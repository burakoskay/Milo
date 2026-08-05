import Foundation
import MiloDomain
import Testing

@Suite("Launchd disable eligibility")
struct LaunchdDisablePolicyTests {
    // MARK: - What may be disabled

    @Test("a third-party launch agent may be disabled")
    func thirdPartyAgentIsAllowed() {
        #expect(MiloLaunchdDisablePolicy.canDisable(label: "com.adobe.AdobeUpdater"))
        #expect(MiloLaunchdDisablePolicy.canDisable(label: "com.microsoft.update.agent"))
        #expect(MiloLaunchdDisablePolicy.canDisable(label: "com.dropbox.DropboxMacUpdate.agent"))
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.adobe.AdobeUpdater") == nil)
    }

    // MARK: - Session-critical

    @Test("a session-critical job is refused")
    func sessionCriticalIsRefused() {
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.apple.WindowServer") == .sessionCritical)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.apple.loginwindow") == .sessionCritical)
        // Session-critical outranks Apple-managed: both are true of these labels, and the
        // explanation the user sees must be the more serious one.
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.apple.security.syspolicy") == .sessionCritical)
    }

    // MARK: - Milo's own jobs

    @Test("Milo never offers to disable its own root helper")
    func miloHelperIsRefused() {
        // The row that would reach this is real: the helper runs as root, and a user looking at
        // a process list has every reason to try to stop it. Disabling it here would strand an
        // SMAppService registration Milo still believes it owns.
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.gonggong.milo.helper") == .miloItself)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.monomacaw.milo.helper") == .miloItself)
    }

    @Test("a running Milo's application label is recognised as Milo's own")
    func miloApplicationLabelIsRefused() {
        // launchd gives a running app a label of the form `application.<bundle-id>.<hash>.<hash>`,
        // so a whole-string comparison against the bundle identifier would miss it entirely.
        #expect(
            MiloLaunchdDisablePolicy.refusal(
                forLabel: "application.com.gonggong.milo.preview.104857.104862"
            ) == .miloItself
        )
        #expect(MiloLaunchdDisablePolicy.isMiloOwnedLabel("com.gonggong.milo.preview"))
        #expect(MiloLaunchdDisablePolicy.isMiloOwnedLabel("COM.GONGGONG.MILO.HELPER"))
    }

    @Test("an unrelated vendor sharing Milo's prefix is not treated as Milo")
    func unrelatedVendorIsNotMilo() {
        // The uninstall path was burned by exactly this shape of mistake — a vendor-name match
        // that would have destroyed two unrelated products' preferences. A prefix match here
        // would refuse a third-party job for the wrong reason and hide a real action.
        #expect(!MiloLaunchdDisablePolicy.isMiloOwnedLabel("com.gonggong.milometer"))
        #expect(!MiloLaunchdDisablePolicy.isMiloOwnedLabel("com.monomacaw.picoberry.prototype"))
        #expect(!MiloLaunchdDisablePolicy.isMiloOwnedLabel("com.monomacaw.squeaky.preview"))
        #expect(MiloLaunchdDisablePolicy.canDisable(label: "com.monomacaw.squeaky.preview"))
    }

    // MARK: - Apple's service graph

    @Test("an Apple-managed job is refused, and not as a critical one")
    func appleManagedIsRefused() {
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.apple.tipsd") == .appleManaged)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.apple.Siri.agent") == .appleManaged)
    }

    // MARK: - Well-formedness

    @Test("a label Milo cannot state exactly is refused")
    func malformedLabelsAreRefused() {
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: nil) == .malformedLabel)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "") == .malformedLabel)
        // A slash would be read as a domain separator by whoever builds `system/<label>`.
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "system/com.apple.WindowServer") == .malformedLabel)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.vendor.agent extra") == .malformedLabel)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.vendor.agent\u{0}") == .malformedLabel)
        #expect(MiloLaunchdDisablePolicy.refusal(forLabel: "com.vendor.agent\nbootout") == .malformedLabel)
        #expect(
            MiloLaunchdDisablePolicy.refusal(
                forLabel: String(repeating: "a", count: MiloLaunchdDisablePolicy.maximumLabelLength + 1)
            ) == .malformedLabel
        )
    }

    @Test("a critical label smuggled inside a malformed one is still refused")
    func malformednessDoesNotOpenACriticalLabel() {
        // Well-formedness is checked first, so this is refused as malformed rather than as
        // critical. Either refusal is correct; what must never happen is a verdict of allowed.
        for label in [
            "com.apple.WindowServer ",
            " com.apple.WindowServer",
            "com.apple.WindowServer\t",
            "gui/501/com.apple.WindowServer"
        ] {
            #expect(MiloLaunchdDisablePolicy.refusal(forLabel: label) != nil)
        }
    }

    // MARK: - Every refusal can be explained

    @Test("every refusal carries a non-empty explanation")
    func everyRefusalExplainsItself() {
        // A refusal with no explanation is an undefined UI state: the action disappears and the
        // user is told nothing about why.
        let refusals: [MiloLaunchdDisableRefusal] = [
            .malformedLabel, .sessionCritical, .miloItself, .appleManaged
        ]
        for refusal in refusals {
            #expect(!refusal.explanation.isEmpty)
            #expect(refusal.explanation.count > 20)
        }
    }
}
