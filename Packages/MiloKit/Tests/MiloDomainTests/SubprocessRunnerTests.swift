import Darwin
import Foundation
import MiloDomain
import Testing

@Suite("Bounded subprocess runner", .serialized)
struct SubprocessRunnerTests {
    @Test("normal exit preserves status and output")
    func normalExit() {
        let result = MiloSubprocessRunner.run(
            executable: "/bin/echo",
            arguments: ["milo"],
            maximumOutputBytes: 1_024,
            deadline: .seconds(1)
        )

        #expect(result.termination == .exited)
        #expect(result.status == 0)
        #expect(result.standardOutput == Data("milo\n".utf8))
        #expect(result.standardError.isEmpty)
    }

    @Test("deadline terminates the private process group")
    func deadlineTerminatesProcessGroup() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = MiloSubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep 10 & child=$!; echo $child; wait"],
            maximumOutputBytes: 1_024,
            deadline: .milliseconds(75)
        )

        #expect(result.termination == .timedOut)
        #expect(result.status == 124)
        #expect(started.duration(to: clock.now) < .seconds(1))

        guard let outputString = String(bytes: result.standardOutput, encoding: .utf8) else {
            Issue.record("Expected UTF-8 child process output")
            return
        }
        let output = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descendantIdentifier = Int32(output) else {
            Issue.record("Expected the child process identifier in stdout")
            return
        }

        for _ in 0..<50 where processExists(descendantIdentifier) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!processExists(descendantIdentifier))
    }

    @Test("output overflow terminates a streaming process")
    func outputOverflowTerminatesProcess() {
        let clock = ContinuousClock()
        let started = clock.now
        let result = MiloSubprocessRunner.run(
            executable: "/usr/bin/yes",
            arguments: [],
            maximumOutputBytes: 1_024,
            deadline: .seconds(2)
        )

        #expect(result.termination == .outputLimitExceeded)
        #expect(result.status == 74)
        #expect(result.standardOutput.count + result.standardError.count == 1_024)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test("cancellation terminates the private process group")
    func cancellationTerminatesProcessGroup() {
        let cancellation = CancellationProbe(cancelAfterChecks: 3)
        let result = MiloSubprocessRunner.run(
            executable: "/bin/sleep",
            arguments: ["10"],
            maximumOutputBytes: 1_024,
            deadline: .seconds(2),
            cancellationRequested: cancellation.isCancellationRequested
        )

        #expect(result.termination == .cancelled)
        #expect(result.status == 130)
    }

    private func processExists(_ processIdentifier: pid_t) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}

/// SAFETY: `checks` is read and mutated only while `lock` is held.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterChecks: Int
    private var checks = 0

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = cancelAfterChecks
    }

    func isCancellationRequested() -> Bool {
        lock.lock()
        checks += 1
        let shouldCancel = checks >= cancelAfterChecks
        lock.unlock()
        return shouldCancel
    }
}
