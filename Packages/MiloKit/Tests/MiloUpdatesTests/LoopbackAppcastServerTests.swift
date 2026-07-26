import CryptoKit
import Foundation
import MiloLicense
@testable import MiloUpdates
import Testing

@Suite("Exact-byte Sparkle bridge")
struct LoopbackAppcastServerTests {
    @Test("tokenized loopback endpoint serves the verified bytes unchanged")
    func exactBytes() async throws {
        let bytes = Data("<rss version=\"2.0\"><channel></channel></rss>".utf8)
        let appcast = try verifiedAppcast(bytes: bytes)
        let server = MiloLoopbackAppcastServer()

        do {
            let endpoint = try await server.start(appcast: appcast)
            let localURL = endpoint.url
            #expect(localURL.scheme == "http")
            #expect(localURL.host == "127.0.0.1")
            #expect(localURL.path.hasPrefix("/milo-update/"))

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (downloadedBytes, response) = try await session.data(from: localURL)
            let httpResponse = try #require(response as? HTTPURLResponse)

            #expect(httpResponse.statusCode == 200)
            #expect(downloadedBytes == bytes)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test("unpredictable path is required and replacing a feed invalidates the old endpoint")
    func tokenAndReplacement() async throws {
        let firstBytes = Data("<rss><channel>first</channel></rss>".utf8)
        let secondBytes = Data("<rss><channel>second</channel></rss>".utf8)
        let server = MiloLoopbackAppcastServer()

        do {
            let firstEndpoint = try await server.start(appcast: verifiedAppcast(bytes: firstBytes))
            let firstURL = firstEndpoint.url
            var invalidComponents = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
            invalidComponents.path = "/milo-update/invalid/appcast.xml"
            let invalidURL = try #require(invalidComponents.url)
            let (invalidData, invalidResponse) = try await URLSession.shared.data(from: invalidURL)
            let invalidHTTPResponse = try #require(invalidResponse as? HTTPURLResponse)
            #expect(invalidHTTPResponse.statusCode == 404)
            #expect(invalidData.isEmpty)

            let secondEndpoint = try await server.start(appcast: verifiedAppcast(bytes: secondBytes))
            let secondURL = secondEndpoint.url
            #expect(firstURL != secondURL)
            await expectEndpointIsInvalid(firstURL)

            await server.stop(endpoint: firstEndpoint)

            let (downloadedBytes, response) = try await URLSession.shared.data(from: secondURL)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 200)
            #expect(downloadedBytes == secondBytes)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test("bridge retires after the bounded number of successful reads")
    func successfulReadLimit() async throws {
        let bytes = Data("<rss><channel>bounded</channel></rss>".utf8)
        let server = MiloLoopbackAppcastServer()

        do {
            let endpoint = try await server.start(appcast: verifiedAppcast(bytes: bytes))
            let localURL = endpoint.url
            for _ in 0 ..< 3 {
                let (downloadedBytes, response) = try await URLSession.shared.data(from: localURL)
                let httpResponse = try #require(response as? HTTPURLResponse)
                #expect(httpResponse.statusCode == 200)
                #expect(downloadedBytes == bytes)
            }
            await expectEndpointIsInvalid(localURL)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func verifiedAppcast(bytes: Data) throws -> MiloVerifiedAppcast {
        let remoteURL = try #require(URL(string: "https://monomacaw.com/releases/appcast.xml"))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let policy = try MiloAppcastPolicy(allowedHosts: ["monomacaw.com"])
        return try MiloAppcastVerifier.verify(
            descriptor: MLPUpdateFeed(appcastURL: remoteURL, appcastSHA256: hash),
            bytes: bytes,
            policy: policy
        )
    }

    private func expectEndpointIsInvalid(_ url: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                Issue.record("Superseded endpoint returned a non-HTTP response")
                return
            }
            #expect(httpResponse.statusCode == 404)
            #expect(data.isEmpty)
        } catch let error as URLError {
            let expectedTransportFailures: Set<URLError.Code> = [
                .cannotConnectToHost,
                .networkConnectionLost,
                .timedOut
            ]
            #expect(expectedTransportFailures.contains(error.code))
        } catch {
            Issue.record("Superseded endpoint failed unexpectedly: \(error.localizedDescription)")
        }
    }
}
