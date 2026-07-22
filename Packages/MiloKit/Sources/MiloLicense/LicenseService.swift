import CryptoKit
import Foundation
import MiloDomain
import Security

@_silgen_name("mh_compute_device_id")
private func cComputeDeviceID(
    _ userID: UnsafePointer<CChar>,
    _ output: UnsafeMutablePointer<CChar>,
    _ outputLength: Int
) -> Int32

@_silgen_name("mh_license_verify_envelope_with_public_key")
private func cVerifyEnvelope(
    _ envelope: UnsafePointer<UInt8>,
    _ envelopeLength: Int,
    _ signature: UnsafePointer<UInt8>,
    _ signatureLength: Int,
    _ publicKey: UnsafePointer<UInt8>,
    _ publicKeyLength: Int
) -> Int32

/// Errors emitted while creating, enrolling, refreshing, or verifying an MLP-v1 license.
public enum MLPLicenseError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case missingLicensePublicKey
    case invalidLicensePublicKey
    case keychainFailure(String)
    case deviceKeyUnavailable
    case deviceFingerprintUnavailable
    case enrollmentMissing
    case enrollmentNotApproved
    case enrollmentExpired
    case malformedResponse
    case responseTooLarge
    case serverRejected(String)
    case invalidEnvelope
    case invalidSignature
    case unsupportedProtocolVersion
    case appMismatch
    case userMismatch
    case deviceKeyMismatch
    case deviceMismatch
    case inactiveSubscription
    case missingProEntitlement
    case issuedInFuture
    case expired
    case updateFeedRejected

    /// Returns a user-safe description that does not expose cryptographic material.
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Milo's license configuration is invalid."
        case .missingLicensePublicKey:
            return "This Milo build does not include a license verification key."
        case .invalidLicensePublicKey:
            return "This Milo build includes an invalid license verification key."
        case .keychainFailure:
            return "Milo could not access secure local license storage."
        case .deviceKeyUnavailable:
            return "Milo could not create this Mac's device key."
        case .deviceFingerprintUnavailable:
            return "Milo could not derive this Mac's device fingerprint."
        case .enrollmentMissing:
            return "This Mac has not been paired with a Monomacaw account."
        case .enrollmentNotApproved:
            return "Approve the pairing code in your Monomacaw account, then try again."
        case .enrollmentExpired:
            return "The pairing code expired. Start a new pairing request."
        case .malformedResponse:
            return "The Monomacaw service returned an invalid response."
        case .responseTooLarge:
            return "The Monomacaw service returned an oversized response."
        case .serverRejected(let message):
            return message
        case .invalidEnvelope:
            return "The signed license envelope is invalid."
        case .invalidSignature:
            return "The signed license envelope failed signature verification."
        case .unsupportedProtocolVersion:
            return "The signed license uses an unsupported protocol version."
        case .appMismatch:
            return "The signed license is not for Milo."
        case .userMismatch:
            return "The signed license is not for the paired Monomacaw account."
        case .deviceKeyMismatch:
            return "The signed license is not bound to this Milo device key."
        case .deviceMismatch:
            return "The signed license is not bound to this Mac."
        case .inactiveSubscription:
            return "Your Milo subscription is not currently active."
        case .missingProEntitlement:
            return "Your signed license does not include Milo Pro."
        case .issuedInFuture:
            return "The signed license is not valid yet."
        case .expired:
            return "The signed license has expired."
        case .updateFeedRejected:
            return "No update feed is available for this license."
        }
    }
}

/// Immutable configuration for a Milo MLP-v1 device client.
public struct MLPClientConfiguration: Sendable {
    /// Monomacaw's HTTPS backend root, such as `https://monomacaw.com`.
    public let baseURL: URL
    /// The ecosystem app identifier bound into all requests and envelopes.
    public let appID: String
    /// The Ed25519 public key used to verify signed license envelopes.
    public let licensePublicKey: Data

    /// Builds a configuration from a base URL and base64url-encoded Ed25519 public key.
    public init(baseURL: URL, appID: String = "milo", licensePublicKeyBase64URL: String) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw MLPLicenseError.invalidConfiguration
        }
        guard appID == "milo" else {
            throw MLPLicenseError.invalidConfiguration
        }
        guard !licensePublicKeyBase64URL.isEmpty else {
            throw MLPLicenseError.missingLicensePublicKey
        }

        let key = try MLPBase64URL.decode(licensePublicKeyBase64URL)
        guard key.count == 32 else {
            throw MLPLicenseError.invalidLicensePublicKey
        }

        self.baseURL = baseURL
        self.appID = appID
        self.licensePublicKey = key
    }
}

/// A pairing challenge shown to the user while waiting for browser approval.
public struct MLPEnrollmentChallenge: Sendable, Equatable {
    /// Opaque challenge identifier used only by the enrollment completion request.
    public let id: String
    /// Short human-entered code displayed in the Monomacaw account dashboard.
    public let pairingCode: String
    /// Server-provided expiration time for the pairing code.
    public let expiresAt: Date
}

/// A verified MLP-v1 envelope plus the hot-path license snapshot derived from it.
public struct MLPVerifiedLicense: Sendable, Equatable {
    /// The immutable feature-gating snapshot for UI and process-engine readers.
    public let snapshot: LicenseSnapshot
    /// Canonical signed envelope bytes. This is retained only for trusted app-data extraction.
    public let envelopeData: Data
}

/// A device-authenticated update-feed discovery response.
public struct MLPUpdateFeed: Sendable, Equatable {
    /// Absolute HTTPS URL of the offline-signed Sparkle appcast.
    public let appcastURL: URL
    /// Hex-encoded SHA-256 of the returned appcast bytes.
    public let appcastSHA256: String
}

/// Verifies MLP-v1 signed envelope bytes against a supplied Ed25519 public key.
public struct MiloLicenseService: Sendable {
    private let publicKey: Data
    private let appID: String

    /// Creates a verifier for Milo's MLP-v1 envelope format.
    public init(licensePublicKey: Data, appID: String = "milo") throws {
        guard licensePublicKey.count == 32, appID == "milo" else {
            throw MLPLicenseError.invalidConfiguration
        }
        self.publicKey = licensePublicKey
        self.appID = appID
    }

    /// Verifies a detached signature and validates all envelope fields bound to this install.
    public func verify(
        envelope: Data,
        signature: Data,
        expectedUserID: UUID,
        expectedDeviceKeyID: UUID,
        expectedDeviceFingerprint: String,
        now: Date = Date()
    ) throws -> MLPVerifiedLicense {
        guard envelope.count >= 2, envelope.count <= MLPWire.maximumEnvelopeBytes else {
            throw MLPLicenseError.invalidEnvelope
        }
        guard signature.count == 64 else {
            throw MLPLicenseError.invalidSignature
        }

        let signatureValid = envelope.withUnsafeBytes { envelopeBuffer -> Bool in
            guard let envelopePointer = envelopeBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return signature.withUnsafeBytes { signatureBuffer -> Bool in
                guard let signaturePointer = signatureBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                return publicKey.withUnsafeBytes { publicKeyBuffer in
                    guard let publicKeyPointer = publicKeyBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return false
                    }
                    return cVerifyEnvelope(
                        envelopePointer,
                        envelope.count,
                        signaturePointer,
                        signature.count,
                        publicKeyPointer,
                        publicKey.count
                    ) == 1
                }
            }
        }

        guard signatureValid else {
            throw MLPLicenseError.invalidSignature
        }

        let decoded: MLPEnvelope
        do {
            decoded = try MLPWire.decoder.decode(MLPEnvelope.self, from: envelope)
        } catch {
            throw MLPLicenseError.invalidEnvelope
        }

        guard decoded.protocolVersion == 1 else {
            throw MLPLicenseError.unsupportedProtocolVersion
        }
        guard decoded.appID == appID else {
            throw MLPLicenseError.appMismatch
        }
        guard decoded.userID == expectedUserID else {
            throw MLPLicenseError.userMismatch
        }
        guard decoded.deviceKeyID == expectedDeviceKeyID else {
            throw MLPLicenseError.deviceKeyMismatch
        }
        guard Self.constantTimeEquals(decoded.deviceID, expectedDeviceFingerprint) else {
            throw MLPLicenseError.deviceMismatch
        }
        guard decoded.entitlements.contains("pro") else {
            throw MLPLicenseError.missingProEntitlement
        }
        guard MLPSubscriptionStatus(rawValue: decoded.subscriptionStatus).grantsProAccess else {
            throw MLPLicenseError.inactiveSubscription
        }
        guard decoded.issuedAt <= now.addingTimeInterval(MLPWire.maximumFutureClockSkew) else {
            throw MLPLicenseError.issuedInFuture
        }
        guard decoded.expiresAt > now else {
            throw MLPLicenseError.expired
        }

        let snapshot = LicenseSnapshot(
            isPro: true,
            productEntitlements: decoded.entitlements,
            signatureSetVersion: String(decoded.policyRevision),
            issuedAt: decoded.issuedAt,
            expiresAt: decoded.expiresAt,
            userID: decoded.userID,
            licenseID: decoded.licenseID,
            deviceKeyID: decoded.deviceKeyID,
            releaseChannel: decoded.releaseChannel,
            updateEntitledUntil: decoded.updateEntitledUntil
        )
        return MLPVerifiedLicense(snapshot: snapshot, envelopeData: envelope)
    }

    private static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftData = Data(left.utf8)
        let rightData = Data(right.utf8)
        guard leftData.count == rightData.count else {
            return false
        }
        if leftData.isEmpty {
            return true
        }

        return leftData.withUnsafeBytes { leftBuffer in
            guard let leftPointer = leftBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return rightData.withUnsafeBytes { rightBuffer in
                guard let rightPointer = rightBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }
                var difference: UInt8 = 0
                for index in 0..<leftData.count {
                    difference |= leftPointer[index] ^ rightPointer[index]
                }
                return difference == 0
            }
        }
    }
}

/// Owns Milo's non-exportable device key and MLP-v1 enrollment lifecycle.
public final class MLPDeviceLicenseClient: @unchecked Sendable {
    private let configuration: MLPClientConfiguration
    private let keyStore: MLPDeviceKeyStore
    private let session: URLSession

    /// Creates an MLP-v1 device client using the shared URL loading system.
    public init(configuration: MLPClientConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.keyStore = MLPDeviceKeyStore()
        self.session = session
    }

    /// Restores and verifies the locally cached signed license envelope.
    public func cachedLicense(now: Date = Date()) throws -> MLPVerifiedLicense {
        let registration = try registrationStore.load()
        let signedEnvelope = try envelopeStore.load()
        return try verify(
            signedEnvelope: signedEnvelope,
            registration: registration,
            now: now
        )
    }

    /// Starts a new browser-approved pairing flow and securely stores its opaque challenge token.
    public func startEnrollment() async throws -> MLPEnrollmentChallenge {
        let publicKeySPKI = try keyStore.publicKeySPKI()
        let body = MLPEnrollmentStartRequest(
            protocolVersion: 1,
            appID: configuration.appID,
            publicKeySPKI: MLPBase64URL.encode(publicKeySPKI),
            appVersion: MLPWire.appVersion,
            macOSVersion: MLPWire.macOSVersion
        )
        let response: MLPEnrollmentStartResponse = try await sendUnsigned(path: "/functions/v1/device-enroll-start", body: body)
        guard let expiration = MLPWire.parseDate(response.expiresAt) else {
            throw MLPLicenseError.malformedResponse
        }

        let pending = MLPPendingEnrollment(
            challengeID: response.challengeID,
            pairingCode: response.pairingCode,
            challengeToken: response.challengeToken,
            expiresAt: expiration
        )
        try pendingEnrollmentStore.save(pending)
        return MLPEnrollmentChallenge(id: pending.challengeID, pairingCode: pending.pairingCode, expiresAt: pending.expiresAt)
    }

    /// Returns an unexpired pending pairing challenge, if this Mac is waiting for browser approval.
    public func pendingEnrollment(now: Date = Date()) throws -> MLPEnrollmentChallenge? {
        guard let pending = try pendingEnrollmentStore.loadIfPresent() else {
            return nil
        }
        guard pending.expiresAt > now else {
            try pendingEnrollmentStore.deleteIfPresent()
            return nil
        }
        return MLPEnrollmentChallenge(id: pending.challengeID, pairingCode: pending.pairingCode, expiresAt: pending.expiresAt)
    }

    /// Completes browser-approved pairing, activates this device, and caches the verified envelope.
    public func completeEnrollment() async throws -> MLPVerifiedLicense {
        guard let pending = try pendingEnrollmentStore.loadIfPresent() else {
            throw MLPLicenseError.enrollmentMissing
        }
        guard pending.expiresAt > Date() else {
            try pendingEnrollmentStore.deleteIfPresent()
            throw MLPLicenseError.enrollmentExpired
        }

        let completionBody = MLPEnrollmentCompleteRequest(
            protocolVersion: 1,
            challengeID: pending.challengeID,
            challengeToken: pending.challengeToken
        )
        let completion: MLPEnrollmentCompleteResponse
        do {
            completion = try await sendUnsigned(path: "/functions/v1/device-enroll-complete", body: completionBody)
        } catch MLPLicenseError.serverRejected(let message) {
            if message.localizedCaseInsensitiveContains("not been approved") {
                throw MLPLicenseError.enrollmentNotApproved
            }
            throw MLPLicenseError.serverRejected(message)
        }

        guard completion.appID == configuration.appID,
              let userID = UUID(uuidString: completion.userID),
              let keyID = UUID(uuidString: completion.keyID) else {
            throw MLPLicenseError.malformedResponse
        }

        let registration = MLPDeviceRegistration(userID: userID, keyID: keyID, appID: completion.appID)
        try registrationStore.save(registration)
        try pendingEnrollmentStore.deleteIfPresent()
        return try await activate(registration: registration)
    }

    /// Refreshes the signed license envelope using the enrolled device key.
    public func refreshLicense() async throws -> MLPVerifiedLicense {
        let registration = try registrationStore.load()
        let fingerprint = try Self.deviceFingerprint(for: registration.userID)
        let body = MLPLicenseRefreshRequest(
            protocolVersion: 1,
            appID: configuration.appID,
            deviceFingerprint: fingerprint,
            appVersion: MLPWire.appVersion,
            macOSVersion: MLPWire.macOSVersion
        )
        let signedEnvelope: MLPSignedEnvelopeResponse = try await sendSigned(
            path: "/functions/v1/license-refresh",
            method: "POST",
            body: body,
            registration: registration
        )
        let verified = try verify(signedEnvelope: signedEnvelope, registration: registration, now: Date())
        try envelopeStore.save(signedEnvelope)
        return verified
    }

    /// Fetches a device-authenticated Sparkle appcast descriptor for the selected channel.
    public func updateFeed(channel: String = "stable") async throws -> MLPUpdateFeed {
        let registration = try registrationStore.load()
        guard channel == "stable" || channel == "beta" else {
            throw MLPLicenseError.invalidConfiguration
        }
        var components = URLComponents(url: try endpoint(path: "/functions/v1/update-feed"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "app", value: configuration.appID),
            URLQueryItem(name: "channel", value: channel)
        ]
        guard let url = components?.url else {
            throw MLPLicenseError.invalidConfiguration
        }

        let descriptor: MLPUpdateFeedResponse = try await sendSigned(
            url: url,
            method: "GET",
            body: Data(),
            registration: registration
        )
        guard let appcastURL = URL(string: descriptor.appcastURL),
              appcastURL.scheme?.lowercased() == "https",
              appcastURL.host != nil,
              descriptor.appcastSHA256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else {
            throw MLPLicenseError.updateFeedRejected
        }
        return MLPUpdateFeed(appcastURL: appcastURL, appcastSHA256: descriptor.appcastSHA256.lowercased())
    }

    /// Removes all local pairing, envelope, and private-key state for this Milo install.
    public func clearLocalState() throws {
        try envelopeStore.deleteIfPresent()
        try pendingEnrollmentStore.deleteIfPresent()
        try registrationStore.deleteIfPresent()
        try keyStore.deleteIfPresent()
    }

    private func activate(registration: MLPDeviceRegistration) async throws -> MLPVerifiedLicense {
        let fingerprint = try Self.deviceFingerprint(for: registration.userID)
        let body = MLPDeviceActivationRequest(
            protocolVersion: 1,
            appID: configuration.appID,
            userID: registration.userID.uuidString.lowercased(),
            deviceFingerprint: fingerprint,
            appVersion: MLPWire.appVersion,
            macOSVersion: MLPWire.macOSVersion,
            nickname: Host.current().localizedName
        )
        let signedEnvelope: MLPSignedEnvelopeResponse = try await sendSigned(
            path: "/functions/v1/device-activate",
            method: "POST",
            body: body,
            registration: registration
        )
        let verified = try verify(signedEnvelope: signedEnvelope, registration: registration, now: Date())
        try envelopeStore.save(signedEnvelope)
        return verified
    }

    private func verify(
        signedEnvelope: MLPSignedEnvelopeResponse,
        registration: MLPDeviceRegistration,
        now: Date
    ) throws -> MLPVerifiedLicense {
        let envelope = try MLPBase64URL.decode(signedEnvelope.envelope)
        let signature = try MLPBase64URL.decode(signedEnvelope.signature)
        let fingerprint = try Self.deviceFingerprint(for: registration.userID)
        let verifier = try MiloLicenseService(
            licensePublicKey: configuration.licensePublicKey,
            appID: configuration.appID
        )
        return try verifier.verify(
            envelope: envelope,
            signature: signature,
            expectedUserID: registration.userID,
            expectedDeviceKeyID: registration.keyID,
            expectedDeviceFingerprint: fingerprint,
            now: now
        )
    }

    private func sendUnsigned<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        let data = try MLPWire.encode(body)
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await send(request)
    }

    private func sendSigned<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        registration: MLPDeviceRegistration
    ) async throws -> Response {
        let data = try MLPWire.encode(body)
        return try await sendSigned(
            url: try endpoint(path: path),
            method: method,
            body: data,
            registration: registration
        )
    }

    private func sendSigned<Response: Decodable>(
        url: URL,
        method: String,
        body: Data,
        registration: MLPDeviceRegistration
    ) async throws -> Response {
        let timestamp = MLPWire.timestamp()
        let nonce = try MLPBase64URL.encodeRandom(byteCount: 32)
        let message = try MLPWire.requestMessage(
            method: method,
            url: url,
            timestamp: timestamp,
            nonce: nonce,
            body: body
        )
        let signature = try keyStore.sign(message: Data(message.utf8))

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("1", forHTTPHeaderField: "X-MLP-Version")
        request.setValue(registration.keyID.uuidString.lowercased(), forHTTPHeaderField: "X-Device-Key-Id")
        request.setValue(nonce, forHTTPHeaderField: "X-Request-Nonce")
        request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")
        request.setValue(MLPBase64URL.encode(signature), forHTTPHeaderField: "X-Device-Signature")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard data.count <= MLPWire.maximumResponseBytes else {
            throw MLPLicenseError.responseTooLarge
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MLPLicenseError.malformedResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.serverError(from: data, fallbackStatus: httpResponse.statusCode)
        }
        do {
            return try MLPWire.decoder.decode(Response.self, from: data)
        } catch {
            throw MLPLicenseError.malformedResponse
        }
    }

    private func endpoint(path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw MLPLicenseError.invalidConfiguration
        }
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MLPLicenseError.invalidConfiguration
        }
        return url
    }

    private static func serverError(from data: Data, fallbackStatus: Int) -> MLPLicenseError {
        do {
            let decoded = try MLPWire.decoder.decode(MLPServerError.self, from: data)
            if let message = decoded.error?.message, !message.isEmpty {
                return .serverRejected(message)
            }
        } catch {
            return .serverRejected("The Monomacaw service rejected this request (HTTP \(fallbackStatus)).")
        }
        return .serverRejected("The Monomacaw service rejected this request (HTTP \(fallbackStatus)).")
    }

    private static func deviceFingerprint(for userID: UUID) throws -> String {
        var output = [CChar](repeating: 0, count: 65)
        let result = userID.uuidString.lowercased().withCString { userIDPointer in
            output.withUnsafeMutableBufferPointer { outputBuffer -> Int32 in
                guard let outputPointer = outputBuffer.baseAddress else {
                    return 0
                }
                return cComputeDeviceID(userIDPointer, outputPointer, outputBuffer.count)
            }
        }
        guard result == 1 else {
            throw MLPLicenseError.deviceFingerprintUnavailable
        }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let fingerprint = String(decoding: bytes, as: UTF8.self)
        guard fingerprint.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw MLPLicenseError.deviceFingerprintUnavailable
        }
        return fingerprint
    }

    private let registrationStore = MLPKeychainStore<MLPDeviceRegistration>(
        service: "com.monomacaw.milo.mlp-v1",
        account: "device-registration"
    )
    private let pendingEnrollmentStore = MLPKeychainStore<MLPPendingEnrollment>(
        service: "com.monomacaw.milo.mlp-v1",
        account: "pending-enrollment"
    )
    private let envelopeStore = MLPKeychainStore<MLPSignedEnvelopeResponse>(
        service: "com.monomacaw.milo.license",
        account: "mlp-v1-license-envelope"
    )
}

private enum MLPWire {
    static let maximumEnvelopeBytes = 16 * 1024
    static let maximumResponseBytes = 64 * 1024
    static let maximumFutureClockSkew: TimeInterval = 5 * 60

    static var appVersion: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "2.0.0"
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "2.0.0" : value
    }

    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseDate(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 timestamp.")
            }
            return date
        }
        return decoder
    }()

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func requestMessage(method: String, url: URL, timestamp: String, nonce: String, body: Data) throws -> String {
        guard let host = url.host?.lowercased() else {
            throw MLPLicenseError.invalidConfiguration
        }
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        let bodyHash = MLPBase64URL.encode(Data(SHA256.hash(data: body)))
        return ["MLP1", method.uppercased(), host, path, timestamp, nonce, bodyHash].joined(separator: "\n")
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private enum MLPBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func encodeRandom(byteCount: Int) throws -> String {
        guard byteCount > 0 else {
            throw MLPLicenseError.invalidConfiguration
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        return encode(Data(bytes))
    }

    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57)
                      || byte == 45
                      || byte == 95
              }) else {
            throw MLPLicenseError.malformedResponse
        }

        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch standard.count % 4 {
        case 0:
            break
        case 2:
            standard.append("==")
        case 3:
            standard.append("=")
        default:
            throw MLPLicenseError.malformedResponse
        }
        guard let data = Data(base64Encoded: standard) else {
            throw MLPLicenseError.malformedResponse
        }
        return data
    }
}

private final class MLPDeviceKeyStore: @unchecked Sendable {
    private let tag = Data("com.monomacaw.milo.mlp-v1.device-key".utf8)
    private let publicKeySPKIPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D,
        0x02, 0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01,
        0x07, 0x03, 0x42, 0x00
    ])

    func publicKeySPKI() throws -> Data {
        let privateKey = try loadOrCreate()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        guard external.count == 65 else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        return publicKeySPKIPrefix + external
    }

    func sign(message: Data) throws -> Data {
        let privateKey = try loadOrCreate()
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, message as CFData, &error) as Data? else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        return signature
    }

    func deleteIfPresent() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(status))
        }
    }

    private func loadOrCreate() throws -> SecKey {
        if let key = try loadIfPresent() {
            return key
        }
        do {
            return try create(tokenID: kSecAttrTokenIDSecureEnclave)
        } catch {
            return try create(tokenID: nil)
        }
    }

    private func loadIfPresent() throws -> SecKey? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnReference: true) as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(status))
        }
        // SAFETY: SecItemCopyMatching returned a retained Core Foundation object whose type was checked above.
        return unsafeBitCast(result, to: SecKey.self)
    }

    private func create(tokenID: CFString?) throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var accessError: Unmanaged<CFError>?
        if let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) {
            privateAttributes[kSecAttrAccessControl as String] = access
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        if let tokenID {
            attributes[kSecAttrTokenID as String] = tokenID
        }

        var creationError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
            throw MLPLicenseError.deviceKeyUnavailable
        }
        return key
    }

    private func query(returnReference: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        if returnReference {
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func statusMessage(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }
        return "OSStatus \(status)"
    }
}

private struct MLPKeychainStore<Value: Codable>: @unchecked Sendable {
    let service: String
    let account: String

    func load() throws -> Value {
        guard let value = try loadIfPresent() else {
            throw MLPLicenseError.enrollmentMissing
        }
        return value
    }

    func loadIfPresent() throws -> Value? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery() as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(status))
        }
        do {
            return try MLPWire.decoder.decode(Value.self, from: data)
        } catch {
            throw MLPLicenseError.keychainFailure("Stored license state is malformed.")
        }
    }

    func save(_ value: Value) throws {
        let data: Data
        do {
            data = try MLPWire.encode(value)
        } catch {
            throw MLPLicenseError.keychainFailure("License state could not be encoded.")
        }
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(updateStatus))
        }

        var addQuery = baseQuery()
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(addStatus))
        }
    }

    func deleteIfPresent() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLPLicenseError.keychainFailure(Self.statusMessage(status))
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func readQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    private static func statusMessage(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) {
            return message as String
        }
        return "OSStatus \(status)"
    }
}

private enum MLPSubscriptionStatus {
    case active
    case trial
    case pastDue
    case expired
    case cancelled
    case unknown

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "active": self = .active
        case "trial", "trialing": self = .trial
        case "past_due": self = .pastDue
        case "expired": self = .expired
        case "cancelled", "canceled": self = .cancelled
        default: self = .unknown
        }
    }

    var grantsProAccess: Bool {
        switch self {
        case .active, .trial, .pastDue:
            return true
        case .expired, .cancelled, .unknown:
            return false
        }
    }
}

private struct MLPEnvelope: Decodable {
    let protocolVersion: Int
    let appID: String
    let userID: UUID
    let licenseID: UUID
    let deviceID: String
    let deviceKeyID: UUID
    let subscriptionStatus: String
    let entitlements: [String]
    let updateEntitledUntil: Date?
    let releaseChannel: String
    let issuedAt: Date
    let expiresAt: Date
    let policyRevision: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appID = "appId"
        case userID = "userId"
        case licenseID = "licenseId"
        case deviceID = "deviceId"
        case deviceKeyID = "deviceKeyId"
        case subscriptionStatus
        case entitlements
        case updateEntitledUntil
        case releaseChannel
        case issuedAt
        case expiresAt
        case policyRevision
    }
}

private struct MLPEnrollmentStartRequest: Encodable {
    let protocolVersion: Int
    let appID: String
    let publicKeySPKI: String
    let appVersion: String
    let macOSVersion: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appID = "appId"
        case publicKeySPKI
        case appVersion
        case macOSVersion
    }
}

private struct MLPEnrollmentStartResponse: Decodable {
    let challengeID: String
    let pairingCode: String
    let challengeToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challengeId"
        case pairingCode
        case challengeToken
        case expiresAt
    }
}

private struct MLPEnrollmentCompleteRequest: Encodable {
    let protocolVersion: Int
    let challengeID: String
    let challengeToken: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case challengeID = "challengeId"
        case challengeToken
    }
}

private struct MLPEnrollmentCompleteResponse: Decodable {
    let keyID: String
    let userID: String
    let appID: String

    enum CodingKeys: String, CodingKey {
        case keyID = "keyId"
        case userID = "userId"
        case appID = "appId"
    }
}

private struct MLPDeviceActivationRequest: Encodable {
    let protocolVersion: Int
    let appID: String
    let userID: String
    let deviceFingerprint: String
    let appVersion: String
    let macOSVersion: String
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appID = "appId"
        case userID = "userId"
        case deviceFingerprint
        case appVersion
        case macOSVersion
        case nickname
    }
}

private struct MLPLicenseRefreshRequest: Encodable {
    let protocolVersion: Int
    let appID: String
    let deviceFingerprint: String
    let appVersion: String
    let macOSVersion: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appID = "appId"
        case deviceFingerprint
        case appVersion
        case macOSVersion
    }
}

private struct MLPSignedEnvelopeResponse: Codable {
    let envelope: String
    let signature: String
    let signingKeyID: String?

    enum CodingKeys: String, CodingKey {
        case envelope
        case signature
        case signingKeyID = "signingKeyId"
    }
}

private struct MLPUpdateFeedResponse: Decodable {
    let appcastURL: String
    let appcastSHA256: String

    enum CodingKeys: String, CodingKey {
        case appcastURL = "appcastUrl"
        case appcastSHA256 = "appcastSha256"
    }
}

private struct MLPServerError: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
}

private struct MLPDeviceRegistration: Codable {
    let userID: UUID
    let keyID: UUID
    let appID: String
}

private struct MLPPendingEnrollment: Codable {
    let challengeID: String
    let pairingCode: String
    let challengeToken: String
    let expiresAt: Date
}
