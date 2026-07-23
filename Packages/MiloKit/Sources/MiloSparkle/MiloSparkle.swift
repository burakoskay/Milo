import Foundation
import MiloUpdates
import Sparkle

/// Sparkle delegate that supplies Milo's per-license authenticated update-feed URL.
@MainActor
public final class MiloSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    public typealias BaseFeedURLProvider = @MainActor () throws -> URL
    public typealias FeedStateProvider = @MainActor () throws -> AuthenticatedUpdateFeedState

    private let baseFeedURLProvider: BaseFeedURLProvider
    private let feedStateProvider: FeedStateProvider
    private var lastError: Error?

    /// Creates a delegate with injected state providers so the app owns storage and trust policy.
    public init(
        baseFeedURLProvider: @escaping BaseFeedURLProvider,
        feedStateProvider: @escaping FeedStateProvider
    ) {
        self.baseFeedURLProvider = baseFeedURLProvider
        self.feedStateProvider = feedStateProvider
        super.init()
    }

    /// Prevents Sparkle from checking when no verified license state can authenticate the request.
    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        do {
            _ = try authenticatedFeedURL()
            lastError = nil
        } catch {
            lastError = error
            throw error
        }
    }

    /// Supplies Sparkle with the one-shot authenticated appcast URL.
    @objc(feedURLStringForUpdater:)
    public func feedURLString(for updater: SPUUpdater) -> String? {
        do {
            let url = try authenticatedFeedURL()
            lastError = nil
            return url.absoluteString
        } catch {
            lastError = error
            return nil
        }
    }

    /// The last URL construction failure, exposed for diagnostics and tests.
    public func latestError() -> Error? {
        lastError
    }

    private func authenticatedFeedURL() throws -> URL {
        try AuthenticatedUpdateFeed.makeURL(
            baseURL: baseFeedURLProvider(),
            state: feedStateProvider()
        )
    }
}
