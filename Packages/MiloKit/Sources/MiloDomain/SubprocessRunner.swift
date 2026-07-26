import Darwin
import Foundation

public enum MiloSubprocessTermination: Equatable, Sendable {
    case exited
    case signaled(Int32)
    case timedOut
    case cancelled
    case outputLimitExceeded
    case launchFailed(Int32)
    case inputOutputFailed(Int32)
}

public struct MiloSubprocessResult: Equatable, Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data
    public let termination: MiloSubprocessTermination

    public init(
        status: Int32,
        standardOutput: Data,
        standardError: Data,
        termination: MiloSubprocessTermination
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
    }
}

/// Runs an executable in a private process group with bounded output and execution time.
public enum MiloSubprocessRunner {
    private static let pollIntervalMicroseconds: useconds_t = 10_000
    private static let cleanupLimit: Duration = .seconds(1)

    /// Runs an executable without invoking a shell and terminates its process group on any resource limit.
    public static func run(
        executable: String,
        arguments: [String],
        maximumOutputBytes: Int,
        deadline: Duration,
        cancellationRequested: @Sendable () -> Bool = { false }
    ) -> MiloSubprocessResult {
        guard maximumOutputBytes > 0, deadline > .zero else {
            return failure(termination: .launchFailed(EINVAL))
        }

        let output: MiloBoundedCommandOutput
        do {
            output = try MiloBoundedCommandOutput(maximumBytes: maximumOutputBytes)
        } catch {
            return failure(termination: .launchFailed(EINVAL))
        }

        let standardOutputPipeResult = makePipe()
        guard standardOutputPipeResult.errorCode == 0 else {
            return failure(termination: .launchFailed(standardOutputPipeResult.errorCode))
        }
        let standardOutputPipe = standardOutputPipeResult.descriptors
        let standardErrorPipeResult = makePipe()
        guard standardErrorPipeResult.errorCode == 0 else {
            closeDescriptors(standardOutputPipe)
            return failure(termination: .launchFailed(standardErrorPipeResult.errorCode))
        }
        let standardErrorPipe = standardErrorPipeResult.descriptors

        let spawnResult = spawn(
            executable: executable,
            arguments: arguments,
            standardOutputPipe: standardOutputPipe,
            standardErrorPipe: standardErrorPipe
        )
        closeDescriptor(standardOutputPipe[1])
        closeDescriptor(standardErrorPipe[1])

        guard case let .success(processIdentifier) = spawnResult else {
            closeDescriptor(standardOutputPipe[0])
            closeDescriptor(standardErrorPipe[0])
            if case let .failure(errorCode) = spawnResult {
                return failure(termination: .launchFailed(errorCode))
            }
            return failure(termination: .launchFailed(EINVAL))
        }

        let nonblockingError = configureNonblocking([
            standardOutputPipe[0],
            standardErrorPipe[0]
        ])
        guard nonblockingError == 0 else {
            terminateProcessGroup(processIdentifier)
            reap(processIdentifier)
            closeDescriptor(standardOutputPipe[0])
            closeDescriptor(standardErrorPipe[0])
            return failure(termination: .inputOutputFailed(nonblockingError))
        }

        return supervise(
            processIdentifier: processIdentifier,
            descriptors: OutputDescriptors(
                standardOutput: standardOutputPipe[0],
                standardError: standardErrorPipe[0]
            ),
            initialOutput: output,
            deadline: deadline,
            cancellationRequested: cancellationRequested
        )
    }

    private enum SpawnResult {
        case success(pid_t)
        case failure(Int32)
    }

    private struct OutputDescriptors {
        let standardOutput: Int32
        let standardError: Int32
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        standardOutputPipe: [Int32],
        standardErrorPipe: [Int32]
    ) -> SpawnResult {
        var fileActions: posix_spawn_file_actions_t?
        let actionInitialization = posix_spawn_file_actions_init(&fileActions)
        guard actionInitialization == 0 else {
            return .failure(actionInitialization)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }

        let actionResults = [
            posix_spawn_file_actions_adddup2(&fileActions, standardOutputPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, standardErrorPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe[0]),
            posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe[1]),
            posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe[1])
        ]
        guard let actionError = actionResults.first(where: { $0 != 0 }) else {
            return spawnWithConfiguredActions(
                executable: executable,
                arguments: arguments,
                fileActions: &fileActions
            )
        }
        return .failure(actionError)
    }

    private static func spawnWithConfiguredActions(
        executable: String,
        arguments: [String],
        fileActions: inout posix_spawn_file_actions_t?
    ) -> SpawnResult {
        var attributes: posix_spawnattr_t?
        let attributeInitialization = posix_spawnattr_init(&attributes)
        guard attributeInitialization == 0 else {
            return .failure(attributeInitialization)
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        let flagResult = posix_spawnattr_setflags(&attributes, flags)
        guard flagResult == 0 else {
            return .failure(flagResult)
        }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupResult == 0 else {
            return .failure(groupResult)
        }

        let values = [executable] + arguments
        var allocatedArguments: [UnsafeMutablePointer<CChar>] = []
        allocatedArguments.reserveCapacity(values.count)
        for value in values {
            guard let allocated = strdup(value) else {
                allocatedArguments.forEach { free($0) }
                return .failure(ENOMEM)
            }
            allocatedArguments.append(allocated)
        }
        defer {
            allocatedArguments.forEach { free($0) }
        }

        var argumentVector = allocatedArguments.map(Optional.some)
        argumentVector.append(nil)
        var processIdentifier = pid_t()
        let spawnError = executable.withCString { executablePointer in
            argumentVector.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        return spawnError == 0 ? .success(processIdentifier) : .failure(spawnError)
    }

    private static func supervise(
        processIdentifier: pid_t,
        descriptors: OutputDescriptors,
        initialOutput: MiloBoundedCommandOutput,
        deadline: Duration,
        cancellationRequested: @Sendable () -> Bool
    ) -> MiloSubprocessResult {
        defer {
            closeDescriptor(descriptors.standardOutput)
            closeDescriptor(descriptors.standardError)
        }

        var output = initialOutput
        var standardOutputOpen = true
        var standardErrorOpen = true
        var waitStatus: Int32?
        let deadlineInstant = ContinuousClock.now.advanced(by: deadline)

        while true {
            let outputError = drain(
                descriptor: descriptors.standardOutput,
                stream: .standardOutput,
                isOpen: &standardOutputOpen,
                output: &output
            )
            guard outputError == 0 else {
                terminateProcessGroup(processIdentifier)
                reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
                return result(output: output, status: 74, termination: .inputOutputFailed(outputError))
            }
            let errorOutputError = drain(
                descriptor: descriptors.standardError,
                stream: .standardError,
                isOpen: &standardErrorOpen,
                output: &output
            )
            guard errorOutputError == 0 else {
                terminateProcessGroup(processIdentifier)
                reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
                return result(output: output, status: 74, termination: .inputOutputFailed(errorOutputError))
            }

            updateWaitStatus(processIdentifier, waitStatus: &waitStatus)
            if output.wasTruncated {
                terminateProcessGroup(processIdentifier)
                reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
                drainAfterTermination(
                    descriptors: descriptors,
                    output: &output
                )
                return result(output: output, status: 74, termination: .outputLimitExceeded)
            }
            if let waitStatus, !standardOutputOpen, !standardErrorOpen {
                return completedResult(waitStatus: waitStatus, output: output)
            }
            if cancellationRequested() {
                terminateProcessGroup(processIdentifier)
                reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
                drainAfterTermination(
                    descriptors: descriptors,
                    output: &output
                )
                return result(output: output, status: 130, termination: .cancelled)
            }
            if ContinuousClock.now >= deadlineInstant {
                terminateProcessGroup(processIdentifier)
                reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
                drainAfterTermination(
                    descriptors: descriptors,
                    output: &output
                )
                return result(output: output, status: 124, termination: .timedOut)
            }
            usleep(pollIntervalMicroseconds)
        }
    }

    private static func drain(
        descriptor: Int32,
        stream: MiloCommandOutputStream,
        isOpen: inout Bool,
        output: inout MiloBoundedCommandOutput
    ) -> Int32 {
        guard isOpen else {
            return 0
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = read(descriptor, &buffer, buffer.count)
            if bytesRead > 0 {
                output.append(Data(buffer.prefix(bytesRead)), to: stream)
                continue
            }
            if bytesRead == 0 {
                isOpen = false
                return 0
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return 0
            }
            return errno
        }
    }

    private static func drainAfterTermination(
        descriptors: OutputDescriptors,
        output: inout MiloBoundedCommandOutput
    ) {
        var standardOutputOpen = true
        var standardErrorOpen = true
        let cleanupDeadline = ContinuousClock.now.advanced(by: cleanupLimit)
        while standardOutputOpen || standardErrorOpen, ContinuousClock.now < cleanupDeadline {
            let standardOutputError = drain(
                descriptor: descriptors.standardOutput,
                stream: .standardOutput,
                isOpen: &standardOutputOpen,
                output: &output
            )
            let standardErrorError = drain(
                descriptor: descriptors.standardError,
                stream: .standardError,
                isOpen: &standardErrorOpen,
                output: &output
            )
            if standardOutputError != 0 || standardErrorError != 0 {
                return
            }
            if standardOutputOpen || standardErrorOpen {
                usleep(pollIntervalMicroseconds)
            }
        }
    }

    private static func updateWaitStatus(_ processIdentifier: pid_t, waitStatus: inout Int32?) {
        guard waitStatus == nil else {
            return
        }
        var status: Int32 = 0
        while true {
            let waitResult = waitpid(processIdentifier, &status, WNOHANG)
            if waitResult == processIdentifier {
                waitStatus = status
                return
            }
            if waitResult == 0 {
                return
            }
            if waitResult == -1, errno == EINTR {
                continue
            }
            if waitResult == -1, errno == ECHILD {
                waitStatus = 0
            }
            return
        }
    }

    private static func reapIfNeeded(_ processIdentifier: pid_t, waitStatus: inout Int32?) {
        guard waitStatus == nil else {
            return
        }
        let cleanupDeadline = ContinuousClock.now.advanced(by: cleanupLimit)
        while ContinuousClock.now < cleanupDeadline {
            updateWaitStatus(processIdentifier, waitStatus: &waitStatus)
            guard waitStatus == nil else {
                return
            }
            usleep(pollIntervalMicroseconds)
        }
    }

    private static func reap(_ processIdentifier: pid_t) {
        var waitStatus: Int32?
        reapIfNeeded(processIdentifier, waitStatus: &waitStatus)
    }

    private static func terminateProcessGroup(_ processIdentifier: pid_t) {
        let processGroup = -processIdentifier
        if kill(processGroup, SIGTERM) == -1, errno != ESRCH {
            kill(processIdentifier, SIGTERM)
        }
        usleep(100_000)
        if kill(processGroup, SIGKILL) == -1, errno != ESRCH {
            kill(processIdentifier, SIGKILL)
        }
    }

    private static func configureNonblocking(_ descriptors: [Int32]) -> Int32 {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags != -1 else {
                return errno
            }
            guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                return errno
            }
        }
        return 0
    }

    private static func makePipe() -> (descriptors: [Int32], errorCode: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            return ([], errno)
        }

        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let relocated = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard relocated != -1 else {
                let errorCode = errno
                closeDescriptors(descriptors)
                return ([], errorCode)
            }
            closeDescriptor(descriptors[index])
            descriptors[index] = relocated
        }
        return (descriptors, 0)
    }

    private static func completedResult(
        waitStatus: Int32,
        output: MiloBoundedCommandOutput
    ) -> MiloSubprocessResult {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return result(output: output, status: (waitStatus >> 8) & 0xFF, termination: .exited)
        }
        return result(output: output, status: 128 + signal, termination: .signaled(signal))
    }

    private static func result(
        output: MiloBoundedCommandOutput,
        status: Int32,
        termination: MiloSubprocessTermination
    ) -> MiloSubprocessResult {
        MiloSubprocessResult(
            status: status,
            standardOutput: output.standardOutput,
            standardError: output.standardError,
            termination: termination
        )
    }

    private static func failure(termination: MiloSubprocessTermination) -> MiloSubprocessResult {
        MiloSubprocessResult(
            status: 126,
            standardOutput: Data(),
            standardError: Data(),
            termination: termination
        )
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        descriptors.forEach(closeDescriptor(_:))
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else {
            return
        }
        while close(descriptor) == -1, errno == EINTR {}
    }
}
