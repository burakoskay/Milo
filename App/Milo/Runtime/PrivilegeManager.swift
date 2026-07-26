import Foundation
import AppKit
import Security

/// Manages the optional passwordless mode.
/// This is intentionally opt-in because sudoers rules apply to the whole user session.
/// SAFETY: `_sudoVerified` is the only mutable stored state and is accessed
/// exclusively through `verificationLock`; all other stored state is immutable.
final class PrivilegeManager: @unchecked Sendable {
    static let shared = PrivilegeManager()

    private let sudoersFilePath = "/etc/sudoers.d/milo"

    /// Cached result of sudo verification (reset on configure/remove)
    private var _sudoVerified: Bool?
    private let verificationLock = NSLock()

    private enum SudoersTempFileError: LocalizedError {
        case randomGenerationFailed(OSStatus)
        case utf8EncodingFailed
        case openFailed(Int32)
        case permissionFailed(Int32)
        case writeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed(let status):
                return "Secure random generation failed with status \(status)"
            case .utf8EncodingFailed:
                return "Sudoers content could not be encoded as UTF-8"
            case .openFailed(let code):
                return "Secure temporary sudoers file open failed with errno \(code)"
            case .permissionFailed(let code):
                return "Secure temporary sudoers file permission update failed with errno \(code)"
            case .writeFailed(let code):
                return "Secure temporary sudoers file write failed with errno \(code)"
            }
        }
    }

    /// Check if privileges are already configured and working
    var isConfigured: Bool {
        // First check if the sudoers file exists
        guard FileManager.default.fileExists(atPath: sudoersFilePath) else {
            setCachedVerification(nil)
            return false
        }
        guard !containsLegacyBroadRules() else {
            setCachedVerification(nil)
            return false
        }
        // Use cached result if available
        if let cached = cachedVerification() { return cached }
        let result = verifySudoWorks()
        setCachedVerification(result)
        return result
    }

    /// Quick test that passwordless sudo is functional.
    private func verifySudoWorks() -> Bool {
        CommandRunner.run("/usr/bin/sudo", arguments: ["-n", "/bin/echo", "milo"]).succeeded
    }

    private func containsLegacyBroadRules() -> Bool {
        do {
            let contents = try String(contentsOfFile: sudoersFilePath, encoding: .utf8)
            let broadRules = [
                "NOPASSWD: /usr/bin/pkill",
                "NOPASSWD: /bin/launchctl",
                "NOPASSWD: /usr/bin/killall\n",
                "NOPASSWD: /usr/sbin/systemsetup",
                "NOPASSWD: /usr/bin/xattr"
            ]
            return broadRules.contains { contents.contains($0) }
        } catch {
            return true
        }
    }

    /// Reset the cached verification result
    func resetVerification() {
        setCachedVerification(nil)
    }

    private func cachedVerification() -> Bool? {
        verificationLock.lock()
        defer { verificationLock.unlock() }
        return _sudoVerified
    }

    private func setCachedVerification(_ value: Bool?) {
        verificationLock.lock()
        _sudoVerified = value
        verificationLock.unlock()
    }

    /// Configure passwordless access (requires one-time password)
    func configurePrivileges(completion: @escaping @Sendable (Bool) -> Void) {
        let username = NSUserName()
        let allowedUsername = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !username.isEmpty, username.unicodeScalars.allSatisfy({ allowedUsername.contains($0) }) else {
            completion(false)
            return
        }

        // Create sudoers content scoped to exact low-risk maintenance commands.
        // Destructive launchctl/xattr/systemsetup operations still require an admin prompt.
        let sudoersContent = """
        # Milo - optional fast privileged mode
        # WARNING: sudoers rules are user-wide. Any process running as this user
        # can invoke these exact commands through sudo without a password.
        \(username) ALL=(ALL) NOPASSWD: /usr/sbin/purge
        \(username) ALL=(ALL) NOPASSWD: /bin/echo milo
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/dscacheutil -flushcache
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/mdutil -a -i off
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/mdutil -a -i on
        """

        let tempFile: String
        do {
            let tempURL = try createSecureTemporarySudoersFile(contents: sudoersContent)
            tempFile = tempURL.path
        } catch {
            MiloLog.error("Failed to write temporary sudoers file: \(error.localizedDescription)", category: .privileges)
            completion(false)
            return
        }

        // Use AppleScript to move file with admin privileges
        let command = [
            "/usr/sbin/visudo -c -f \(Self.shellQuote(tempFile))",
            "/bin/cp \(Self.shellQuote(tempFile)) /etc/sudoers.d/milo",
            "/bin/chmod 0440 /etc/sudoers.d/milo",
            "/bin/rm -f \(Self.shellQuote(tempFile))"
        ].joined(separator: " && ")
        let script = """
        do shell script "\(Self.appleScriptStringLiteral(command))" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self, script, tempFile, completion] in
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                _ = appleScript.executeAndReturnError(&error)
                let succeeded = error == nil
                DispatchQueue.main.async { [weak self, tempFile, completion] in
                    // Clean up temp file if still exists
                    do {
                        if FileManager.default.fileExists(atPath: tempFile) {
                            try FileManager.default.removeItem(atPath: tempFile)
                        }
                    } catch {
                        MiloLog.warning("Failed to clean up temporary sudoers file: \(error.localizedDescription)", category: .privileges)
                    }

                    if succeeded {
                        self?.setCachedVerification(nil)
                        completion(true)
                    } else {
                        MiloLog.error("Failed to configure privileges via administrator prompt", category: .privileges)
                        completion(false)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    private func createSecureTemporarySudoersFile(contents: String) throws -> URL {
        let token = try Self.secureRandomHex(byteCount: 16)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("milo-sudoers-\(token)", isDirectory: false)
            .standardizedFileURL
        try Self.writeExclusiveUTF8(contents, to: tempURL)
        return tempURL
    }

    private static func secureRandomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SudoersTempFileError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeExclusiveUTF8(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw SudoersTempFileError.utf8EncodingFailed
        }

        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw SudoersTempFileError.openFailed(errno)
        }
        defer {
            close(fd)
        }

        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw SudoersTempFileError.permissionFailed(errno)
        }

        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else {
                throw SudoersTempFileError.utf8EncodingFailed
            }

            var remaining = data.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                guard written > 0 else {
                    throw SudoersTempFileError.writeFailed(errno)
                }
                let writtenCount = written
                remaining -= writtenCount
                pointer = pointer.advanced(by: writtenCount)
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Remove privileges configuration
    func removePrivileges(completion: @escaping @Sendable (Bool) -> Void) {
        let script = """
        do shell script "rm -f /etc/sudoers.d/milo /etc/sudoers.d/pkill" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                let succeeded = error == nil
                DispatchQueue.main.async {
                    self?.setCachedVerification(nil)
                    completion(succeeded)
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}
