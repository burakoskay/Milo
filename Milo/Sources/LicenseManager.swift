import Foundation
import CryptoKit
import IOKit

enum LicenseVerificationError: LocalizedError {
    case base64DecodeFailed
    case invalidPublicKey
    case invalidSignature
    case malformedSignedPayload
    case deviceMismatch
    case stalePayload
    case futurePayload
    case expiredPayload
    case revokedSignatureSet

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
        case .revokedSignatureSet:
            return "Signed telemetry signature set has been revoked."
        }
    }
}

/// Represents the securely signed payload from Supabase
struct LicensePayload: Codable {
    let schemaVersion: Int
    let deviceId: String
    let subscriptionStatus: String // "active", "trial", "expired"
    let trialEndDate: Date?
    let nextBillingDate: Date?
    let issuedAt: Date
    let expiresAt: Date
    let signatureSetVersion: String
    let revokedSignatureSetVersions: [String]
    let cloudSignatures: [TelemetrySignature]
}

private struct SignedLicenseEnvelope: Codable {
    let payload: String
    let signature: String
}

/// Zero-Debt License Manager
/// Handles hardware fingerprinting, Supabase API communication, and Ed25519 verification.
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var isSubscribed: Bool = false
    @Published private(set) var isVerifying: Bool = false
    @Published private(set) var licenseError: String?

    // The single Public Key embedded in the app. The Private Key NEVER leaves the Supabase server.
    private let publicKeyBase64 = Secrets.ed25519PublicKeyBase64
    private let maximumPayloadAge: TimeInterval = 7 * 24 * 60 * 60
    private let maximumFutureSkew: TimeInterval = 5 * 60

    private let supabaseURL = Secrets.supabaseURL

    private init() {}

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
        await MainActor.run { isVerifying = true }
        defer { Task { @MainActor in isVerifying = false } }

        guard let deviceId = generateDeviceFingerprint(userID: userID) else {
            await setLicenseState(isValid: false, error: "Hardware fingerprint generation failed.")
            return
        }

        guard let url = URL(string: "\(supabaseURL)/functions/v1/generate-license") else {
            await setLicenseState(isValid: false, error: "Invalid backend URL.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["deviceId": deviceId]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        guard let payloadData = Data(base64Encoded: envelope.payload),
              let signatureData = Data(base64Encoded: envelope.signature),
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

        guard payload.deviceId == generateDeviceFingerprint(userID: userID) else {
            throw LicenseVerificationError.deviceMismatch
        }

        try validatePayloadFreshness(payload)
        return payload
    }

    private func validatePayloadFreshness(_ payload: LicensePayload) throws {
        guard payload.schemaVersion == 2 else {
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

        guard !payload.revokedSignatureSetVersions.contains(payload.signatureSetVersion) else {
            throw LicenseVerificationError.revokedSignatureSet
        }
    }

    @MainActor
    private func applyVerifiedPayload(_ payload: LicensePayload) {
        let isSubscriptionActive = payload.subscriptionStatus == "active" || payload.subscriptionStatus == "trial"
        isSubscribed = isSubscriptionActive
        licenseError = nil
        if isSubscriptionActive {
            CloudSignatureManager.shared.updateCloudSignatures(
                payload.cloudSignatures,
                signatureSetVersion: payload.signatureSetVersion
            )
        } else {
            CloudSignatureManager.shared.clearCloudSignatures()
        }
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
            if let date = LicenseManager.iso8601FormatterWithFractionalSeconds.date(from: string) {
                return date
            }
            if let date = LicenseManager.iso8601Formatter.date(from: string) {
                return date
            }
            throw LicenseVerificationError.malformedSignedPayload
        }
        return decoder
    }()

    private static let iso8601FormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

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
        self.isSubscribed = isValid
        self.licenseError = error
        if !isValid {
            CloudSignatureManager.shared.clearCloudSignatures()
        }
    }

    @MainActor
    func clearLocalLicenseState() {
        isSubscribed = false
        licenseError = nil
        clearCachedLicenseEnvelope()
        CloudSignatureManager.shared.clearCloudSignatures()
    }
}
