import Foundation

public struct SettingsSnapshot: Sendable, Equatable {
    public let launchesAtLogin: Bool

    public init(launchesAtLogin: Bool) {
        self.launchesAtLogin = launchesAtLogin
    }
}
