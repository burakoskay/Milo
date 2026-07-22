import Foundation

public struct PermissionsSnapshot: Sendable, Equatable {
    public let privilegedOperationsAvailable: Bool

    public init(privilegedOperationsAvailable: Bool) {
        self.privilegedOperationsAvailable = privilegedOperationsAvailable
    }
}
