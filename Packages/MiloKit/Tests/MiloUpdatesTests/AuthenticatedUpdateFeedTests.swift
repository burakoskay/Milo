import CryptoKit
import Foundation
import MiloLicense
@testable import MiloUpdates
import Testing

@Suite("Authenticated update feed")
struct AuthenticatedUpdateFeedTests {
    private let trustedURL = URL(string: "https://monomacaw.com/releases/milo/appcast.xml")

    @Test("authenticated digest accepts the exact trusted appcast bytes")
    func exactDigest() throws {
        let bytes = Data("<rss version=\"2.0\"></rss>".utf8)
        let policy = try MiloAppcastPolicy(allowedHosts: ["monomacaw.com"])
        let descriptor = MLPUpdateFeed(
            appcastURL: try #require(trustedURL),
            appcastSHA256: sha256(bytes)
        )

        let verified = try MiloAppcastVerifier.verify(
            descriptor: descriptor,
            bytes: bytes,
            policy: policy
        )

        #expect(verified.bytes == bytes)
        #expect(verified.remoteURL == trustedURL)
        #expect(verified.sha256 == descriptor.appcastSHA256)
    }

    @Test("digest mismatch fails closed")
    func digestMismatch() throws {
        let bytes = Data("<rss></rss>".utf8)
        let policy = try MiloAppcastPolicy(allowedHosts: ["monomacaw.com"])
        let descriptor = MLPUpdateFeed(
            appcastURL: try #require(trustedURL),
            appcastSHA256: String(repeating: "0", count: 64)
        )

        #expect(throws: MiloUpdateError.appcastHashMismatch) {
            try MiloAppcastVerifier.verify(descriptor: descriptor, bytes: bytes, policy: policy)
        }
    }

    @Test("descriptor digest must use canonical lowercase hexadecimal")
    func canonicalDigest() throws {
        let bytes = Data("<rss></rss>".utf8)
        let policy = try MiloAppcastPolicy(allowedHosts: ["monomacaw.com"])
        let descriptor = MLPUpdateFeed(
            appcastURL: try #require(trustedURL),
            appcastSHA256: String(repeating: "A", count: 64)
        )

        #expect(throws: MiloUpdateError.invalidDescriptorHash) {
            try MiloAppcastVerifier.verify(descriptor: descriptor, bytes: bytes, policy: policy)
        }
    }

    @Test(
        "untrusted remote locations are rejected",
        arguments: [
            "http://monomacaw.com/releases/appcast.xml",
            "https://cdn.example.com/releases/appcast.xml",
            "https://user@monomacaw.com/releases/appcast.xml",
            "https://monomacaw.com:8443/releases/appcast.xml",
            "https://monomacaw.com/releases/appcast.xml#fragment",
            "https://monomacaw.com/"
        ]
    )
    func untrustedLocation(rawURL: String) throws {
        let policy = try MiloAppcastPolicy(allowedHosts: ["monomacaw.com"])
        let url = try #require(URL(string: rawURL))

        #expect(throws: MiloUpdateError.untrustedAppcastURL) {
            try policy.validate(remoteURL: url)
        }
    }

    @Test("configured body limit is enforced before Sparkle receives bytes")
    func bodyLimit() throws {
        let policy = try MiloAppcastPolicy(
            allowedHosts: ["monomacaw.com"],
            maximumByteCount: 4
        )
        let bytes = Data("12345".utf8)
        let descriptor = MLPUpdateFeed(
            appcastURL: try #require(trustedURL),
            appcastSHA256: sha256(bytes)
        )

        #expect(throws: MiloUpdateError.responseTooLarge) {
            try MiloAppcastVerifier.verify(descriptor: descriptor, bytes: bytes, policy: policy)
        }
    }

    @Test("host allowlist is explicit and canonical")
    func hostPolicy() {
        #expect(throws: MiloUpdateError.invalidPolicy) {
            try MiloAppcastPolicy(allowedHosts: [])
        }
        #expect(throws: MiloUpdateError.invalidPolicy) {
            try MiloAppcastPolicy(allowedHosts: ["*.monomacaw.com"])
        }
        #expect(throws: MiloUpdateError.invalidPolicy) {
            try MiloAppcastPolicy(allowedHosts: ["MONOMACAW.COM"])
        }
    }

    @Test("HTTP response metadata is fail-closed before body streaming")
    func responseMetadata() throws {
        let url = try #require(trustedURL)
        let policy = try MiloAppcastPolicy(
            allowedHosts: ["monomacaw.com"],
            maximumByteCount: 16
        )
        let acceptedResponse = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/rss+xml; charset=utf-8",
                "Content-Encoding": "identity",
                "Content-Length": "16"
            ]
        ))
        try MiloAppcastHTTPResponseValidator.validate(acceptedResponse, policy: policy)

        let nonHTTPResponse = URLResponse(
            url: url,
            mimeType: "application/rss+xml",
            expectedContentLength: 1,
            textEncodingName: nil
        )
        #expect(throws: MiloUpdateError.nonHTTPResponse) {
            try MiloAppcastHTTPResponseValidator.validate(nonHTTPResponse, policy: policy)
        }
        try expectResponseError(.redirectRejected, status: 302, headers: ["Content-Type": "application/rss+xml"])
        try expectResponseError(.rejectedHTTPStatus(503), status: 503, headers: ["Content-Type": "application/rss+xml"])
        try expectResponseError(.rejectedContentType(nil), status: 200, headers: [:])
        try expectResponseError(.rejectedContentType("text/html"), status: 200, headers: ["Content-Type": "text/html"])
        try expectResponseError(
            .rejectedContentEncoding("gzip"),
            status: 200,
            headers: ["Content-Type": "application/rss+xml", "Content-Encoding": "gzip"]
        )
        try expectResponseError(
            .declaredResponseTooLarge,
            status: 200,
            headers: ["Content-Type": "application/rss+xml", "Content-Length": "17"]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectResponseError(
        _ expectedError: MiloUpdateError,
        status: Int,
        headers: [String: String]
    ) throws {
        let url = try #require(trustedURL)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
        let policy = try MiloAppcastPolicy(
            allowedHosts: ["monomacaw.com"],
            maximumByteCount: 16
        )
        #expect(throws: expectedError) {
            try MiloAppcastHTTPResponseValidator.validate(response, policy: policy)
        }
    }
}
