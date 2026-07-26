import Foundation

public struct LicenseSnapshot: Equatable, Sendable {
    public let isPro: Bool
    public let productEntitlements: [String]
    public let signatureSetVersion: String?
    public let issuedAt: Date?
    public let expiresAt: Date?
    public let userID: UUID?
    public let licenseID: UUID?
    public let deviceKeyID: UUID?
    public let releaseChannel: String?
    public let updateEntitledUntil: Date?

    public init(
        isPro: Bool,
        productEntitlements: [String] = [],
        signatureSetVersion: String? = nil,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        userID: UUID? = nil,
        licenseID: UUID? = nil,
        deviceKeyID: UUID? = nil,
        releaseChannel: String? = nil,
        updateEntitledUntil: Date? = nil
    ) {
        self.isPro = isPro
        self.productEntitlements = productEntitlements
        self.signatureSetVersion = signatureSetVersion
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.userID = userID
        self.licenseID = licenseID
        self.deviceKeyID = deviceKeyID
        self.releaseChannel = releaseChannel
        self.updateEntitledUntil = updateEntitledUntil
    }

    public static let locked = LicenseSnapshot(isPro: false)
}
