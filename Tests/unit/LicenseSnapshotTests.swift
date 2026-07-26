import MiloDomain
import XCTest

final class LicenseSnapshotTests: XCTestCase {
    func testLockedSnapshotGrantsNoCapabilities() {
        let snapshot = LicenseSnapshot.locked

        XCTAssertFalse(snapshot.isPro)
        XCTAssertTrue(snapshot.productEntitlements.isEmpty)
        XCTAssertNil(snapshot.issuedAt)
        XCTAssertNil(snapshot.expiresAt)
        XCTAssertNil(snapshot.userID)
        XCTAssertNil(snapshot.licenseID)
        XCTAssertNil(snapshot.deviceKeyID)
    }
}
