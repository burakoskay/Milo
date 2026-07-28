import XCTest
@testable import Milo

@MainActor
final class WhitelistManagerTests: XCTestCase {
    func testClearWhitelist() {
        let manager = WhitelistManager.shared

        // Setup initial state
        manager.clearWhitelist()

        // Add processes
        manager.addToWhitelist("com.apple.example1")
        manager.addToWhitelist("com.apple.example2")

        // Verify processes were added
        XCTAssertTrue(manager.isWhitelisted("com.apple.example1"))
        XCTAssertTrue(manager.isWhitelisted("com.apple.example2"))
        XCTAssertEqual(manager.getWhitelistedProcesses().count, 2)

        // Clear the whitelist
        manager.clearWhitelist()

        // Verify whitelist is cleared
        XCTAssertFalse(manager.isWhitelisted("com.apple.example1"))
        XCTAssertFalse(manager.isWhitelisted("com.apple.example2"))
        XCTAssertTrue(manager.getWhitelistedProcesses().isEmpty)
    }
}
