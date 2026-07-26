import Foundation

/// Every user-visible or security-sensitive operation owned by Milo.
public enum MiloOperationKind: String, CaseIterable, Sendable {
    case scan
    case processAction = "process-action"
    case launchd
    case helper
    case license
    case pairing
    case paymentHandoff = "payment-handoff"
    case update
    case policySync = "policy-sync"
    case persistence
    case tuning
    case export
    case notification
}

/// Stable, support-safe failure categories. Sensitive underlying details belong only in private logs.
public struct MiloOperationFailure: Error, Equatable, LocalizedError, Sendable {
    public enum Code: String, CaseIterable, Sendable {
        case timedOut = "timed-out"
        case permissionDenied = "permission-denied"
        case unsupported
        case unavailable
        case invalidInput = "invalid-input"
        case policyDenied = "policy-denied"
        case capabilityDenied = "capability-denied"
        case notFound = "not-found"
        case conflict
        case partial
        case transport
        case authentication
        case integrity
        case storage
        case system
        case unknown
    }

    public let operation: MiloOperationKind
    public let code: Code
    public let message: String
    public let recovery: String?

    public var stableCode: String {
        "milo.\(operation.rawValue).\(code.rawValue)"
    }

    public var errorDescription: String? {
        message
    }

    public var recoverySuggestion: String? {
        recovery
    }

    public init(
        operation: MiloOperationKind,
        code: Code,
        message: String,
        recovery: String? = nil
    ) {
        self.operation = operation
        self.code = code
        self.message = message
        self.recovery = recovery
    }
}

public struct MiloOperationContext: Equatable, Sendable {
    public let id: UUID
    public let operation: MiloOperationKind
    public let startedAt: Date
    public let deadline: Date?

    public init(
        id: UUID = UUID(),
        operation: MiloOperationKind,
        startedAt: Date,
        deadline: Date? = nil
    ) {
        self.id = id
        self.operation = operation
        self.startedAt = startedAt
        self.deadline = deadline
    }
}

public enum MiloOperationState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case running(MiloOperationContext)
    case succeeded(MiloOperationContext, Value)
    case partiallySucceeded(MiloOperationContext, Value, MiloOperationFailure)
    case failed(MiloOperationContext, MiloOperationFailure)
    case cancelled(MiloOperationContext)

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    public var isTerminal: Bool {
        switch self {
        case .idle, .running:
            return false
        case .succeeded, .partiallySucceeded, .failed, .cancelled:
            return true
        }
    }

    public var context: MiloOperationContext? {
        switch self {
        case .idle:
            return nil
        case .running(let context),
             .succeeded(let context, _),
             .partiallySucceeded(let context, _, _),
             .failed(let context, _),
             .cancelled(let context):
            return context
        }
    }
}

/// Owns one operation generation and rejects late results from superseded work.
public struct MiloOperationLifecycle<Value: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var state: MiloOperationState<Value> = .idle

    public init() {}

    @discardableResult
    public mutating func begin(
        operation: MiloOperationKind,
        startedAt: Date,
        deadline: Date? = nil,
        id: UUID = UUID()
    ) -> MiloOperationContext {
        let context = MiloOperationContext(
            id: id,
            operation: operation,
            startedAt: startedAt,
            deadline: deadline
        )
        state = .running(context)
        return context
    }

    @discardableResult
    public mutating func succeed(_ value: Value, for context: MiloOperationContext) -> Bool {
        guard accepts(context) else {
            return false
        }
        state = .succeeded(context, value)
        return true
    }

    @discardableResult
    public mutating func partiallySucceed(
        _ value: Value,
        failure: MiloOperationFailure,
        for context: MiloOperationContext
    ) -> Bool {
        guard accepts(context), failure.operation == context.operation else {
            return false
        }
        state = .partiallySucceeded(context, value, failure)
        return true
    }

    @discardableResult
    public mutating func fail(
        _ failure: MiloOperationFailure,
        for context: MiloOperationContext
    ) -> Bool {
        guard accepts(context), failure.operation == context.operation else {
            return false
        }
        state = .failed(context, failure)
        return true
    }

    @discardableResult
    public mutating func cancel(_ context: MiloOperationContext) -> Bool {
        guard accepts(context) else {
            return false
        }
        state = .cancelled(context)
        return true
    }

    private func accepts(_ context: MiloOperationContext) -> Bool {
        guard case .running(let current) = state else {
            return false
        }
        return current == context
    }
}
