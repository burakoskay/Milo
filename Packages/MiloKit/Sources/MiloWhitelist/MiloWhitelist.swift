import Foundation

public struct WhitelistSnapshot: Sendable, Equatable {
    public let processNames: [String]

    public init(processNames: [String]) {
        self.processNames = processNames
    }
}
