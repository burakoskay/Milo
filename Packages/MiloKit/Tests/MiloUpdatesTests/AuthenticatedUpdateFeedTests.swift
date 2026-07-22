import Foundation
import Testing
import MiloUpdates

@Suite("Authenticated update feed")
struct AuthenticatedUpdateFeedTests {
    @Test("entitlement URL includes verified license scope")
    func entitlementURL() throws {
        let url = try AuthenticatedUpdateFeed.makeURL(
            baseURL: try #require(URL(string: "https://monomacaw.com/functions/v1/update-feed")),
            state: AuthenticatedUpdateFeedState(
                appId: "milo",
                licenseId: "00000000-0000-0000-0000-000000000000",
                deviceHash: String(repeating: "0", count: 64)
            )
        )

        #expect(url.absoluteString.contains("app=milo"))
        #expect(url.absoluteString.contains("license_id=00000000-0000-0000-0000-000000000000"))
        #expect(!url.absoluteString.contains("hmac="))
    }
}
