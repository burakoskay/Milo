import Foundation
import MiloDomain
import Testing

@Suite("Typed operation lifecycle")
struct OperationStateTests {
    @Test("all planned operation domains remain explicit")
    func operationDomains() {
        #expect(MiloOperationKind.allCases.count == 13)
        #expect(Set(MiloOperationKind.allCases.map(\.rawValue)).count == 13)
    }

    @Test("success is terminal and cannot be overwritten")
    func terminalSuccess() {
        var lifecycle = MiloOperationLifecycle<Int>()
        let context = lifecycle.begin(
            operation: .scan,
            startedAt: Date(timeIntervalSince1970: 10),
            deadline: Date(timeIntervalSince1970: 20)
        )

        let firstSuccessAccepted = lifecycle.succeed(2, for: context)
        #expect(firstSuccessAccepted)
        #expect(lifecycle.state.isTerminal)
        let secondSuccessAccepted = lifecycle.succeed(3, for: context)
        #expect(!secondSuccessAccepted)
        #expect(lifecycle.state == .succeeded(context, 2))
    }

    @Test("late results from a superseded generation are rejected")
    func staleGeneration() {
        var lifecycle = MiloOperationLifecycle<String>()
        let stale = lifecycle.begin(operation: .scan, startedAt: .distantPast)
        let current = lifecycle.begin(operation: .scan, startedAt: .distantFuture)

        let staleAccepted = lifecycle.succeed("stale", for: stale)
        let currentAccepted = lifecycle.succeed("current", for: current)
        #expect(!staleAccepted)
        #expect(currentAccepted)
        #expect(lifecycle.state == .succeeded(current, "current"))
    }

    @Test("failure domain must match its running operation")
    func failureDomain() {
        var lifecycle = MiloOperationLifecycle<Int>()
        let context = lifecycle.begin(operation: .update, startedAt: .distantPast)
        let wrongFailure = MiloOperationFailure(
            operation: .license,
            code: .authentication,
            message: "License authentication failed."
        )
        let correctFailure = MiloOperationFailure(
            operation: .update,
            code: .transport,
            message: "The update service could not be reached.",
            recovery: "Check your connection and try again."
        )

        let wrongFailureAccepted = lifecycle.fail(wrongFailure, for: context)
        let correctFailureAccepted = lifecycle.fail(correctFailure, for: context)
        #expect(!wrongFailureAccepted)
        #expect(correctFailureAccepted)
        #expect(correctFailure.stableCode == "milo.update.transport")
        #expect(correctFailure.errorDescription == correctFailure.message)
        #expect(correctFailure.recoverySuggestion == correctFailure.recovery)
    }

    @Test("cancellation is an explicit terminal state")
    func cancellation() {
        var lifecycle = MiloOperationLifecycle<VoidResult>()
        let context = lifecycle.begin(operation: .export, startedAt: .distantPast)

        let cancellationAccepted = lifecycle.cancel(context)
        #expect(cancellationAccepted)
        #expect(lifecycle.state == .cancelled(context))
        #expect(lifecycle.state.isTerminal)
    }
}

private struct VoidResult: Equatable, Sendable {}
