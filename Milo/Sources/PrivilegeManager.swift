import Foundation
import AppKit
import os

/// Manages the optional passwordless mode.
/// This is intentionally opt-in because sudoers rules apply to the whole user session.
class PrivilegeManager {
    static let shared = PrivilegeManager()

    private let sudoersFilePath = "/etc/sudoers.d/milo"

    /// Cached result of sudo verification (reset on configure/remove)
    private var _sudoVerified: Bool?

    /// Check if privileges are already configured and working
    var isConfigured: Bool {
        // First check if the sudoers file exists
        guard FileManager.default.fileExists(atPath: sudoersFilePath) else {
            _sudoVerified = nil
            return false
        }
        guard !containsLegacyBroadRules() else {
            _sudoVerified = nil
            return false
        }
        // Use cached result if available
        if let cached = _sudoVerified { return cached }
        let result = verifySudoWorks()
        _sudoVerified = result
        return result
    }

    /// Quick test that passwordless sudo is functional.
    private func verifySudoWorks() -> Bool {
        CommandRunner.run("/usr/bin/sudo", arguments: ["-n", "/usr/bin/dscacheutil", "-flushcache"]).succeeded
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
        _sudoVerified = nil
    }

    /// Configure passwordless access (requires one-time password)
    func configurePrivileges(completion: @escaping (Bool) -> Void) {
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
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/dscacheutil -flushcache
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/mdutil -a -i off
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/mdutil -a -i on
        """

        // Write to temp file first (avoids escaping issues)
        let tempFile = "/tmp/pkill_sudoers_\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try sudoersContent.write(toFile: tempFile, atomically: true, encoding: .utf8)
        } catch {
            Logger.privilege.error("Failed to write temp file: \(error, privacy: .public)")
            completion(false)
            return
        }

        // Use AppleScript to move file with admin privileges
        let script = """
        do shell script "visudo -c -f '\(tempFile)' && cp '\(tempFile)' /etc/sudoers.d/pkill && chmod 0440 /etc/sudoers.d/pkill && rm '\(tempFile)'" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                _ = appleScript.executeAndReturnError(&error)
                DispatchQueue.main.async { [weak self] in
                    // Clean up temp file if still exists
                    do {
                        if FileManager.default.fileExists(atPath: tempFile) {
                            try FileManager.default.removeItem(atPath: tempFile)
                        }
                    } catch {
                        Logger.privilege.error("Failed to clean up temp sudoers file: \(error.localizedDescription, privacy: .public)")
                    }

                    if error == nil {
                        self?._sudoVerified = nil // Reset cache so next check re-verifies
                        completion(true)
                    } else {
                        Logger.privilege.error("Failed to configure privileges: \(error ?? [:], privacy: .public)")
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

    /// Legacy shell-string runner for static debloat recipes only.
    /// Runtime process names, labels, and paths must use CommandRunner directly.
    func runWithPrivileges(_ command: String, completion: ((Bool, String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let wrapped = self.wrapCommandsWithSudo(command)
            guard wrapped.didWrap else {
                DispatchQueue.main.async {
                    completion?(false, "Command requires explicit administrator authorization")
                }
                return
            }

            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", wrapped.command]

            let pipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errorPipe

            do {
                try task.run()
                task.waitUntilExit()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8)

                let success = task.terminationStatus == 0

                DispatchQueue.main.async {
                    completion?(success, output)
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(false, error.localizedDescription)
                }
            }
        }
    }

    /// Legacy synchronous shell-string runner for static debloat recipes only.
    func runWithPrivilegesSync(_ command: String) -> Bool {
        let wrapped = wrapCommandsWithSudo(command)
        guard wrapped.didWrap else { return false }

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", wrapped.command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Sudo Wrapping

    private struct WrapResult {
        let command: String
        let didWrap: Bool
    }

    private func wrapCommandsWithSudo(_ command: String) -> WrapResult {
        struct Segment {
            let text: String
            let isSeparator: Bool
        }

        var segments: [Segment] = []
        var current = ""
        var quote: Character?
        let chars = Array(command)
        var index = 0

        while index < chars.count {
            let char = chars[index]

            if let currentQuote = quote, char == currentQuote {
                current.append(char)
                quote = nil
                index += 1
                continue
            }

            if quote == nil, char == "\"" || char == "'" {
                quote = char
                current.append(char)
                index += 1
                continue
            }

            if quote == nil {
                if char == ";" {
                    if !current.isEmpty {
                        segments.append(Segment(text: current, isSeparator: false))
                        current = ""
                    }
                    segments.append(Segment(text: ";", isSeparator: true))
                    index += 1
                    continue
                }

                if index + 1 < chars.count {
                    let next = chars[index + 1]
                    if char == "&", next == "&" {
                        if !current.isEmpty {
                            segments.append(Segment(text: current, isSeparator: false))
                            current = ""
                        }
                        segments.append(Segment(text: "&&", isSeparator: true))
                        index += 2
                        continue
                    }
                    if char == "|", next == "|" {
                        if !current.isEmpty {
                            segments.append(Segment(text: current, isSeparator: false))
                            current = ""
                        }
                        segments.append(Segment(text: "||", isSeparator: true))
                        index += 2
                        continue
                    }
                }
            }

            current.append(char)
            index += 1
        }

        if !current.isEmpty {
            segments.append(Segment(text: current, isSeparator: false))
        }

        var didWrap = false
        var rejectedSegment = false
        let wrappedCommand = segments.map { segment in
            guard !segment.isSeparator else { return segment.text }

            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }

            if let passwordless = passwordlessCommand(for: trimmed) {
                didWrap = true
                return passwordless
            }
            if trimmed != "true" {
                rejectedSegment = true
            }
            return trimmed
        }.joined(separator: " ")

        return WrapResult(command: wrappedCommand, didWrap: didWrap && !rejectedSegment)
    }

    private func passwordlessCommand(for segment: String) -> String? {
        let tokens = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let redirectionIndex = tokens.firstIndex { token in
            token.hasPrefix(">") || token.hasPrefix("1>") || token.hasPrefix("2>")
        }
        let commandTokens = Array(tokens[..<(redirectionIndex ?? tokens.endIndex)])
        let suffixTokens = redirectionIndex.map { Array(tokens[$0...]) } ?? []
        guard !commandTokens.isEmpty else { return nil }

        let baseName = (commandTokens[0] as NSString).lastPathComponent
        let args = Array(commandTokens.dropFirst())
        let suffix = suffixTokens.isEmpty ? "" : " " + suffixTokens.joined(separator: " ")

        if baseName == "purge", args.isEmpty {
            return "sudo -n /usr/sbin/purge\(suffix)"
        }
        if baseName == "dscacheutil", args == ["-flushcache"] {
            return "sudo -n /usr/bin/dscacheutil -flushcache\(suffix)"
        }
        if baseName == "killall", args == ["-HUP", "mDNSResponder"] {
            return "sudo -n /usr/bin/killall -HUP mDNSResponder\(suffix)"
        }
        if baseName == "mdutil", args == ["-a", "-i", "off"] {
            return "sudo -n /usr/bin/mdutil -a -i off\(suffix)"
        }
        if baseName == "mdutil", args == ["-a", "-i", "on"] {
            return "sudo -n /usr/bin/mdutil -a -i on\(suffix)"
        }

        return nil
    }

    /// Remove privileges configuration
    func removePrivileges(completion: @escaping (Bool) -> Void) {
        let script = """
        do shell script "rm -f /etc/sudoers.d/milo" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                DispatchQueue.main.async {
                    self?._sudoVerified = nil
                    completion(error == nil)
                }
            } else {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }
}
}
}
