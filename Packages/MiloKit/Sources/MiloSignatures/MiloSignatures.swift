import Foundation

public struct CloudSignatureSyncResult: Sendable, Equatable {
    public let signatureSetVersion: String
    public let acceptedRuleCount: Int

    public init(signatureSetVersion: String, acceptedRuleCount: Int) {
        self.signatureSetVersion = signatureSetVersion
        self.acceptedRuleCount = acceptedRuleCount
    }
}
