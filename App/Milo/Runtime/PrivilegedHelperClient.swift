import Foundation
import MiloDomain

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

    /// A helper reply, paired with the pid of the peer that produced it.
    ///
    /// The pid travels with the reply because it is only meaningful once the connection is
    /// established — launchd starts the helper on demand, so a pid read before the first round
    /// trip identifies nothing.
    private struct HelperResponse {
        let result: CommandResult
        let peerProcessIdentifier: pid_t
    }

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
        return run(encodedCommands: encodedCommands).result
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
        return run(encodedCommands: encodedCommands as NSArray).result
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

    private func run(encodedCommands: NSArray) -> HelperResponse {

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
            return HelperResponse(
                result: failure("Milo could not connect to its background helper.", termination: .launchFailed(0)),
                peerProcessIdentifier: 0
            )
        }

        proxy.execute(encodedCommands) { reply in
            lockedReply.store(reply)
            completion.signal()
        }

        let waitResult = completion.wait(timeout: .now() + 30)
        // Read before invalidating: an invalidated connection has no peer to report.
        let peerProcessIdentifier = connection.processIdentifier
        connection.invalidate()
        guard waitResult == .success, let reply = lockedReply.load() else {
            return HelperResponse(
                result: failure("The Milo background helper did not respond in time.", termination: .timedOut),
                peerProcessIdentifier: peerProcessIdentifier
            )
        }

        guard let statusNumber = reply["status"] as? NSNumber,
              let stdout = reply["stdout"] as? String,
              let stderr = reply["stderr"] as? String else {
            return HelperResponse(
                result: failure(
                    "The Milo background helper returned an invalid response.",
                    termination: .invalidOutputEncoding
                ),
                peerProcessIdentifier: peerProcessIdentifier
            )
        }

        let status = statusNumber.int32Value
        return HelperResponse(
            result: CommandResult(status: status, stdout: stdout, stderr: stderr),
            peerProcessIdentifier: peerProcessIdentifier
        )
    }

    /// The existing allowlisted, non-mutating round trip. Reaching the helper at all is the
    /// health check; it is also what establishes the connection the freshness probe needs.
    ///
    /// Built per call rather than stored: `NSArray` is not `Sendable`, and one shared instance
    /// handed to concurrent requests is exactly the shared mutable state this client avoids.
    private func healthCheckCommands() -> NSArray {
        [
            [
                "executable": "/bin/echo",
                "arguments": ["milo-helper-ready"]
            ] as NSDictionary
        ] as NSArray
    }

    func healthCheck() -> Bool {
        run(encodedCommands: healthCheckCommands()).result.succeeded
    }

    /// Whether the helper answering Milo is running the code installed in this bundle.
    ///
    /// One round trip serves both purposes: the reply proves a helper is answering, and the pid
    /// of the peer that produced it identifies the process to inspect. A helper that fails the
    /// health check is not reported as stale — that it is unreachable is
    /// `MiloHelperStatus`'s question, and answering it here would turn "Milo could not ask" into
    /// "your helper is wrong".
    func freshness() -> MiloHelperFreshness {
        let response = run(encodedCommands: healthCheckCommands())
        guard response.result.succeeded else {
            return .undetermined(.helperNotAnswering)
        }
        return HelperFreshnessInspector.freshness(
            ofHelperWithProcessIdentifier: response.peerProcessIdentifier
        )
    }

    private func failure(_ message: String, termination: CommandTermination) -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: message, termination: termination)
    }
}
