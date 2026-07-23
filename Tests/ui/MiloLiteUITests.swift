import XCTest

final class MiloLiteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsReadOnlyCapabilityAndRescanControl() {
        let application = XCUIApplication()
        application.launchArguments = ["--ui-testing"]
        application.launch()

        XCTAssertTrue(
            application.staticTexts["miloLite.title"].waitForExistence(timeout: 8),
            "Milo Lite title did not appear"
        )
        XCTAssertTrue(
            application.staticTexts["miloLite.limitations"].waitForExistence(timeout: 3),
            "Milo Lite capability limitation did not appear"
        )
        XCTAssertTrue(application.buttons["miloLite.scan"].isEnabled)

        application.terminate()
    }
}
