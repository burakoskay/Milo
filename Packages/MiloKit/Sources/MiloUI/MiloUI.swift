import Foundation

public struct MiloUIState: Sendable, Equatable {
    public let isMenuBarVisible: Bool

    public init(isMenuBarVisible: Bool) {
        self.isMenuBarVisible = isMenuBarVisible
    }
}
