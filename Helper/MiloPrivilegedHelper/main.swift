import Darwin
import Foundation
import MiloDomain

@objc private protocol MiloPrivilegedHelperProtocol {
    func execute(_ commands: NSArray, withReply reply: @escaping (NSDictionary) -> Void)
}

private enum MiloPrivilegedHelperIdentity {
    static let machServiceName = "com.gonggong.milo.helper"
    static let clientRequirement = "anchor apple generic and (identifier \"com.gonggong.milo\" or identifier \"com.gonggong.milo.preview\") and certificate leaf[subject.OU] = \"8N738727QB\""
}

private struct HelperCommand {
    let executable: String
    let arguments: [String]
    let expectedProcessIdentity: ExpectedProcessIdentity?
}

private struct ExpectedProcessIdentity {
    let pid: Int32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private enum HelperPolicy {
    private static let allowedExecutables: Set<String> = [
        "/bin/echo",
        "/bin/kill",
        "/bin/launchctl",
        "/bin/sleep",
        "/usr/bin/dscacheutil",
        "/usr/bin/killall",
        "/usr/bin/mdutil",
        "/usr/bin/xattr",
        "/usr/sbin/purge"
    ]

    static func decode(_ rawCommands: NSArray, clientUserID: uid_t) -> [HelperCommand]? {
        guard rawCommands.firstObject != nil, rawCommands.count <= 128 else {
            return nil
        }

        var commands: [HelperCommand] = []
        commands.reserveCapacity(rawCommands.count)
        for rawCommand in rawCommands {
            guard let dictionary = rawCommand as? NSDictionary,
                  let executable = dictionary["executable"] as? String,
                  let arguments = dictionary["arguments"] as? [String],
                  arguments.count <= 32,
                  arguments.allSatisfy({ isSafeArgument($0) }) else {
                return nil
            }
            let identity = decodeExpectedIdentity(dictionary, executable: executable, arguments: arguments)
            guard isAllowed(
                executable: executable,
                arguments: arguments,
                expectedProcessIdentity: identity,
                clientUserID: clientUserID
            ) else {
                return nil
            }
            commands.append(
                HelperCommand(
                    executable: executable,
                    arguments: arguments,
                    expectedProcessIdentity: identity
                )
            )
        }
        return commands
    }

    private static func decodeExpectedIdentity(
        _ dictionary: NSDictionary,
        executable: String,
        arguments: [String]
    ) -> ExpectedProcessIdentity? {
        guard executable == "/bin/kill",
              arguments.count == 2,
              let pid = Int32(arguments[1]),
              let path = dictionary["expectedExecutablePath"] as? String,
              let seconds = dictionary["expectedStartSeconds"] as? NSNumber,
              let microseconds = dictionary["expectedStartMicroseconds"] as? NSNumber,
              isSafeExecutablePath(path) else {
            return nil
        }
        return ExpectedProcessIdentity(
            pid: pid,
            executablePath: path,
            startSeconds: seconds.uint64Value,
            startMicroseconds: microseconds.uint64Value
        )
    }

    private static func isAllowed(
        executable: String,
        arguments: [String],
        expectedProcessIdentity: ExpectedProcessIdentity?,
        clientUserID: uid_t
    ) -> Bool {
        guard executable.hasPrefix("/"),
              URL(fileURLWithPath: executable).standardizedFileURL.path == executable,
              allowedExecutables.contains(executable) else {
            return false
        }

        switch executable {
        case "/bin/echo":
            return expectedProcessIdentity == nil && arguments == ["milo-helper-ready"]
        case "/bin/kill":
            return isAllowedKill(arguments, expectedProcessIdentity: expectedProcessIdentity)
        case "/bin/launchctl":
            return isAllowedLaunchctl(arguments, clientUserID: clientUserID)
        case "/bin/sleep":
            return arguments == ["1"]
        case "/usr/bin/dscacheutil":
            return arguments == ["-flushcache"]
        case "/usr/bin/killall":
            return arguments == ["-HUP", "mDNSResponder"]
        case "/usr/bin/mdutil":
            return arguments == ["-a", "-i", "off"] || arguments == ["-a", "-i", "on"]
        case "/usr/bin/xattr":
            return isAllowedXattr(arguments)
        case "/usr/sbin/purge":
            return arguments.isEmpty
        default:
            return false
        }
    }

    private static func isAllowedKill(
        _ arguments: [String],
        expectedProcessIdentity: ExpectedProcessIdentity?
    ) -> Bool {
        guard arguments.count == 2,
              ["-TERM", "-KILL"].contains(arguments[0]),
              let pid = Int32(arguments[1]),
              pid > 1,
              pid != getpid(),
              let expectedProcessIdentity,
              expectedProcessIdentity.pid == pid else {
            return false
        }

        // The helper runs as root and must not depend on the client having asked correctly.
        // The client already refuses these, but a gate that exists only on the far side of an
        // XPC boundary is a gate that a client-side regression silently removes.
        //
        // The list is shared source with the app rather than a copy, so the two cannot drift.
        guard !MiloProcessSafetyPolicy.isCriticalSystemExecutable(expectedProcessIdentity.executablePath) else {
            return false
        }

        return true
    }

    private static func isSafeExecutablePath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        return value.hasPrefix("/")
            && standardized == value
            && value.utf8.count <= 4_096
            && !containsControlCharacters(value)
    }

    private static func isAllowedLaunchctl(_ arguments: [String], clientUserID: uid_t) -> Bool {
        guard let action = arguments.first else {
            return false
        }
        if ["disable", "enable", "bootout"].contains(action), arguments.count == 2 {
            return isSafeDomainTarget(arguments[1], clientUserID: clientUserID)
        }
        if action == "print-disabled", arguments == ["print-disabled", "system"] {
            return true
        }
        if action == "bootstrap", arguments.count == 3 {
            return isSafeDomain(arguments[1], clientUserID: clientUserID)
                && isSafePlistPath(arguments[2], clientUserID: clientUserID)
        }
        if ["load", "unload"].contains(action), arguments.count == 3, arguments[1] == "-w" {
            return isSafePlistPath(arguments[2], clientUserID: clientUserID)
        }
        return false
    }

    private static func isSafeDomain(_ value: String, clientUserID: uid_t) -> Bool {
        if value == "system" {
            return true
        }
        return value == "gui/\(clientUserID)"
    }

    private static func isSafeDomainTarget(_ value: String, clientUserID: uid_t) -> Bool {
        let parts = value.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "system" {
            return isSafeLabel(parts[1])
        }
        guard parts.count == 3,
              parts[0] == "gui",
              UInt32(parts[1]) == clientUserID else {
            return false
        }
        return isSafeLabel(parts[2])
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        isSafeText(
            value,
            maximumLength: 256,
            allowed: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        )
    }

    private static func isSafePlistPath(_ value: String, clientUserID: uid_t) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        guard standardized == value, value.hasSuffix(".plist"), !containsControlCharacters(value) else {
            return false
        }

        let userHome: String
        if let passwordEntry = getpwuid(clientUserID), let directory = passwordEntry.pointee.pw_dir {
            userHome = String(cString: directory)
        } else {
            return false
        }
        let userLaunchAgents = URL(fileURLWithPath: userHome)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL.path + "/"
        return value.hasPrefix("/System/Library/LaunchDaemons/")
            || value.hasPrefix("/System/Library/LaunchAgents/")
            || value.hasPrefix("/Library/LaunchDaemons/")
            || value.hasPrefix("/Library/LaunchAgents/")
            || value.hasPrefix(userLaunchAgents)
    }

    private static func isAllowedXattr(_ arguments: [String]) -> Bool {
        if arguments.count == 4,
           arguments[0] == "-w",
           arguments[1] == "com.apple.quarantine",
           arguments[2] == "0181;00000000;blocked;" {
            return isSafeStockAppPath(arguments[3])
        }
        if arguments.count == 3,
           arguments[0] == "-d",
           arguments[1] == "com.apple.quarantine" {
            return isSafeStockAppPath(arguments[2])
        }
        return false
    }

    private static func isSafeStockAppPath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        return standardized == value
            && value.hasSuffix(".app")
            && (value.hasPrefix("/System/Applications/") || value.hasPrefix("/Applications/"))
            && !containsControlCharacters(value)
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && !containsControlCharacters(value)
    }

    private static func isSafeText(_ value: String, maximumLength: Int, allowed: CharacterSet) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && !containsControlCharacters(value)
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0
        }
    }
}

private final class MiloPrivilegedService: NSObject, MiloPrivilegedHelperProtocol {
    private let clientUserID: uid_t

    init(clientUserID: uid_t) {
        self.clientUserID = clientUserID
    }

    func execute(_ commands: NSArray, withReply reply: @escaping (NSDictionary) -> Void) {
        guard let decoded = HelperPolicy.decode(commands, clientUserID: clientUserID) else {
            reply(Self.response(status: 126, stdout: "", stderr: "Privileged request rejected by policy."))
            return
        }

        var stdout = Data()
        var stderr = Data()
        var finalStatus: Int32 = 0
        let maximumBytes = 1_048_576

        for command in decoded {
            if let expectedIdentity = command.expectedProcessIdentity {
                switch Self.processIdentityStatus(expectedIdentity) {
                case .same:
                    break
                case .gone:
                    continue
                case .changed:
                    reply(
                        Self.response(
                            status: 126,
                            stdout: "",
                            stderr: "Process identity changed before the signal was sent."
                        )
                    )
                    return
                }
            }
            let result = MiloSubprocessRunner.run(
                executable: command.executable,
                arguments: command.arguments,
                maximumOutputBytes: maximumBytes,
                deadline: .seconds(15)
            )
            Self.append(result.standardOutput, to: &stdout, maximumBytes: maximumBytes)
            Self.append(result.standardError, to: &stderr, maximumBytes: maximumBytes)
            if result.status != 0 || result.termination != .exited {
                finalStatus = result.status == 0 ? 1 : result.status
                break
            }
        }

        guard let decodedStdout = String(data: stdout, encoding: .utf8),
              let decodedStderr = String(data: stderr, encoding: .utf8) else {
            reply(Self.response(status: 74, stdout: "", stderr: "Helper output was not valid UTF-8."))
            return
        }
        reply(Self.response(status: finalStatus, stdout: decodedStdout, stderr: decodedStderr))
    }

    private enum ProcessIdentityStatus {
        case same
        case gone
        case changed
    }

    private static func processIdentityStatus(_ expected: ExpectedProcessIdentity) -> ProcessIdentityStatus {
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let informationResult = proc_pidinfo(
            expected.pid,
            PROC_PIDTBSDINFO,
            0,
            &information,
            informationSize
        )
        guard informationResult == informationSize else {
            return errno == ESRCH ? .gone : .changed
        }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathResult = pathBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return 0
            }
            return proc_pidpath(expected.pid, baseAddress, UInt32(buffer.count))
        }
        guard pathResult > 0 else {
            return errno == ESRCH ? .gone : .changed
        }
        let pathBytes = pathBuffer.prefix(Int(pathResult)).map { UInt8(bitPattern: $0) }
        guard let executablePath = String(bytes: pathBytes, encoding: .utf8) else {
            return .changed
        }

        return executablePath == expected.executablePath
            && information.pbi_start_tvsec == expected.startSeconds
            && information.pbi_start_tvusec == expected.startMicroseconds
            ? .same
            : .changed
    }

    private static func append(_ data: Data, to destination: inout Data, maximumBytes: Int) {
        let remaining = max(0, maximumBytes - destination.count)
        guard remaining > 0 else {
            return
        }
        destination.append(data.prefix(remaining))
    }

    private static func response(status: Int32, stdout: String, stderr: String) -> NSDictionary {
        [
            "status": NSNumber(value: status),
            "stdout": stdout,
            "stderr": stderr
        ] as NSDictionary
    }
}

private final class MiloConnectionDelegate: NSObject, NSXPCListenerDelegate {
    private var services: [ObjectIdentifier: MiloPrivilegedService] = [:]
    private let lock = NSLock()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier != 0 else {
            return false
        }

        newConnection.setCodeSigningRequirement(MiloPrivilegedHelperIdentity.clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: MiloPrivilegedHelperProtocol.self)
        let service = MiloPrivilegedService(clientUserID: newConnection.effectiveUserIdentifier)
        let identifier = ObjectIdentifier(newConnection)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak self] in
            self?.removeService(identifier: identifier)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.removeService(identifier: identifier)
        }
        store(service: service, identifier: identifier)
        newConnection.resume()
        return true
    }

    private func store(service: MiloPrivilegedService, identifier: ObjectIdentifier) {
        lock.lock()
        services[identifier] = service
        lock.unlock()
    }

    private func removeService(identifier: ObjectIdentifier) {
        lock.lock()
        services.removeValue(forKey: identifier)
        lock.unlock()
    }
}

private let connectionDelegate = MiloConnectionDelegate()
private let listener = NSXPCListener(machServiceName: MiloPrivilegedHelperIdentity.machServiceName)
listener.delegate = connectionDelegate
listener.resume()
RunLoop.current.run()
