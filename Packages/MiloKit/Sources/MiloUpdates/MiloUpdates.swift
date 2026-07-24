import CryptoKit
import Foundation
import MiloLicense

/// Security policy for fetching an MLP-selected Sparkle appcast.
public struct MiloAppcastPolicy: Sendable, Equatable {
    public static let defaultMaximumByteCount = 1_048_576
    public static let defaultTimeout: TimeInterval = 30

    public let allowedHosts: Set<String>
    public let maximumByteCount: Int
    public let timeout: TimeInterval

    public init(
        allowedHosts: Set<String>,
        maximumByteCount: Int = defaultMaximumByteCount,
        timeout: TimeInterval = defaultTimeout
    ) throws {
        let normalizedHosts = try Set(allowedHosts.map(Self.normalize(host:)))
        guard !normalizedHosts.isEmpty,
              (1 ... 8_388_608).contains(maximumByteCount),
              (1 ... 120).contains(timeout) else {
            throw MiloUpdateError.invalidPolicy
        }
        self.allowedHosts = normalizedHosts
        self.maximumByteCount = maximumByteCount
        self.timeout = timeout
    }

    /// Rejects a remote URL unless it is strict HTTPS on an explicitly allowed host.
    public func validate(remoteURL: URL) throws {
        guard remoteURL.scheme?.lowercased() == "https",
              let host = remoteURL.host?.lowercased(),
              allowedHosts.contains(host),
              remoteURL.user == nil,
              remoteURL.password == nil,
              remoteURL.fragment == nil,
              remoteURL.port == nil || remoteURL.port == 443,
              !remoteURL.path.isEmpty,
              remoteURL.path != "/" else {
            throw MiloUpdateError.untrustedAppcastURL
        }
    }

    private static func normalize(host: String) throws -> String {
        let normalized = host.lowercased()
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard normalized == host,
              !normalized.isEmpty,
              !normalized.hasPrefix("."),
              !normalized.hasSuffix("."),
              !normalized.contains(".."),
              normalized.utf8.count <= 253,
              normalized.unicodeScalars.allSatisfy(allowedScalars.contains),
              normalized.split(separator: ".").allSatisfy(Self.isValidDNSLabel) else {
            throw MiloUpdateError.invalidPolicy
        }
        return normalized
    }

    private static func isValidDNSLabel(_ label: Substring) -> Bool {
        guard (1 ... 63).contains(label.count),
              label.first != "-",
              label.last != "-" else {
            return false
        }
        return true
    }
}

/// Hash-verified appcast bytes selected by the authenticated MLP update endpoint.
public struct MiloVerifiedAppcast: Sendable, Equatable {
    public let remoteURL: URL
    public let sha256: String
    public let bytes: Data
}

/// Fail-closed update discovery and appcast-fetch errors.
public enum MiloUpdateError: Error, Sendable, Equatable {
    case invalidPolicy
    case invalidDescriptorHash
    case untrustedAppcastURL
    case redirectRejected
    case nonHTTPResponse
    case rejectedHTTPStatus(Int)
    case rejectedContentType(String?)
    case rejectedContentEncoding(String)
    case declaredResponseTooLarge
    case responseTooLarge
    case appcastHashMismatch
    case transportFailed
    case cancelled
}

extension MiloUpdateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Milo's update security policy is invalid."
        case .invalidDescriptorHash:
            return "The update service returned an invalid appcast digest."
        case .untrustedAppcastURL:
            return "The update service selected an appcast location Milo does not trust."
        case .redirectRejected:
            return "The appcast server attempted an unapproved redirect."
        case .nonHTTPResponse:
            return "The appcast server returned an unsupported response."
        case let .rejectedHTTPStatus(status):
            return "The appcast server returned HTTP status \(status)."
        case .rejectedContentType:
            return "The appcast server returned an unsupported content type."
        case .rejectedContentEncoding:
            return "The appcast server returned an encoded response Milo cannot verify byte for byte."
        case .declaredResponseTooLarge, .responseTooLarge:
            return "The appcast exceeded Milo's download safety limit."
        case .appcastHashMismatch:
            return "The downloaded appcast did not match the authenticated digest."
        case .transportFailed:
            return "Milo could not securely download the update feed."
        case .cancelled:
            return "The update check was cancelled."
        }
    }
}

/// Pure appcast validation used by the network loader and deterministic tests.
public enum MiloAppcastVerifier {
    /// Verifies descriptor policy, byte limit, and the exact lowercase SHA-256 digest.
    public static func verify(
        descriptor: MLPUpdateFeed,
        bytes: Data,
        policy: MiloAppcastPolicy
    ) throws -> MiloVerifiedAppcast {
        try policy.validate(remoteURL: descriptor.appcastURL)
        guard bytes.count <= policy.maximumByteCount else {
            throw MiloUpdateError.responseTooLarge
        }

        let expectedHash = descriptor.appcastSHA256
        guard expectedHash.count == 64,
              expectedHash.utf8.allSatisfy(Self.isLowercaseHexDigit) else {
            throw MiloUpdateError.invalidDescriptorHash
        }

        let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actualHash == expectedHash else {
            throw MiloUpdateError.appcastHashMismatch
        }
        return MiloVerifiedAppcast(
            remoteURL: descriptor.appcastURL,
            sha256: actualHash,
            bytes: bytes
        )
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
    }
}

/// Downloads an appcast using an ephemeral, cookie-free, no-cache, no-redirect session.
public struct MiloAppcastLoader: Sendable {
    private let policy: MiloAppcastPolicy

    public init(policy: MiloAppcastPolicy) {
        self.policy = policy
    }

    public func load(descriptor: MLPUpdateFeed) async throws -> MiloVerifiedAppcast {
        try policy.validate(remoteURL: descriptor.appcastURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.timeout
        configuration.timeoutIntervalForResource = policy.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false

        let session = URLSession(
            configuration: configuration,
            delegate: MiloRedirectRejectingDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: descriptor.appcastURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = policy.timeout
        request.setValue("application/rss+xml, application/xml;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            try MiloAppcastHTTPResponseValidator.validate(response, policy: policy)

            var appcastData = Data()
            if response.expectedContentLength > 0 {
                appcastData.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard appcastData.count < policy.maximumByteCount else {
                    throw MiloUpdateError.responseTooLarge
                }
                appcastData.append(byte)
            }
            return try MiloAppcastVerifier.verify(
                descriptor: descriptor,
                bytes: appcastData,
                policy: policy
            )
        } catch let error as MiloUpdateError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw MiloUpdateError.cancelled
            }
            throw MiloUpdateError.transportFailed
        }
    }
}

enum MiloAppcastHTTPResponseValidator {
    private static let acceptedContentTypes: Set<String> = [
        "application/octet-stream",
        "application/rss+xml",
        "application/xml",
        "text/xml"
    ]

    static func validate(_ response: URLResponse, policy: MiloAppcastPolicy) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MiloUpdateError.nonHTTPResponse
        }
        if (300 ... 399).contains(httpResponse.statusCode) {
            throw MiloUpdateError.redirectRejected
        }
        guard httpResponse.statusCode == 200 else {
            throw MiloUpdateError.rejectedHTTPStatus(httpResponse.statusCode)
        }
        try validateContentType(httpResponse.value(forHTTPHeaderField: "Content-Type"))
        if let contentEncoding = httpResponse.value(forHTTPHeaderField: "Content-Encoding"),
           contentEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            throw MiloUpdateError.rejectedContentEncoding(contentEncoding)
        }
        if response.expectedContentLength > Int64(policy.maximumByteCount) {
            throw MiloUpdateError.declaredResponseTooLarge
        }
    }

    private static func validateContentType(_ rawContentType: String?) throws {
        guard let rawContentType else {
            throw MiloUpdateError.rejectedContentType(nil)
        }
        let normalized = rawContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized,
              acceptedContentTypes.contains(normalized) else {
            throw MiloUpdateError.rejectedContentType(rawContentType)
        }
    }
}

/// Immutable and stateless; redirect callbacks never access shared mutable state.
private final class MiloRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
