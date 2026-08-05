import MiloDomain
import Security
import XCTest

/// `MiloDomain` is deliberately pure — it imports only `Darwin` and `Foundation` — so the
/// Code Signing statuses it interprets are written there as literals. That is the only way the
/// policy stays unit-testable without a root process, and it is also the only way those literals
/// could silently stop meaning what they say.
///
/// These tests are the pin. They run where `Security` is available and assert the literals still
/// equal the SDK constants they document.
final class HelperFreshnessStatusPinningTests: XCTestCase {
    func testSuccessStatusMatchesSecurityFramework() {
        XCTAssertEqual(MiloHelperFreshnessPolicy.codeValidationSucceeded, errSecSuccess)
    }

    func testStaticCodeChangedMatchesSecurityFramework() {
        // "the code on disk does not match what is running" — the staleness condition itself.
        XCTAssertEqual(MiloHelperFreshnessPolicy.staticCodeChanged, errSecCSStaticCodeChanged)
    }

    func testRequirementFailedMatchesSecurityFramework() {
        XCTAssertEqual(MiloHelperFreshnessPolicy.requirementFailed, errSecCSReqFailed)
    }

    /// The three statuses must stay distinct, or the mapping collapses and two different
    /// measurements start producing one verdict.
    func testInterpretedStatusesAreDistinct() {
        let statuses: Set<Int32> = [
            MiloHelperFreshnessPolicy.codeValidationSucceeded,
            MiloHelperFreshnessPolicy.staticCodeChanged,
            MiloHelperFreshnessPolicy.requirementFailed
        ]

        XCTAssertEqual(statuses.count, 3)
    }

    /// A real Security status the policy does not interpret must remain undetermined, so a
    /// signature failure is never presented to the user as "your helper is out of date".
    func testUninterpretedSecurityStatusStaysUndetermined() {
        let verdict = MiloHelperFreshnessPolicy.freshness(
            forCodeValidationStatus: errSecCSSignatureFailed
        )

        XCTAssertFalse(verdict.isStale)
        XCTAssertEqual(
            verdict,
            .undetermined(.validationInconclusive(status: errSecCSSignatureFailed))
        )
    }
}
