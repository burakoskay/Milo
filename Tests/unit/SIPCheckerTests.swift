import XCTest
@testable import Milo

final class SIPCheckerTests: XCTestCase {
    func testSIPEnabled() {
        let runner: (String, [String]) -> CommandResult = { _, _ in
            return CommandResult(
                status: 0,
                stdout: "System Integrity Protection status: enabled.",
                stderr: "",
                termination: .exited
            )
        }

        XCTAssertTrue(SIPChecker.isSIPEnabled(runner: runner))
    }

    func testSIPDisabled() {
        let runner: (String, [String]) -> CommandResult = { _, _ in
            return CommandResult(
                status: 0,
                stdout: "System Integrity Protection status: disabled.",
                stderr: "",
                termination: .exited
            )
        }

        XCTAssertFalse(SIPChecker.isSIPEnabled(runner: runner))
    }

    func testCommandFailureDefaultsToEnabled() {
        let runner: (String, [String]) -> CommandResult = { _, _ in
            return CommandResult(
                status: 1,
                stdout: "",
                stderr: "csrutil: command not found",
                termination: .exited
            )
        }

        XCTAssertTrue(SIPChecker.isSIPEnabled(runner: runner))
    }
}
