import Foundation
import XCTest

/// Guards the invariants that keep open discovery from becoming a way to break macOS, and
/// the uninstall path from becoming a way to delete the wrong files.
///
/// These are source-level assertions because the properties they protect are structural: the
/// app target cannot be imported by a test bundle here, and a runtime test would have to
/// actually signal system processes to prove the negative.
final class ProcessDiscoverySafetyRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - The root helper does not trust the client

    func testHelperIndependentlyRefusesCriticalSystemExecutables() throws {
        let helper = try source("Helper/MiloPrivilegedHelper/main.swift")

        // The helper must reach its own verdict, using the same shared list as the app rather
        // than a copy that can drift.
        XCTAssertTrue(
            helper.contains("MiloProcessSafetyPolicy.isCriticalSystemExecutable"),
            "The root helper must refuse session-critical executables independently of the client"
        )
        XCTAssertTrue(helper.contains("import MiloDomain"))
    }

    func testHelperIndependentlyRefusesDisablingCriticalLaunchdJobs() throws {
        let helper = try source("Helper/MiloPrivilegedHelper/main.swift")

        // A kill request carries an executable path, so `isCriticalSystemExecutable` gates it.
        // A `launchctl disable` request carries only a label, so it needs its own gate — and
        // without one, the launchctl grammar accepts `disable system/com.apple.WindowServer`
        // on nothing but a character-set check.
        XCTAssertTrue(
            helper.contains("MiloProcessSafetyPolicy.isCriticalLaunchdLabel"),
            "The root helper must refuse to disable session-critical launchd jobs independently"
        )
        XCTAssertTrue(
            helper.contains("refusingCriticalLabels"),
            "The stop verbs must pass the refusal through to the domain-target check"
        )
    }

    func testTheClientAlsoRefusesDisablingCriticalLaunchdJobs() throws {
        let runner = try source("App/Milo/Runtime/CommandRunner.swift")

        XCTAssertTrue(runner.contains("MiloProcessSafetyPolicy.isCriticalLaunchdLabel"))
        XCTAssertTrue(runner.contains("import MiloDomain"))
    }

    func testRecoveringACriticalLaunchdJobIsStillPossible() throws {
        let helper = try source("Helper/MiloPrivilegedHelper/main.swift")
        let runner = try source("App/Milo/Runtime/CommandRunner.swift")

        // `enable` is the recovery verb. Refusing it too would mean that a session-critical
        // job disabled by any other means could never be put back through Milo. Both sides
        // must scope the refusal to the stop verbs only.
        for source in [helper, runner] {
            XCTAssertTrue(
                source.contains("action == \"disable\" || action == \"bootout\""),
                "The critical-label refusal must be scoped to the stop verbs, leaving enable available"
            )
        }
    }

    func testHelperRequiresAnExpectedIdentityForEverySignal() throws {
        let helper = try source("Helper/MiloPrivilegedHelper/main.swift")

        // A kill with no expected identity is a PID-only kill, which races process exit.
        XCTAssertTrue(helper.contains("let expectedProcessIdentity,"))
        XCTAssertTrue(helper.contains("expectedProcessIdentity.pid == pid"))
        XCTAssertTrue(helper.contains("pid > 1"))
        XCTAssertTrue(helper.contains("pid != getpid()"))
    }

    // MARK: - Discovery cannot escalate itself

    func testDiscoveryNeverClaimsAReviewedRule() throws {
        let scanner = try source("App/Milo/Runtime/BackgroundProcessScanner.swift")

        // `matchesReviewedRule` is the single flag that allows Milo to act on Apple system
        // software. Open discovery must never set it: only the catalogue and signed telemetry
        // rules may, and those travel a different path.
        XCTAssertTrue(scanner.contains("matchesReviewedRule: false"))
        XCTAssertFalse(scanner.contains("matchesReviewedRule: true"))
    }

    func testDiscoveredTerminationRefusesProtectedProcessesAtTheManager() throws {
        let processManager = try source("App/Milo/Runtime/ProcessManager.swift")

        // The refusal must exist below the view layer. A check that lives only in SwiftUI is
        // one that disappears the first time someone adds another call site.
        XCTAssertTrue(processManager.contains("candidate.safety.isActionable"))
        XCTAssertTrue(processManager.contains("protectedProcessTerminationRefused"))
    }

    func testDiscoverySelectionCannotIncludeProtectedProcesses() throws {
        let appState = try source("App/Milo/Runtime/AppState.swift")

        XCTAssertTrue(appState.contains("discoveredProcesses[index].isActionable == true"))
        XCTAssertTrue(appState.contains("$0.isSelected && $0.isActionable"))
    }

    func testDiscoveryIsClassifiedByPolicyRatherThanByName() throws {
        let scanner = try source("App/Milo/Runtime/BackgroundProcessScanner.swift")

        XCTAssertTrue(scanner.contains("MiloProcessSafetyPolicy.classify"))
        // Evidence, not display names: a process chooses its own argv[0].
        XCTAssertTrue(scanner.contains("inspector.isAppleSigned"))
        XCTAssertTrue(scanner.contains("effectiveUserID: information.pbi_uid"))
    }

    func testAppleSignatureUsesTheStrictAnchor() throws {
        let inspector = try source("App/Milo/Runtime/ProcessSafetyInspector.swift")

        // `anchor apple generic` is satisfied by every Developer ID binary and would classify
        // third-party software as the operating system. Asserted against the requirement
        // literal rather than the whole file, which is free to explain the distinction in prose.
        XCTAssertTrue(inspector.contains("\"anchor apple\" as CFString"))
        XCTAssertFalse(inspector.contains("\"anchor apple generic\" as CFString"))
        XCTAssertFalse(inspector.contains("SecRequirementCreateWithString(\"anchor apple generic\""))
    }

    // MARK: - Disabling a launchd job

    func testDisablingALaunchdJobRechecksThePolicyBelowTheUI() throws {
        let processManager = try source("App/Milo/Runtime/ProcessManager.swift")

        // Disabling a launch item rewrites macOS configuration and outlives the click, so the
        // verdict cannot live only in the view that drew the button.
        XCTAssertTrue(processManager.contains("MiloLaunchdDisablePolicy.refusal(forLabel: job.label)"))
        XCTAssertTrue(processManager.contains("launchdDisableRefused"))
    }

    func testDisablingALaunchdJobIsAlwaysConfirmedFirst() throws {
        let appState = try source("App/Milo/Runtime/AppState.swift")

        // `requestLaunchdDisable` may only stage the job; the command runs from
        // `confirmLaunchdDisable`. A termination click must never rewrite launchd config.
        guard let requestRange = appState.range(of: "func requestLaunchdDisable("),
              let confirmRange = appState.range(of: "func confirmLaunchdDisable(") else {
            return XCTFail("The launchd disable flow could not be located")
        }
        let requestBody = String(appState[requestRange.lowerBound..<confirmRange.lowerBound])
        XCTAssertFalse(
            requestBody.contains("ProcessManager.shared.disableLaunchdJob"),
            "Requesting a disable must only stage it for confirmation, never run it"
        )
        XCTAssertTrue(appState.contains("pendingLaunchdDisable = job"))

        let confirmBody = String(appState[confirmRange.lowerBound...])
        XCTAssertTrue(confirmBody.contains("ProcessManager.shared.disableLaunchdJob"))
    }

    func testTheDisableOfferOnlyExistsForAProcessThatCameBack() throws {
        let appState = try source("App/Milo/Runtime/AppState.swift")

        // The offer is derived from results, so it must be gated on the respawn flag. Offering
        // to disable a launch item whose process stayed dead would be acting on nothing.
        XCTAssertTrue(appState.contains("for result in results where result.wasRespawned"))
    }

    func testTheDisableTargetIsBuiltFromTheLabelNotADisplayName() throws {
        let processManager = try source("App/Milo/Runtime/ProcessManager.swift")

        XCTAssertTrue(processManager.contains("\"system/\\(job.label)\""))
        XCTAssertTrue(processManager.contains("\"gui/\\(getuid())/\\(job.label)\""))
        XCTAssertTrue(processManager.contains("arguments: [action, target]"))
    }

    func testDisablingALaunchdJobAlsoStopsTheRunningInstance() throws {
        let processManager = try source("App/Milo/Runtime/ProcessManager.swift")

        // Measured on macOS 27.0: `launchctl disable` succeeds, reports the job disabled, and
        // the job keeps respawning, because the disable only applies at the next bootstrap.
        // `disable` alone would ship a button that claims success while the user watches the
        // process return. Both commands are required, and `disable` must come first so an
        // interruption leaves the persistent guarantee in place rather than the reverse.
        guard let disableIndex = processManager.range(of: "run(\"disable\")")?.lowerBound,
              let bootoutIndex = processManager.range(of: "run(\"bootout\")")?.lowerBound else {
            return XCTFail("The disable/bootout sequence could not be located")
        }
        XCTAssertLessThan(
            disableIndex,
            bootoutIndex,
            "disable must precede bootout, so an interrupted sequence still survives a restart"
        )
    }

    // MARK: - Uninstall containment

    func testUninstallChecksContainmentImmediatelyBeforeEveryRemoval() throws {
        let manager = try source("App/Milo/Runtime/UninstallManager.swift")

        XCTAssertTrue(manager.contains("MiloUninstallPlan.isRemovable(item.path, homeDirectory: home)"))
        XCTAssertTrue(manager.contains("uninstallItemRejected"))

        // Every removal must be gated. `removeItem` appears exactly once, inside the branch
        // guarded above.
        let removals = manager.components(separatedBy: "removeItem(atPath:").count - 1
        XCTAssertEqual(removals, 1, "Uninstall must have exactly one removal site, behind the containment gate")
        XCTAssertFalse(manager.contains("removeItem(at:"))
    }

    func testUninstallNeverDeletesTheApplicationBundleOutright() throws {
        let manager = try source("App/Milo/Runtime/UninstallManager.swift")

        // The bundle goes to the Trash so the user can undo, and only after the helper has
        // actually been unregistered.
        XCTAssertTrue(manager.contains("NSWorkspace.shared.recycle"))
        XCTAssertTrue(manager.contains("steps.first(where: { $0.id == \"helper\" })?.outcome.succeeded"))
    }

    func testUninstallDoesNotResetBackgroundItemsForEveryApp() throws {
        let manager = try source("App/Milo/Runtime/UninstallManager.swift")
        let view = try source("App/Milo/Runtime/UninstallView.swift")

        // `sfltool resetbtm` clears background items for every application on the Mac. It may
        // be named in guidance to warn against it, but never executed.
        XCTAssertFalse(manager.contains("sfltool"))
        XCTAssertFalse(view.contains("CommandRunner"))
        XCTAssertTrue(view.contains("Never use sfltool resetbtm"))
    }

    func testUninstallUnregistersTheHelperBeforeRemovingFiles() throws {
        let manager = try source("App/Milo/Runtime/UninstallManager.swift")

        guard let helperIndex = manager.range(of: "unregisterHelper { [weak self] helperResult in")?.lowerBound,
              let filesIndex = manager.range(of: "collected.append(contentsOf: self.removePlannedItems())")?.lowerBound else {
            return XCTFail("Uninstall ordering could not be located")
        }
        XCTAssertLessThan(
            helperIndex,
            filesIndex,
            "The helper registration must be removed before Milo's files, or a partial failure leaves an orphaned root daemon"
        )
    }
}
