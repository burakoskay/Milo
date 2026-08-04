import Foundation

@objc protocol MiloPrivilegedHelperProtocol {
    func execute(_ commands: NSArray, withReply reply: @escaping (NSDictionary) -> Void)
}

enum MiloPrivilegedHelperIdentity {
    static let machServiceName = "com.gonggong.milo.helper"
    static let plistName = "com.gonggong.milo.helper.plist"
    static let helperRequirement = "anchor apple generic and identifier \"com.gonggong.milo.helper\" and certificate leaf[subject.OU] = \"8N738727QB\""
    static let clientRequirement = "anchor apple generic and (identifier \"com.gonggong.milo\" or identifier \"com.gonggong.milo.preview\") and certificate leaf[subject.OU] = \"8N738727QB\""
}

/// Synchronous boundary used only from Milo's existing background command workers.
/// SAFETY: each request owns its connection and `LockedReply` serializes the sole
/// mutable response slot. The main actor never blocks on this API.
final class MiloPrivilegedHelperClient: @unchecked Sendable {
    static let shared = MiloPrivilegedHelperClient()

    /// SAFETY: every access to `value` is serialized by `lock`.
    private final class LockedReply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: NSDictionary?

        func store(_ reply: NSDictionary) {
            lock.lock()
            value = reply
            lock.unlock()
        }

        func load() -> NSDictionary? {
            lock.lock()
            let reply = value
            lock.unlock()
            return reply
        }
    }

    private init() {}

    func run(commands: [(executable: String, arguments: [String])]) -> CommandResult {
        guard !commands.isEmpty, commands.count <= 128 else {
            return failure("The privileged request was empty or too large.", termination: .policyRejected)
        }

        let encodedCommands = commands.map { command -> NSDictionary in
            [
                "executable": command.executable,
                "arguments": command.arguments
            ] as NSDictionary
        } as NSArray
        return run(encodedCommands: encodedCommands)
    }

    func terminate(identities: Set<ProcessIdentity>) -> CommandResult {
        guard !identities.isEmpty, identities.count <= 64 else {
            return failure("The process request was empty or too large.", termination: .policyRejected)
        }

        let sortedIdentities = identities.sorted { $0.pid < $1.pid }
        var encodedCommands: [NSDictionary] = sortedIdentities.map { encodedSignal("-TERM", identity: $0) }
        encodedCommands.append([
            "executable": "/bin/sleep",
            "arguments": ["1"]
        ] as NSDictionary)
        encodedCommands.append(contentsOf: sortedIdentities.map { encodedSignal("-KILL", identity: $0) })
        return run(encodedCommands: encodedCommands as NSArray)
    }

    private func encodedSignal(_ signal: String, identity: ProcessIdentity) -> NSDictionary {
        [
            "executable": "/bin/kill",
            "arguments": [signal, String(identity.pid)],
            "expectedExecutablePath": identity.executablePath,
            "expectedStartSeconds": NSNumber(value: identity.startSeconds),
            "expectedStartMicroseconds": NSNumber(value: identity.startMicroseconds)
        ] as NSDictionary
    }

    private func run(encodedCommands: NSArray) -> CommandResult {

        let connection = NSXPCConnection(
            machServiceName: MiloPrivilegedHelperIdentity.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MiloPrivilegedHelperProtocol.self)
        connection.setCodeSigningRequirement(MiloPrivilegedHelperIdentity.helperRequirement)

        let completion = DispatchSemaphore(value: 0)
        let lockedReply = LockedReply()
        connection.interruptionHandler = {
            completion.signal()
        }
        connection.invalidationHandler = {
            completion.signal()
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            completion.signal()
        }) as? MiloPrivilegedHelperProtocol else {
            connection.invalidate()
            return failure("Milo could not connect to its background helper.", termination: .launchFailed(0))
        }

        proxy.execute(encodedCommands) { reply in
            lockedReply.store(reply)
            completion.signal()
        }

        let waitResult = completion.wait(timeout: .now() + 30)
        connection.invalidate()
        guard waitResult == .success, let reply = lockedReply.load() else {
            return failure("The Milo background helper did not respond in time.", termination: .timedOut)
        }

        guard let statusNumber = reply["status"] as? NSNumber,
              let stdout = reply["stdout"] as? String,
              let stderr = reply["stderr"] as? String else {
            return failure("The Milo background helper returned an invalid response.", termination: .invalidOutputEncoding)
        }

        let status = statusNumber.int32Value
        return CommandResult(status: status, stdout: stdout, stderr: stderr)
    }

    func healthCheck() -> Bool {
        run(commands: [("/bin/echo", ["milo-helper-ready"])]).succeeded
    }

    private func failure(_ message: String, termination: CommandTermination) -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: message, termination: termination)
    }
}
