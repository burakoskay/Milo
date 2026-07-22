import Foundation

public struct DebloatPlan: Sendable, Equatable {
    public let commandCount: Int

    public init(commandCount: Int) {
        self.commandCount = commandCount
    }
}
