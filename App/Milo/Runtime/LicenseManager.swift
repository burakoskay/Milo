import AppKit
import Foundation
import MiloDomain
import MiloLicense

/// Main-actor adapter between Milo's UI and the sole supported MLP-v1 device client.
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    @Published private(set) var snapshot: LicenseSnapshot = .locked
    @Published private(set) var isVerifying = false
    @Published private(set) var licenseError: String?
    @Published private(set) var pairingChallenge: MLPEnrollmentChallenge?

    var isSubscribed: Bool {
        if MiloBuildMode.isDevelopmentPreview {
            return true
        }
        guard snapshot.isPro, let expiration = snapshot.expiresAt else {
            return false
        }
        return expiration > Date()
    }

    var licenseExpiresAt: Date? {
        snapshot.expiresAt
    }

    private let client: MLPDeviceLicenseClient?
    private let configurationError: String?

    private init() {
        if MiloBuildMode.isDevelopmentPreview {
            snapshot = LicenseSnapshot(
                isPro: true,
                productEntitlements: ["process-control", "system-tuning", "local-preview"],
                issuedAt: Date(),
                expiresAt: .distantFuture,
                releaseChannel: "development-preview"
            )
            client = nil
            configurationError = nil
            return
        }

        do {
            let configuration = try MLPClientConfiguration(
                baseURL: try BackendConfiguration.serviceBaseURL(),
                licensePublicKeyBase64URL: MiloClientConfiguration.licensePublicKeyBase64URL
            )
            client = MLPDeviceLicenseClient(configuration: configuration)
            configurationError = nil
        } catch {
            client = nil
            configurationError = Self.userMessage(for: error)
        }

        Task { @MainActor [weak self] in
            await self?.restoreLocalState()
        }
    }

    /// Restores an unexpired pairing challenge and a cryptographically verified cached license.
    func restoreLocalState() async {
        guard !MiloBuildMode.isDevelopmentPreview else {
            return
        }
        guard beginOperation() else {
            return
        }
        defer { finishOperation() }

        guard let client = configuredClient() else {
            return
        }

        do {
            pairingChallenge = try await client.pendingEnrollment()
        } catch {
            pairingChallenge = nil
            licenseError = Self.userMessage(for: error)
        }

        do {
            apply(try await client.cachedLicense())
        } catch MLPLicenseError.enrollmentMissing {
            snapshot = .locked
        } catch {
            snapshot = .locked
            licenseError = Self.userMessage(for: error)
        }
    }

    /// Creates a short-lived browser pairing challenge without transferring browser credentials to Milo.
    func startEnrollment() async {
        guard !MiloBuildMode.isDevelopmentPreview else {
            return
        }
        guard beginOperation() else {
            return
        }
        defer { finishOperation() }

        guard let client = configuredClient() else {
            return
        }

        do {
            pairingChallenge = try await client.startEnrollment()
            licenseError = nil
        } catch {
            licenseError = Self.userMessage(for: error)
        }
    }

    /// Completes an approved browser pairing and applies only the verified signed license snapshot.
    func completeEnrollment() async {
        guard !MiloBuildMode.isDevelopmentPreview else {
            return
        }
        guard beginOperation() else {
            return
        }
        defer { finishOperation() }

        guard let client = configuredClient() else {
            return
        }

        do {
            let verified = try await client.completeEnrollment()
            pairingChallenge = nil
            apply(verified)
        } catch {
            licenseError = Self.userMessage(for: error)
        }
    }

    /// Refreshes the license using the enrolled device's signed MLP-v1 request.
    func refreshLicense() async {
        guard !MiloBuildMode.isDevelopmentPreview else {
            return
        }
        guard beginOperation() else {
            return
        }
        defer { finishOperation() }

        guard let client = configuredClient() else {
            return
        }

        let hadValidOfflineLicense = isSubscribed
        do {
            apply(try await client.refreshLicense())
        } catch {
            if !hadValidOfflineLicense || Self.requiresImmediateLock(for: error) {
                snapshot = .locked
            }
            licenseError = Self.userMessage(for: error)
        }
    }

    /// Obtains the MLP-authenticated update descriptor for the signed license channel.
    func updateFeedDescriptor() async throws -> (descriptor: MLPUpdateFeed, channel: String) {
        guard !MiloBuildMode.isDevelopmentPreview else {
            throw MLPLicenseError.updateFeedRejected
        }
        guard !isVerifying else {
            throw MLPLicenseError.updateFeedRejected
        }
        guard isSubscribed else {
            throw MLPLicenseError.missingProEntitlement
        }
        guard let channel = snapshot.releaseChannel,
              channel == "stable" || channel == "beta" else {
            throw MLPLicenseError.invalidEnvelope
        }
        guard let client else {
            throw MLPLicenseError.invalidConfiguration
        }
        return (try await client.updateFeed(channel: channel), channel)
    }

    /// Removes all device enrollment and cached license material from this Mac.
    func clearLocalLicenseState() async {
        guard !MiloBuildMode.isDevelopmentPreview else {
            return
        }
        guard beginOperation() else {
            return
        }
        defer { finishOperation() }
        guard let client = configuredClient() else {
            return
        }

        snapshot = .locked
        pairingChallenge = nil
        do {
            try await client.clearLocalState()
            licenseError = nil
        } catch {
            licenseError = "Milo locked Pro features, but some local pairing data could not be removed. \(Self.userMessage(for: error))"
        }
        CloudSignatureManager.shared.clearCloudSignatures()
    }

    func openAccountDevices() {
        openBrowser(path: "/account/devices")
    }

    func openAccount() {
        openBrowser(path: "/account")
    }

    private func beginOperation() -> Bool {
        guard !isVerifying else {
            licenseError = "A license operation is already in progress."
            return false
        }
        isVerifying = true
        return true
    }

    private func finishOperation() {
        isVerifying = false
    }

    private func configuredClient() -> MLPDeviceLicenseClient? {
        guard let client else {
            licenseError = configurationError ?? "Milo's license configuration is unavailable."
            return nil
        }
        return client
    }

    private func apply(_ verified: MLPVerifiedLicense) {
        snapshot = verified.snapshot
        licenseError = nil
        CloudSignatureManager.shared.clearCloudSignatures()
    }

    private func openBrowser(path: String) {
        do {
            let url = try BackendConfiguration.websiteURL(path: path)
            guard NSWorkspace.shared.open(url) else {
                licenseError = "macOS could not open your default browser. Visit gonggong.tech\(path) manually."
                return
            }
            licenseError = nil
        } catch {
            licenseError = Self.userMessage(for: error)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return "The license operation failed. Check your connection and try again."
    }

    private static func requiresImmediateLock(for error: Error) -> Bool {
        guard let licenseError = error as? MLPLicenseError else {
            return false
        }
        switch licenseError {
        case .enrollmentMissing,
             .enrollmentExpired,
             .inactiveSubscription,
             .missingProEntitlement,
             .expired:
            return true
        case .invalidConfiguration,
             .missingLicensePublicKey,
             .invalidLicensePublicKey,
             .keychainFailure,
             .deviceKeyUnavailable,
             .deviceFingerprintUnavailable,
             .enrollmentNotApproved,
             .malformedResponse,
             .responseTooLarge,
             .serverRejected,
             .invalidEnvelope,
             .invalidSignature,
             .unsupportedProtocolVersion,
             .appMismatch,
             .userMismatch,
             .deviceKeyMismatch,
             .deviceMismatch,
             .issuedInFuture,
             .updateFeedRejected:
            return false
        }
    }
}
