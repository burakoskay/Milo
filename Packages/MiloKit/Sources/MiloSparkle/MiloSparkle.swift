import Foundation
import MiloLicense
import MiloUpdates
import Sparkle

public enum MiloSparkleEvent: Sendable, Equatable {
    case preparing
    case checking
    case updateAvailable(version: String)
    case upToDate
    case updateDownloaded(version: String)
    case failed(message: String)
}

public enum MiloSparkleError: Error, Sendable, Equatable {
    case invalidHostBundle
    case invalidChannel
    case checkAlreadyInProgress
    case feedNotPrepared
    case updaterUnavailable
    case informationOnlyUpdateRejected
    case invalidInstallationType
    case untrustedDownloadURL
}

extension MiloSparkleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHostBundle:
            return "Milo's updater is attached to an unexpected application bundle."
        case .invalidChannel:
            return "The signed license selected an unsupported update channel."
        case .checkAlreadyInProgress:
            return "An update check is already in progress."
        case .feedNotPrepared:
            return "Milo has not prepared an authenticated update feed."
        case .updaterUnavailable:
            return "Sparkle could not start with Milo's release configuration."
        case .informationOnlyUpdateRejected:
            return "The update feed selected an informational-only item instead of a signed application update."
        case .invalidInstallationType:
            return "The update feed selected an unsupported installer type."
        case .untrustedDownloadURL:
            return "The update feed selected an untrusted download location."
        }
    }
}

/// Pro-only composition root for MLP-authenticated discovery and Sparkle installation.
@MainActor
public final class MiloSparkleController: NSObject, SPUUpdaterDelegate {
    public typealias EventHandler = @MainActor @Sendable (MiloSparkleEvent) -> Void

    private let expectedBundleIdentifier: String
    private let appcastPolicy: MiloAppcastPolicy
    private let appcastLoader: MiloAppcastLoader
    private let loopbackServer = MiloLoopbackAppcastServer()
    private let eventHandler: EventHandler

    private var standardController: SPUStandardUpdaterController?
    private var preparedEndpoint: MiloLoopbackAppcastEndpoint?
    private var selectedChannel = "stable"
    private var isPreparing = false

    public init(
        expectedBundleIdentifier: String,
        appcastPolicy: MiloAppcastPolicy,
        eventHandler: @escaping EventHandler
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.appcastPolicy = appcastPolicy
        self.appcastLoader = MiloAppcastLoader(policy: appcastPolicy)
        self.eventHandler = eventHandler
        super.init()
    }

    public var canCheckForUpdates: Bool {
        !isPreparing && !(standardController?.updater.sessionInProgress ?? false)
    }

    /// Preflights the authenticated descriptor and exact appcast bytes before Sparkle receives them.
    public func checkForUpdates(descriptor: MLPUpdateFeed, channel: String) async throws {
        guard Bundle.main.bundleIdentifier == expectedBundleIdentifier else {
            throw MiloSparkleError.invalidHostBundle
        }
        guard channel == "stable" || channel == "beta" else {
            throw MiloSparkleError.invalidChannel
        }
        guard canCheckForUpdates else {
            throw MiloSparkleError.checkAlreadyInProgress
        }

        isPreparing = true
        eventHandler(.preparing)
        do {
            let verifiedAppcast = try await appcastLoader.load(descriptor: descriptor)
            let endpoint = try await loopbackServer.start(appcast: verifiedAppcast)
            preparedEndpoint = endpoint
            selectedChannel = channel

            let updater = try configuredUpdater()
            guard updater.canCheckForUpdates else {
                throw MiloSparkleError.checkAlreadyInProgress
            }
            isPreparing = false
            eventHandler(.checking)
            updater.checkForUpdates()
        } catch {
            isPreparing = false
            let endpoint = preparedEndpoint
            preparedEndpoint = nil
            if let endpoint {
                await loopbackServer.stop(endpoint: endpoint)
            }
            eventHandler(.failed(message: Self.userMessage(for: error)))
            throw error
        }
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard preparedEndpoint != nil else {
            throw MiloSparkleError.feedNotPrepared
        }
    }

    @objc(feedURLStringForUpdater:)
    public func feedURLString(for updater: SPUUpdater) -> String? {
        preparedEndpoint?.url.absoluteString
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        selectedChannel == "beta" ? ["beta"] : []
    }

    public func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        stopPreparedEndpoint()
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        eventHandler(.updateAvailable(version: item.displayVersionString))
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let sparkleError = error as NSError
        if Self.isSparkleError(sparkleError, code: SUError.noUpdateError) {
            eventHandler(.upToDate)
        } else {
            eventHandler(.failed(message: "Sparkle could not securely complete the update check."))
        }
    }

    public func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard !updateItem.isInformationOnlyUpdate,
              let fileURL = updateItem.fileURL else {
            throw MiloSparkleError.informationOnlyUpdateRejected
        }
        guard updateItem.installationType == "application" else {
            throw MiloSparkleError.invalidInstallationType
        }
        do {
            try appcastPolicy.validate(remoteURL: fileURL)
        } catch {
            throw MiloSparkleError.untrustedDownloadURL
        }
    }

    public func updater(
        _ updater: SPUUpdater,
        shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem
    ) -> Bool {
        false
    }

    public func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        eventHandler(.updateDownloaded(version: item.displayVersionString))
    }

    public func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        stopPreparedEndpoint()
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let sparkleError = error as NSError
        let isBenign = Self.isSparkleError(sparkleError, code: SUError.noUpdateError) ||
            Self.isSparkleError(
                sparkleError,
                code: SUError.installationCanceledError
            )
        if !isBenign {
            eventHandler(.failed(message: "Sparkle could not securely complete the update session."))
        }
    }

    private func configuredUpdater() throws -> SPUUpdater {
        if let standardController {
            return standardController.updater
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        let updater = controller.updater
        _ = updater.clearFeedURLFromUserDefaults()
        do {
            try updater.start()
        } catch {
            throw MiloSparkleError.updaterUnavailable
        }
        standardController = controller
        return updater
    }

    private func stopPreparedEndpoint() {
        let endpoint = preparedEndpoint
        preparedEndpoint = nil
        guard let endpoint else {
            return
        }
        Task { [loopbackServer] in
            await loopbackServer.stop(endpoint: endpoint)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Milo could not complete the update check."
    }

    private static func isSparkleError(_ error: NSError, code: SUError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == code.rawValue
    }
}
