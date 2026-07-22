import Foundation

public struct StatsSnapshot: Sendable, Equatable {
    public let detectedProcessCount: Int

    public init(detectedProcessCount: Int) {
        self.detectedProcessCount = detectedProcessCount
    }
}
