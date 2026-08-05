import Foundation
import XCTest

/// Pins decision 0005: the runtime signature check detects, and deliberately does not enforce.
///
/// These assertions exist so that adding enforcement requires re-opening
/// `docs/decisions/0005-defer-tamper-enforcement-to-1.0.md` rather than happening by accident —
/// which is precisely how the previous state arose, where three documents described a
/// tamper-exit that a red-team test simultaneously forbade.
///
/// Note that this file may not spell that exit literal out: `Exit173RegressionTest` scans `Tests`
/// as well as the shipping sources, and it is right to. Writing the marker here to talk *about*
/// it would be indistinguishable, to a text scan, from reintroducing it.
///
/// Source-level assertions, for the same reason as the discovery suite: the app target cannot be
/// imported by a test bundle here, and the alternative is a runtime test that tampers with the
/// running binary.
final class DetectionOnlyIntegrityTests: XCTestCase {
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

    func testTheCheckStillRunsAtLaunch() throws {
        let delegate = try source("App/Milo/Runtime/MenuBarAppDelegate.swift")

        // Detection-only is not the same as absent. The check must still run: the packaged smoke
        // suite asserts the same requirement, and that assertion is what proved the gonggong
        // rename had not broken the requirement string in Integrity.c.
        XCTAssertTrue(delegate.contains("MiloIntegrity.check(.launch)"))
        XCTAssertTrue(delegate.contains("performRuntimeSignatureCheck()"))
    }

    func testAFailedCheckIsReported() throws {
        let delegate = try source("App/Milo/Runtime/MenuBarAppDelegate.swift")

        // Detecting silently would be worse than not detecting: it produces no evidence for
        // anyone diagnosing a real compromise.
        XCTAssertTrue(delegate.contains("runtimeIntegrityFailed"))
    }

    func testAFailedCheckWritesNoFlagThatNothingReads() throws {
        let body = try runtimeSignatureCheckBody()

        // The compromised flag was written and never read anywhere in the project. A flag no code
        // consults reads as a control when it is a note to nobody, and it is exactly what a later
        // session wires an action to without re-opening decision 0005.
        //
        // Asserted against the function body rather than the whole file, so the comment above it
        // stays free to name the removed key and explain why it went. A guard that forbids
        // discussing what it guards makes the codebase harder to understand, not safer — the
        // first version of this test did exactly that and failed on its own explanation.
        XCTAssertFalse(
            body.contains("UserDefaults"),
            "The write-only compromised flag was removed by decision 0005; do not reintroduce it"
        )
        XCTAssertFalse(body.contains("compromised"))
    }

    /// The text of `performRuntimeSignatureCheck`, excluding the documentation above it.
    private func runtimeSignatureCheckBody() throws -> String {
        let delegate = try source("App/Milo/Runtime/MenuBarAppDelegate.swift")
        guard let checkRange = delegate.range(of: "private func performRuntimeSignatureCheck()"),
              let endRange = delegate.range(
                  of: "// MARK: - Typed Notification Names",
                  range: checkRange.upperBound..<delegate.endIndex
              ) else {
            // Deliberately an error and not a skip. If the function cannot be located, this guard
            // has stopped guarding, and a skipped test reports that as "fine".
            throw LocationFailure.checkNotFound
        }
        return String(delegate[checkRange.lowerBound..<endRange.lowerBound])
    }

    private enum LocationFailure: Error {
        case checkNotFound
    }

    func testAFailedCheckDoesNotTerminateOrDisableAnything() throws {
        let body = try runtimeSignatureCheckBody()

        // Enforcement is a 1.0 decision made alongside licensing, because what a failed check
        // should mean depends on whether there is a license to check. Refusing to run is also the
        // weakest option on its merits: trivially patched out by the person it targets, while a
        // false positive bricks the app for a legitimate user.
        for enforcement in ["exit(", "fatalError", "NSApp.terminate", "abort()", "kill("] {
            XCTAssertFalse(
                body.contains(enforcement),
                "Decision 0005 defers enforcement to 1.0; `\(enforcement)` here reverses it silently"
            )
        }
    }

    func testTheDecisionRecordExistsAndIsAccepted() throws {
        // The reasoning behind `Exit173RegressionTest` was recorded nowhere, which is what made
        // the false documentation survive so long. This asserts the replacement is present.
        let record = try source("docs/decisions/0005-defer-tamper-enforcement-to-1.0.md")

        XCTAssertTrue(record.contains("**Status:** Accepted"))
        XCTAssertTrue(record.contains("Exit173RegressionTest"))
    }
}
