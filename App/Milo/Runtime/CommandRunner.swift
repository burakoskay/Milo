import Foundation
import AppKit
import MiloDomain

enum CommandTermination: Equatable, Sendable {
    case exited
    case policyRejected
    case launchFailed
    case outputLimitExceeded
    case invalidOutputEncoding
}

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let termination: CommandTermination

    var succeeded: Bool { status == 0 && termination == .exited }

    init(
        status: Int32,
        stdout: String,
        stderr: String,
        termination: CommandTermination = .exited
    ) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.termination = termination
    }
}

enum CommandRunner {
    private static let defaultMaximumOutputBytes = 1_048_576
    private static let allowedExecutables: Set<String> = [
        "/bin/echo",
        "/bin/kill",
        "/bin/launchctl",
        "/bin/ps",
        "/bin/sleep",
        "/usr/bin/defaults",
        "/usr/bin/csrutil",
        "/usr/bin/dscacheutil",
        "/usr/bin/killall",
        "/usr/bin/mdutil",
        "/usr/bin/pluginkit",
        "/usr/bin/sudo",
        "/usr/bin/vm_stat",
        "/usr/bin/xattr",
        "/usr/sbin/purge"
    ]

    /// SAFETY: `output` is accessed only while `lock` is held.
    private final class LockedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var output: MiloBoundedCommandOutput

        init(maximumBytes: Int) throws {
            output = try MiloBoundedCommandOutput(maximumBytes: maximumBytes)
        }

        func append(_ data: Data, to stream: MiloCommandOutputStream) {
            lock.lock()
            output.append(data, to: stream)
            lock.unlock()
        }

        func snapshot() -> MiloBoundedCommandOutput {
            lock.lock()
            let snapshot = output
            lock.unlock()
            return snapshot
        }
    }

    @discardableResult
    static func run(
        _ executable: String,
        arguments: [String] = [],
        maximumOutputBytes: Int = defaultMaximumOutputBytes
    ) -> CommandResult {
        guard maximumOutputBytes > 0,
              maximumOutputBytes <= defaultMaximumOutputBytes else {
            return CommandResult(
                status: 126,
                stdout: "",
                stderr: "Invalid command output limit",
                termination: .policyRejected
            )
        }
        guard isAllowedExecutable(executable),
              arguments.allSatisfy(isSafeArgument(_:)),
              isAllowedInvocation(executable: executable, arguments: arguments) else {
            MiloLog.error("Rejected command outside allowlist: \(executable)", category: .security)
            return CommandResult(
                status: 126,
                stdout: "",
                stderr: "Executable or argument rejected by Milo command policy",
                termination: .policyRejected
            )
        }

        let output: LockedOutput
        do {
            output = try LockedOutput(maximumBytes: maximumOutputBytes)
        } catch {
            return CommandResult(
                status: 126,
                stdout: "",
                stderr: "Invalid command output limit",
                termination: .policyRejected
            )
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        attachDrainHandler(to: stdoutPipe, output: output, stream: .standardOutput)
        attachDrainHandler(to: stderrPipe, output: output, stream: .standardError)

        do {
            try task.run()
            task.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try drainRemaining(
                from: stdoutPipe.fileHandleForReading,
                output: output,
                stream: .standardOutput
            )
            try drainRemaining(
                from: stderrPipe.fileHandleForReading,
                output: output,
                stream: .standardError
            )
            return commandResult(status: task.terminationStatus, output: output.snapshot())
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return boundedResult(
                status: 1,
                stdout: "",
                stderr: error.localizedDescription,
                termination: .launchFailed
            )
        }
    }

    private static func attachDrainHandler(
        to pipe: Pipe,
        output: LockedOutput,
        stream: MiloCommandOutputStream
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            output.append(data, to: stream)
        }
    }

    private static func drainRemaining(
        from handle: FileHandle,
        output: LockedOutput,
        stream: MiloCommandOutputStream
    ) throws {
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            output.append(data, to: stream)
        }
    }

    private static func commandResult(status: Int32, output: MiloBoundedCommandOutput) -> CommandResult {
        guard let stdout = String(bytes: output.standardOutput, encoding: .utf8),
              let stderr = String(bytes: output.standardError, encoding: .utf8) else {
            return CommandResult(
                status: 74,
                stdout: "",
                stderr: "Command output was not valid UTF-8",
                termination: .invalidOutputEncoding
            )
        }
        return CommandResult(
            status: output.wasTruncated ? 74 : status,
            stdout: stdout,
            stderr: stderr,
            termination: output.wasTruncated ? .outputLimitExceeded : .exited
        )
    }

    private static func boundedResult(
        status: Int32,
        stdout: String,
        stderr: String,
        termination: CommandTermination = .exited
    ) -> CommandResult {
        let output: MiloBoundedCommandOutput
        do {
            var boundedOutput = try MiloBoundedCommandOutput(maximumBytes: defaultMaximumOutputBytes)
            boundedOutput.append(Data(stdout.utf8), to: .standardOutput)
            boundedOutput.append(Data(stderr.utf8), to: .standardError)
            output = boundedOutput
        } catch {
            return CommandResult(
                status: 126,
                stdout: "",
                stderr: "Invalid command output limit",
                termination: .policyRejected
            )
        }
        if output.wasTruncated {
            return commandResult(status: status, output: output)
        }
        guard let decodedStdout = String(bytes: output.standardOutput, encoding: .utf8),
              let decodedStderr = String(bytes: output.standardError, encoding: .utf8) else {
            return CommandResult(
                status: 74,
                stdout: "",
                stderr: "Command output was not valid UTF-8",
                termination: .invalidOutputEncoding
            )
        }
        return CommandResult(status: status, stdout: decodedStdout, stderr: decodedStderr, termination: termination)
    }

    @discardableResult
    static func runPrivileged(_ executable: String, arguments: [String] = []) -> CommandResult {
        guard executable != "/usr/bin/sudo",
              isAllowedExecutable(executable),
              arguments.allSatisfy(isSafeArgument(_:)),
              isAllowedInvocation(executable: executable, arguments: arguments) else {
            MiloLog.error("Rejected privileged command outside allowlist: \(executable)", category: .security)
            return CommandResult(
                status: 126,
                stdout: "",
                stderr: "Privileged executable or argument rejected by Milo command policy",
                termination: .policyRejected
            )
        }

        if PrivilegeManager.shared.isConfigured {
            let sudoResult = run("/usr/bin/sudo", arguments: ["-n", executable] + arguments)
            if sudoResult.succeeded { return sudoResult }
            PrivilegeManager.shared.resetVerification()
        }

        return runWithAdministratorPrivileges(executable, arguments: arguments)
    }

    @discardableResult
    static func runPrivilegedBatch(_ commands: [(executable: String, arguments: [String])]) -> CommandResult {
        guard !commands.isEmpty else { return CommandResult(status: 0, stdout: "", stderr: "") }

        for cmd in commands {
            guard cmd.executable != "/usr/bin/sudo",
                  isAllowedExecutable(cmd.executable),
                  cmd.arguments.allSatisfy(isSafeArgument(_:)),
                  isAllowedInvocation(executable: cmd.executable, arguments: cmd.arguments) else {
                MiloLog.error("Rejected privileged command outside allowlist: \(cmd.executable)", category: .security)
                return CommandResult(
                    status: 126,
                    stdout: "",
                    stderr: "Privileged executable or argument rejected by Milo command policy",
                    termination: .policyRejected
                )
            }
        }

        if PrivilegeManager.shared.isConfigured {
            var finalStatus: Int32 = 0
            let aggregateOutput: LockedOutput
            do {
                aggregateOutput = try LockedOutput(maximumBytes: defaultMaximumOutputBytes)
            } catch {
                return CommandResult(
                    status: 126,
                    stdout: "",
                    stderr: "Invalid command output limit",
                    termination: .policyRejected
                )
            }
            for cmd in commands {
                let res = run("/usr/bin/sudo", arguments: ["-n", cmd.executable] + cmd.arguments)
                aggregateOutput.append(Data((res.stdout + "\n").utf8), to: .standardOutput)
                aggregateOutput.append(Data((res.stderr + "\n").utf8), to: .standardError)
                if !res.succeeded {
                    finalStatus = res.status
                }
            }
            let aggregateSnapshot = aggregateOutput.snapshot()
            if aggregateSnapshot.wasTruncated {
                return commandResult(status: finalStatus, output: aggregateSnapshot)
            }
            if finalStatus == 0 {
                return commandResult(status: 0, output: aggregateSnapshot)
            }
            PrivilegeManager.shared.resetVerification()
        }

        let shellCommands = commands.map { shellEscapedCommand($0.executable, arguments: $0.arguments) }
        let combinedShellCommand = shellCommands.joined(separator: " ; ")
        let script = "do shell script \"\(appleScriptStringLiteral(combinedShellCommand))\" with administrator privileges"

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return boundedResult(status: 1, stdout: "", stderr: "Failed to create administrator prompt")
        }

        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "Administrator access denied"
            return boundedResult(status: 1, stdout: "", stderr: message)
        }

        return boundedResult(status: 0, stdout: descriptor.stringValue ?? "", stderr: "")
    }

    static func shellEscapedCommand(_ executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    private static func runWithAdministratorPrivileges(_ executable: String, arguments: [String]) -> CommandResult {
        let shellCommand = shellEscapedCommand(executable, arguments: arguments)
        let script = "do shell script \"\(appleScriptStringLiteral(shellCommand))\" with administrator privileges"

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return boundedResult(status: 1, stdout: "", stderr: "Failed to create administrator prompt")
        }

        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String ?? "Administrator access denied"
            return boundedResult(status: 1, stdout: "", stderr: message)
        }

        return boundedResult(status: 0, stdout: descriptor.stringValue ?? "", stderr: "")
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
        switch executable {
        case "/usr/bin/sudo":
            guard arguments.count >= 2,
                  arguments[0] == "-n",
                  arguments[1] != "/usr/bin/sudo",
                  isAllowedExecutable(arguments[1]) else { return false }
            return isAllowedInvocation(executable: arguments[1], arguments: Array(arguments.dropFirst(2)))
        case "/bin/echo":
            return true
        case "/bin/kill":
            return isAllowedKillInvocation(arguments)
        case "/bin/launchctl":
            return isAllowedLaunchctlInvocation(arguments)
        case "/bin/ps":
            return isAllowedPSInvocation(arguments)
        case "/usr/bin/csrutil":
            return arguments == ["status"]
        case "/usr/bin/defaults":
            return isAllowedDefaultsInvocation(arguments)
        case "/usr/bin/dscacheutil":
            return arguments == ["-flushcache"]
        case "/usr/bin/killall":
            return isAllowedKillAllInvocation(arguments)
        case "/usr/bin/mdutil":
            return arguments == ["-a", "-i", "off"]
                || arguments == ["-a", "-i", "on"]
                || arguments == ["-s", "/"]
        case "/usr/bin/pluginkit":
            return isAllowedPluginKitInvocation(arguments)
        case "/usr/bin/vm_stat":
            return arguments.isEmpty
        case "/usr/bin/xattr":
            return isAllowedXattrInvocation(arguments)
        case "/usr/sbin/purge":
            return arguments.isEmpty
        case "/bin/sleep":
            return arguments == ["1"]
        default:
            return false
        }
    }

    private static func isSafeArgument(_ argument: String) -> Bool {
        !argument.unicodeScalars.contains { scalar in
            scalar.value == 0 || CharacterSet.newlines.contains(scalar)
        }
    }

    private static func isAllowedPSInvocation(_ arguments: [String]) -> Bool {
        [
            ["-Axo", "command"],
            ["-Axo", "pid,comm,command"],
            ["-Axo", "pid,%cpu,rss,comm,command"],
            ["-Axo", "pid=,command="]
        ].contains(arguments)
    }

    private static func isAllowedKillInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count == 2,
              ["-TERM", "-KILL", "-9"].contains(arguments[0]),
              let pid = Int32(arguments[1]),
              pid > 0 else {
            return false
        }
        return true
    }

    private static func isAllowedKillAllInvocation(_ arguments: [String]) -> Bool {
        if arguments == ["-HUP", "mDNSResponder"] {
            return true
        }

        let allowedNames: Set<String> = ["Finder", "Dock", "SystemUIServer", "cfprefsd", "NotificationCenter"]
        return arguments.count == 1 && allowedNames.contains(arguments[0])
    }

    private static func isAllowedPluginKitInvocation(_ arguments: [String]) -> Bool {
        if arguments == ["-mA"] || arguments == ["-mAvv"] {
            return true
        }

        return arguments.count == 4
            && arguments[0] == "-e"
            && ["ignore", "use"].contains(arguments[1])
            && arguments[2] == "-i"
            && isSafeBundleIdentifier(arguments[3])
    }

    private static func isAllowedLaunchctlInvocation(_ arguments: [String]) -> Bool {
        guard let action = arguments.first else { return false }

        if action == "print-disabled", arguments.count == 2 {
            return isSafeLaunchctlDomain(arguments[1])
        }

        if action == "print", arguments.count == 2 {
            return isSafeLaunchctlDomainTarget(arguments[1])
        }

        if ["disable", "enable", "bootout"].contains(action), arguments.count == 2 {
            return isSafeLaunchctlDomainTarget(arguments[1])
        }

        if action == "bootstrap", arguments.count == 3 {
            return isSafeLaunchctlDomain(arguments[1]) && isSafeLaunchctlPlistPath(arguments[2])
        }

        if ["load", "unload"].contains(action), arguments.count == 3, arguments[1] == "-w" {
            return isSafeLaunchctlPlistPath(arguments[2])
        }

        return false
    }

    private static func isAllowedDefaultsInvocation(_ arguments: [String]) -> Bool {
        var remaining = arguments
        if remaining.first == "-currentHost" {
            remaining.removeFirst()
        }

        guard let action = remaining.first else { return false }

        if action == "read", remaining.count == 3 {
            return isSafeDefaultsDomain(remaining[1]) && isSafeDefaultsKey(remaining[2])
        }

        if action == "delete", remaining.count == 2 {
            return isSafeDefaultsDomain(remaining[1])
        }

        if action == "delete", remaining.count == 3 {
            return isSafeDefaultsDomain(remaining[1]) && isSafeDefaultsKey(remaining[2])
        }

        guard action == "write", remaining.count == 4 || remaining.count == 5 else {
            return false
        }

        let domain = remaining[1]
        let key = remaining[2]
        guard isSafeDefaultsDomain(domain), isSafeDefaultsKey(key) else { return false }

        if remaining.count == 4 {
            return isSafeDefaultsStringValue(remaining[3])
        }

        let valueType = remaining[3]
        let value = remaining[4]
        switch valueType {
        case "-bool":
            return value == "true" || value == "false"
        case "-int":
            return Int(value) != nil
        case "-float":
            return Double(value) != nil
        case "-string":
            return isSafeDefaultsStringValue(value)
        default:
            return false
        }
    }

    private static func isAllowedXattrInvocation(_ arguments: [String]) -> Bool {
        if arguments.count == 3,
           arguments[0] == "-p",
           arguments[1] == "com.apple.quarantine",
           isSafeStockAppPath(arguments[2]) {
            return true
        }

        if arguments.count == 4,
           arguments[0] == "-w",
           arguments[1] == "com.apple.quarantine",
           arguments[2] == "0181;00000000;blocked;",
           isSafeStockAppPath(arguments[3]) {
            return true
        }

        if arguments.count == 3,
           arguments[0] == "-d",
           arguments[1] == "com.apple.quarantine",
           isSafeStockAppPath(arguments[2]) {
            return true
        }

        return false
    }

    private static func isSafeLaunchctlDomain(_ value: String) -> Bool {
        if value == "system" {
            return true
        }

        let parts = value.split(separator: "/").map(String.init)
        return parts.count == 2 && parts[0] == "gui" && UInt32(parts[1]) == getuid()
    }

    private static func isSafeLaunchctlDomainTarget(_ value: String) -> Bool {
        let parts = value.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "system" {
            return isSafeLaunchdLabel(parts[1])
        }
        guard parts.count == 3, parts[0] == "gui", UInt32(parts[1]) == getuid() else { return false }
        return isSafeLaunchdLabel(parts[2])
    }

    private static func isSafeLaunchdLabel(_ value: String) -> Bool {
        isSafeText(value, maxLength: 256, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")))
    }

    private static func isSafeLaunchctlPlistPath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard standardized == value,
              value.hasSuffix(".plist"),
              !containsControlCharacters(value) else {
            return false
        }

        let homeLaunchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL.path + "/"
        return value.hasPrefix("/System/Library/LaunchDaemons/")
            || value.hasPrefix("/System/Library/LaunchAgents/")
            || value.hasPrefix("/Library/LaunchDaemons/")
            || value.hasPrefix("/Library/LaunchAgents/")
            || value.hasPrefix(homeLaunchAgents)
    }

    private static func isSafeStockAppPath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        return standardized == value
            && value.hasSuffix(".app")
            && (value.hasPrefix("/System/Applications/") || value.hasPrefix("/Applications/"))
            && !containsControlCharacters(value)
    }

    private static func isSafeDefaultsDomain(_ value: String) -> Bool {
        value == "NSGlobalDomain" || isSafeBundleIdentifier(value)
    }

    private static func isSafeDefaultsKey(_ value: String) -> Bool {
        isSafeText(value, maxLength: 160, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-")))
    }

    private static func isSafeDefaultsStringValue(_ value: String) -> Bool {
        isSafeText(value, maxLength: 160, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-")))
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        isSafeText(value, maxLength: 256, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")))
    }

    private static func isSafeText(_ value: String, maxLength: Int, allowedCharacters: CharacterSet) -> Bool {
        !value.isEmpty
            && value.count <= maxLength
            && !containsControlCharacters(value)
            && value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0
        }
    }
}
