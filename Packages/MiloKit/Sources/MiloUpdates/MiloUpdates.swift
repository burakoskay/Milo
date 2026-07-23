import Foundation

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
