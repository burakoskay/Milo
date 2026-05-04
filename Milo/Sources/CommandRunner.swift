import Foundation
import AppKit

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum CommandRunner {
    private static let allowedExecutables: Set<String> = [
        "/bin/echo",
        "/bin/kill",
        "/bin/launchctl",
        "/bin/ps",
        "/usr/bin/defaults",
        "/usr/bin/dscacheutil",
        "/usr/bin/killall",
        "/usr/bin/mdutil",
        "/usr/bin/pluginkit",
        "/usr/bin/sudo",
        "/usr/bin/xattr",
        "/usr/sbin/purge"
    ]

    private final class LockedData {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let data = storage
            lock.unlock()
            return data
        }
    }

    @discardableResult
    static func run(_ executable: String, arguments: [String] = []) -> CommandResult {
        guard isAllowedExecutable(executable),
              arguments.allSatisfy(isSafeArgument(_:)),
              isAllowedInvocation(executable: executable, arguments: arguments) else {
            MiloLog.error("Rejected command outside allowlist: \(executable)", category: .security)
            return CommandResult(status: 126, stdout: "", stderr: "Executable or argument rejected by Milo command policy")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        let stdoutData = LockedData()
        let stderrData = LockedData()
        attachDrainHandler(to: stdoutPipe, output: stdoutData)
        attachDrainHandler(to: stderrPipe, output: stderrData)

        do {
            try task.run()
            task.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

            return CommandResult(
                status: task.terminationStatus,
                stdout: String(data: stdoutData.snapshot(), encoding: .utf8) ?? "",
                stderr: String(data: stderrData.snapshot(), encoding: .utf8) ?? ""
            )
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: 1, stdout: "", stderr: error.localizedDescription)
        }
    }

    private static func attachDrainHandler(to pipe: Pipe, output: LockedData) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            output.append(data)
        }
    }

    @discardableResult
    static func runPrivileged(_ executable: String, arguments: [String] = []) -> CommandResult {
        guard isAllowedExecutable(executable), arguments.allSatisfy(isSafeArgument(_:)) else {
            MiloLog.error("Rejected privileged command outside allowlist: \(executable)", category: .security)
            return CommandResult(status: 126, stdout: "", stderr: "Privileged executable or argument rejected by Milo command policy")
        }

        if PrivilegeManager.shared.isConfigured {
            let sudoResult = run("/usr/bin/sudo", arguments: ["-n", executable] + arguments)
            if sudoResult.succeeded { return sudoResult }
            PrivilegeManager.shared.resetVerification()
        }

        return runWithAdministratorPrivileges(executable, arguments: arguments)
    }

    static func shellEscapedCommand(_ executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func runWithAdministratorPrivileges(_ executable: String, arguments: [String]) -> CommandResult {
        let shellCommand = shellEscapedCommand(executable, arguments: arguments)
        let script = "do shell script \"\(appleScriptStringLiteral(shellCommand))\" with administrator privileges"

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return CommandResult(status: 1, stdout: "", stderr: "Failed to create administrator prompt")
        }

        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "Administrator access denied"
            return CommandResult(status: 1, stdout: "", stderr: message)
        }

        return CommandResult(status: 0, stdout: descriptor.stringValue ?? "", stderr: "")
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

    private static func isAllowedExecutable(_ executable: String) -> Bool {
        guard executable.hasPrefix("/") else { return false }
        let standardized = URL(fileURLWithPath: executable).standardizedFileURL.path
        return standardized == executable && allowedExecutables.contains(executable)
    }

    private static func isAllowedInvocation(executable: String, arguments: [String]) -> Bool {
        guard executable == "/usr/bin/sudo" else { return true }
        guard arguments.count >= 2, arguments[0] == "-n" else { return false }
        return isAllowedExecutable(arguments[1])
    }

    private static func isSafeArgument(_ argument: String) -> Bool {
        !argument.unicodeScalars.contains { scalar in
            scalar.value == 0 || CharacterSet.newlines.contains(scalar)
        }
    }
}
