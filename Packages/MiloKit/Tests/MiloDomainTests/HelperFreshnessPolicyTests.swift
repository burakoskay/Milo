import Foundation
import MiloDomain
import Testing

@Suite("Privileged helper freshness")
struct HelperFreshnessPolicyTests {
    private func freshness(_ status: Int32) -> MiloHelperFreshness {
        MiloHelperFreshnessPolicy.freshness(forCodeValidationStatus: status)
    }

    // MARK: - The case that motivated this check

    @Test("a helper whose on-disk binary was replaced is stale, not current")
    func replacedInstalledCodeIsStale() {
        // Installing build 22 over build 21 left the build 21 helper running and serving
        // requests, while launchctl still reported the registration as healthy.
        #expect(
            freshness(MiloHelperFreshnessPolicy.staticCodeChanged)
                == .stale(.installedCodeReplaced)
        )
    }

    @Test("a helper that is not the installed binary is stale")
    func differentCodeIdentityIsStale() {
        #expect(
            freshness(MiloHelperFreshnessPolicy.requirementFailed)
                == .stale(.differentCodeIdentity)
        )
    }

    @Test("a helper matching the installed binary is current")
    func matchingCodeIsCurrent() {
        #expect(freshness(MiloHelperFreshnessPolicy.codeValidationSucceeded) == .current)
    }

    // MARK: - Milo never guesses

    @Test("an unrecognised validation status is undetermined, never stale")
    func unrecognisedStatusIsUndetermined() {
        // -67062 is errSecCSSignatureFailed: a real Security status this policy does not
        // interpret. Reporting it as stale would nag the user over a measurement Milo
        // did not actually make.
        let verdict = freshness(-67_062)

        #expect(verdict == .undetermined(.validationInconclusive(status: -67_062)))
        #expect(verdict.isStale == false)
    }

    @Test("no unrecognised status is ever reported as current or stale")
    func onlyKnownStatusesProduceAVerdict() {
        let recognised: Set<Int32> = [
            MiloHelperFreshnessPolicy.codeValidationSucceeded,
            MiloHelperFreshnessPolicy.staticCodeChanged,
            MiloHelperFreshnessPolicy.requirementFailed
        ]

        // Sweep the Code Signing OSStatus range plus a band around zero, so a future edit
        // that widens the mapping without widening this test fails here.
        for status in Int32(-67_100)...Int32(-67_000) where !recognised.contains(status) {
            #expect(freshness(status).isStale == false)
            #expect(freshness(status) != .current)
        }
        for status in Int32(-8)...Int32(8) where !recognised.contains(status) {
            #expect(freshness(status).isStale == false)
            #expect(freshness(status) != .current)
        }
    }

    @Test("undetermined carries the status so a failure to measure can be diagnosed")
    func undeterminedCarriesStatus() {
        guard case .undetermined(.validationInconclusive(let status)) = freshness(-1) else {
            Issue.record("expected an inconclusive verdict carrying its status")
            return
        }
        #expect(status == -1)
    }

    // MARK: - Presentation

    @Test("every staleness reason states what was measured and stays user-readable")
    func everyReasonIsPresentable() {
        for reason in MiloHelperStalenessReason.allCases {
            #expect(reason.summary.isEmpty == false)
            #expect(reason.explanation.isEmpty == false)
            #expect(reason.rawValue.isEmpty == false)
        }
    }

    @Test("the recovery instruction is the password-free one")
    func recoveryIsPasswordFree() {
        let recovery = MiloHelperFreshnessPolicy.recoveryInstruction

        // The alternative needs root. If this text ever starts telling users to run a
        // command, that is a product regression worth failing a test over.
        #expect(recovery.contains("Settings"))
        #expect(recovery.contains("password"))
        #expect(recovery.contains("sudo") == false)
        #expect(recovery.contains("launchctl") == false)
    }
}
