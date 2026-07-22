import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

public struct UpdateEntitlement: Sendable, Equatable {
    public let maxAppVersion: String
    public let updateEntitledUntil: Date?

    public init(maxAppVersion: String, updateEntitledUntil: Date?) {
        self.maxAppVersion = maxAppVersion
        self.updateEntitledUntil = updateEntitledUntil
    }
}

/// Verified license fields required to authenticate Sparkle appcast requests.
public struct AuthenticatedUpdateFeedState: Sendable, Equatable {
    public let appId: String
    public let licenseId: String
    public let deviceHash: String

    public init(appId: String, licenseId: String, deviceHash: String) {
        self.appId = appId
        self.licenseId = licenseId
        self.deviceHash = deviceHash
    }
}

/// Errors raised while constructing an authenticated update-feed URL.
public enum AuthenticatedUpdateFeedError: Error, Sendable, Equatable {
    case invalidBaseURL
}

/// Builds entitlement-scoped Sparkle feed URLs from a previously verified license state.
public enum AuthenticatedUpdateFeed {
    /// Returns a feed URL containing the verified app, license, and device routing fields.
    public static func makeURL(baseURL: URL, state: AuthenticatedUpdateFeedState) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AuthenticatedUpdateFeedError.invalidBaseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "app", value: state.appId))
        queryItems.append(URLQueryItem(name: "license_id", value: state.licenseId))
        queryItems.append(URLQueryItem(name: "device_hash", value: state.deviceHash))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AuthenticatedUpdateFeedError.invalidBaseURL
        }
        return url
    }
}

#if canImport(Sparkle)
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
#endif
