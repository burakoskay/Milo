import Foundation
import XCTest

/// Guards the one property that makes `Tools/vm-verify.sh` safe to have in the repository at all:
/// its destructive checks must refuse to run anywhere but a marked virtual machine.
///
/// The script unregisters daemons, kills root processes, and rewrites launchd configuration. A
/// regression that weakens the guard would not fail loudly — it would run, on someone's working
/// Mac, and the first sign would be the damage.
final class VMVerifyHarnessSafetyTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptURL: URL {
        repositoryRoot.appendingPathComponent("Tools/vm-verify.sh")
    }

    private func script() throws -> String {
        try String(contentsOf: scriptURL, encoding: .utf8)
    }

    func testDestructiveCommandsAreGuarded() throws {
        let source = try script()

        // Both destructive subcommands must call the guard, and it must be the first thing they
        // do. A guard placed after the fixture is created is not a guard.
        for command in ["cmd_launchd_system()", "cmd_helper_restart()"] {
            guard let range = source.range(of: "\(command) {") else {
                return XCTFail("\(command) is missing — did the harness change shape?")
            }
            let following = source[range.upperBound...].prefix(200)
            XCTAssertTrue(
                following.contains("require_disposable_vm"),
                "\(command) must call require_disposable_vm before doing anything"
            )
        }
    }

    func testTheGuardRequiresBothAHypervisorAndAnExplicitMarker() throws {
        let source = try script()

        // Two independent conditions. One check is one typo away from running on a real Mac.
        XCTAssertTrue(source.contains("kern.hv_vmm_present"))
        XCTAssertTrue(source.contains("/etc/milo-disposable-vm"))
        XCTAssertTrue(source.contains("exit 2"))
    }

    func testTheGuardHasNoEnvironmentOverride() throws {
        let source = try script()

        guard let start = source.range(of: "require_disposable_vm() {"),
              let end = source.range(
                of: "\n}",
                range: start.upperBound..<source.endIndex
              ) else {
            return XCTFail("require_disposable_vm could not be located")
        }
        let body = String(source[start.upperBound..<end.lowerBound])

        // An override defeats the purpose: the one thing that must not be easy is running this
        // somewhere it should not run. Making it easy for a hurried operator is the whole risk.
        XCTAssertFalse(body.contains("FORCE"))
        XCTAssertFalse(body.contains("MILO_VM"))
        XCTAssertFalse(body.contains("$SKIP"))
    }

    func testTheHarnessIsExecutableAndSyntacticallyValid() throws {
        let values = try scriptURL.resourceValues(forKeys: [.isExecutableKey])
        XCTAssertEqual(values.isExecutable, true, "Tools/vm-verify.sh must be executable")

        // `bash -n` parses without running. Cheap, and it catches the class of mistake that would
        // otherwise only surface on the VM, where nobody is watching a CI log.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Tools/vm-verify.sh has a syntax error")
    }

    func testTheDestructiveFixtureIsAlwaysCleanedUp() throws {
        let source = try script()

        // The fixture is a root LaunchDaemon. Leaving one behind on a failed run turns a
        // disposable VM into a dirty one, and the next run's results describe the mess.
        XCTAssertTrue(source.contains("trap cleanup_system_fixture EXIT"))
    }
}
