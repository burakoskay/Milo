import Foundation
import CryptoKit
import IOKit
import MiloUpdates

enum LicenseVerificationError: LocalizedError {
    case base64DecodeFailed
    case invalidPublicKey
    case invalidSignature
    case malformedSignedPayload
    case deviceMismatch
    case stalePayload
    case futurePayload
    case expiredPayload
    case deviceEnrollmentRequired

    var errorDescription: String? {
        switch self {
        case .base64DecodeFailed:
            return "Base64 decode failed."
        case .invalidPublicKey:
            return "Invalid embedded public key."
        case .invalidSignature:
            return "Cryptographic signature verification failed."
        case .malformedSignedPayload:
            return "Malformed signed license payload."
        case .deviceMismatch:
            return "Device ID mismatch. Cloned license detected."
        case .stalePayload:
            return "Signed license payload is stale."
        case .futurePayload:
            return "Signed license payload was issued in the future."
        case .expiredPayload:
            return "Signed license payload has expired."
        case .deviceEnrollmentRequired:
            return "Device enrollment is required before refreshing the license."
        }
    }
}

/// Represents the securely signed Monomacaw License Protocol v1 envelope.
struct LicensePayload: Codable {
    let protocolVersion: Int
    let appId: String
    let userId: String
    let licenseId: String
    let deviceId: String
    let deviceKeyId: String
    let subscriptionStatus: String
    let serverNow: Date?
    let issuedAt: Date
    let expiresAt: Date
    let entitlements: [String]
    let maxDevices: Int
    let updateEntitledUntil: Date?
    let releaseChannel: String
    let policyRevision: Int
    let blocklistRevision: Int?
    let killSwitches: [String]?
}

private struct SignedLicenseEnvelope: Codable {
    let payload: String?
    let envelope: String?
    let signature: String

    func encodedPayload() throws -> String {
        if let payload {
            return payload
        }
        if let envelope {
            return envelope
        }
        throw LicenseVerificationError.malformedSignedPayload
    }
}

/// Zero-Debt License Manager
/// Handles hardware fingerprinting, Supabase API communication, and Ed25519 verification.
final class LicenseManager: ObservableObject, @unchecked Sendable {
    static let shared = LicenseManager()

    @Published private(set) var isSubscribed: Bool = false
    @Published private(set) var isVerifying: Bool = false
    @Published private(set) var licenseError: String?
    @Published private(set) var updateChecksAvailable: Bool = false

    // The single Public Key embedded in the app. The Private Key NEVER leaves the Supabase server.
    private let publicKeyBase64 = Secrets.ed25519PublicKeyBase64
    private let maximumPayloadAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumFutureSkew: TimeInterval = 5 * 60

    private let supabaseURL = BackendConfiguration.supabaseURL
    private var currentUpdateFeedState: AuthenticatedUpdateFeedState?
    private var latestSignatureSetVersion = "unknown"
    private var latestBlocklistRevision = 0

    private init() {
        if Self.localDevelopmentUnlockEnabled {
            applyLocalDevelopmentUnlockState()
        }
    }

    /// Extracts a highly unique, stable device fingerprint without triggering privacy warnings
    func generateDeviceFingerprint(userID: String) -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        guard let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String else {
            return nil
        }

        // Hash the serial number so the raw serial never leaves the device
        let rawString = "\(serialNumberAsCFString)\u{0}\(userID)"
        let data = Data(rawString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Fetches the license state and signed cloud signatures from Supabase
    func verifyLicenseAndFetchSignatures(sessionToken: String, userID: String) async {
        if Self.localDevelopmentUnlockEnabled {
            await MainActor.run {
                self.applyLocalDevelopmentUnlockState()
            }
            return
        }

        await MainActor.run { isVerifying = true }
        defer { Task { @MainActor in isVerifying = false } }

        guard let deviceId = generateDeviceFingerprint(userID: userID) else {
            await setLicenseState(isValid: false, error: "Hardware fingerprint generation failed.")
            return
        }

        guard let url = URL(string: "\(supabaseURL)/functions/v1/license-refresh") else {
            await setLicenseState(isValid: false, error: "Invalid backend URL.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let requestBody = try makeLicenseRequestBody(deviceId: deviceId)
            request.httpBody = requestBody.data
            requestBody.headers.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await setLicenseState(isValid: false, error: "Server rejected the verification request.")
                return
            }
            if httpResponse.statusCode != 200 {
                if httpResponse.statusCode >= 500, await applyCachedLicenseEnvelope(userID: userID) {
                    return
                }
                await setLicenseState(isValid: false, error: "Server rejected the verification request.")
                return
            }

            let envelope = try JSONDecoder().decode(SignedLicenseEnvelope.self, from: data)
            let payload = try verifyCryptographicSignature(envelope: envelope, userID: userID)
            try cacheVerifiedEnvelope(envelope)
            await applyVerifiedPayload(payload)
        } catch {
            if await applyCachedLicenseEnvelope(userID: userID) {
                return
            }
            await setLicenseState(isValid: false, error: "Network or decoding error: \(error.localizedDescription)")
        }
    }

    /// Verifies the Ed25519 Signature.
    /// If an attacker modifies the payload (e.g., changes 'expired' to 'active'),
    /// the cryptographic signature check will fail and throw an error.
    private func verifyCryptographicSignature(envelope: SignedLicenseEnvelope, userID: String) throws -> LicensePayload {
        let encodedPayload = try envelope.encodedPayload()
        guard let payloadData = Self.decodeBase64Envelope(encodedPayload),
              let signatureData = Self.decodeBase64Envelope(envelope.signature),
              let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw LicenseVerificationError.base64DecodeFailed
        }

        guard keyData.count == 32 else {
            throw LicenseVerificationError.invalidPublicKey
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        let isValid = publicKey.isValidSignature(signatureData, for: payloadData)

        if !isValid {
            throw LicenseVerificationError.invalidSignature
        }

        let payload: LicensePayload
        do {
            payload = try Self.licensePayloadDecoder.decode(LicensePayload.self, from: payloadData)
        } catch {
            throw LicenseVerificationError.malformedSignedPayload
        }

        guard let expectedDeviceId = generateDeviceFingerprint(userID: userID),
              Self.constantTimeEquals(Data(payload.deviceId.utf8), Data(expectedDeviceId.utf8)) else {
            throw LicenseVerificationError.deviceMismatch
        }

        try validatePayloadFreshness(payload)
        return payload
    }

    private func validatePayloadFreshness(_ payload: LicensePayload) throws {
        guard payload.protocolVersion == 1 else {
            throw LicenseVerificationError.malformedSignedPayload
        }

        let now = Date()
        guard payload.issuedAt.timeIntervalSince(now) <= maximumFutureSkew else {
            throw LicenseVerificationError.futurePayload
        }

        guard now.timeIntervalSince(payload.issuedAt) <= maximumPayloadAge else {
            throw LicenseVerificationError.stalePayload
        }

        guard payload.expiresAt > now else {
            throw LicenseVerificationError.expiredPayload
        }

    }

    @MainActor
    private func applyVerifiedPayload(_ payload: LicensePayload) {
        let isSubscriptionActive = payload.subscriptionStatus == "active" || payload.subscriptionStatus == "trial"
        isSubscribed = isSubscriptionActive
        licenseError = nil
        latestSignatureSetVersion = String(payload.policyRevision)
        latestBlocklistRevision = payload.blocklistRevision ?? latestBlocklistRevision
        currentUpdateFeedState = Self.makeUpdateFeedState(payload: payload)
        updateChecksAvailable = currentUpdateFeedState != nil
        CloudSignatureManager.shared.clearCloudSignatures()
    }

    private func applyCachedLicenseEnvelope(userID: String) async -> Bool {
        do {
            guard let envelope = try readCachedLicenseEnvelope() else { return false }
            let payload = try verifyCryptographicSignature(envelope: envelope, userID: userID)
            await applyVerifiedPayload(payload)
            return true
        } catch {
            await MainActor.run {
                self.licenseError = "Cached license rejected: \(error.localizedDescription)"
            }
            return false
        }
    }

    private static let licensePayloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = LicenseManager.decodeISO8601Date(string) {
                return date
            }
            throw LicenseVerificationError.malformedSignedPayload
        }
        return decoder
    }()

    private static func decodeISO8601Date(_ string: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func cacheVerifiedEnvelope(_ envelope: SignedLicenseEnvelope) throws {
        let url = try cacheURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(envelope)
        let temporaryURL = directory.appendingPathComponent("license-envelope.json.tmp")
        try data.write(to: temporaryURL, options: [.atomic])

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: url)
        } catch {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                try FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func readCachedLicenseEnvelope() throws -> SignedLicenseEnvelope? {
        let url = try cacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SignedLicenseEnvelope.self, from: data)
    }

    private func clearCachedLicenseEnvelope() {
        do {
            let url = try cacheURL()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            licenseError = "Failed to clear cached license: \(error.localizedDescription)"
        }
    }

    private func cacheURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Milo", isDirectory: true)
            .appendingPathComponent("license-envelope.json")
    }

    @MainActor
    private func setLicenseState(isValid: Bool, error: String?) {
        if Self.localDevelopmentUnlockEnabled {
            applyLocalDevelopmentUnlockState()
            return
        }

        self.isSubscribed = isValid
        self.licenseError = error
        self.currentUpdateFeedState = nil
        self.updateChecksAvailable = false
        self.latestSignatureSetVersion = "unknown"
        self.latestBlocklistRevision = 0
        if !isValid {
            CloudSignatureManager.shared.clearCloudSignatures()
        }
    }

    @MainActor
    func clearLocalLicenseState() {
        isSubscribed = false
        licenseError = nil
        currentUpdateFeedState = nil
        updateChecksAvailable = false
        latestSignatureSetVersion = "unknown"
        latestBlocklistRevision = 0
        clearCachedLicenseEnvelope()
        CloudSignatureManager.shared.clearCloudSignatures()
        if Self.localDevelopmentUnlockEnabled {
            applyLocalDevelopmentUnlockState()
        }
    }

    func authenticatedUpdateFeedURL() throws -> URL {
        guard let state = currentUpdateFeedState else {
            throw LicenseVerificationError.deviceEnrollmentRequired
        }
        return try AuthenticatedUpdateFeed.makeURL(
            baseURL: try updateFeedBaseURL(),
            state: state
        )
    }

    private func makeLicenseRequestBody(deviceId: String) throws -> (data: Data, headers: [String: String]) {
        let body: [String: Any] = [
            "protocolVersion": 1,
            "appId": "milo",
            "deviceId": deviceId,
            "appVersion": Self.bundleString("CFBundleShortVersionString") ?? "2.0.0",
            "macosVersion": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return (data, [:])
    }

    private func updateFeedBaseURL() throws -> URL {
        if let value = Self.bundleString("SUFeedURL"),
           let url = URL(string: value),
           url.scheme == "https" {
            return url
        }
        guard let fallback = URL(string: "\(supabaseURL)/functions/v1/update-feed") else {
            throw AuthenticatedUpdateFeedError.invalidBaseURL
        }
        return fallback
    }

    private static func makeUpdateFeedState(payload: LicensePayload) -> AuthenticatedUpdateFeedState? {
        guard payload.protocolVersion == 1,
              payload.appId == "milo",
              !payload.licenseId.isEmpty,
              payload.deviceId.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return AuthenticatedUpdateFeedState(appId: payload.appId, licenseId: payload.licenseId, deviceHash: payload.deviceId)
    }

    private func applyLocalDevelopmentUnlockState() {
        isSubscribed = true
        isVerifying = false
        licenseError = nil
        currentUpdateFeedState = nil
        updateChecksAvailable = false
        latestSignatureSetVersion = "local-development"
        latestBlocklistRevision = 0
    }

    private static var localDevelopmentUnlockEnabled: Bool {
        #if DEBUG || AD_HOC
        return true
        #else
        return false
        #endif
    }
}
extension LicenseManager {
    private static func decodeBase64Envelope(_ encoded: String) -> Data? {
        if let standard = Data(base64Encoded: encoded) {
            return standard
        }
        var normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
