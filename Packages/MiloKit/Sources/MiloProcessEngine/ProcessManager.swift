import Foundation
import MiloDomain
import MiloHardening

public final class ProcessManager: @unchecked Sendable {
    private var scanCounter: UInt64 = 0

    public init() {}

    public func scanCycleDidAdvance() -> Bool {
        scanCounter &+= 1
        guard scanCounter & 0xFFFF == 0 else { return true }
        return MiloIntegrity.check(.scanLoop)
    }
}
