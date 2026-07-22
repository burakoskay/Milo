import Foundation

public struct PaywallState: Sendable, Equatable {
    public let isPresented: Bool

    public init(isPresented: Bool) {
        self.isPresented = isPresented
    }
}
