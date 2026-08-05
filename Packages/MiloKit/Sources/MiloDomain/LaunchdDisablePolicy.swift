import Foundation

/// Why Milo will not offer to disable a launchd job.
public enum MiloLaunchdDisableRefusal: String, Equatable, Sendable {
    /// The label is empty, over-long, or contains characters a launchd label cannot hold.
    /// A label Milo cannot state exactly is one it must not act on.
    case malformedLabel

    /// Disabling it would wedge the login session. See `criticalLaunchdLabels`.
    case sessionCritical

    /// One of Milo's own jobs, including its root helper. Milo removes its own launchd
    /// registrations through Settings › Uninstall, which unregisters before deleting; letting
    /// a process row disable the helper instead would strand a registration Milo still
    /// believes it owns.
    case miloItself

    /// Part of Apple's own service graph. Milo acts on Apple software only where a reviewed
    /// rule names it, and those travel through System Tuning with their own revert step —
    /// not through a row the user happened to terminate.
    case appleManaged

    /// A human-readable explanation, shown in place of the action.
    public var explanation: String {
        switch self {
        case .malformedLabel:
            return "Milo could not read a valid launch item name for this process, so it will not "
                + "guess at one."
        case .sessionCritical:
            return "This launch item is part of the login session. Disabling it would leave the "
                + "Mac unusable until it restarts, so Milo never offers to."
        case .miloItself:
            return "This is one of Milo's own launch items. Use Settings › Uninstall to remove "
                + "Milo cleanly, which unregisters the background helper first."
        case .appleManaged:
            return "macOS manages this launch item. Milo only changes Apple's own services "
                + "through the reviewed actions in System Tuning, which can be reverted."
        }
    }
}

/// Whether a respawning launchd job may be offered for disabling, and why not when it may not.
///
/// This exists because "the process came back" is the single most common thing a user wants
/// fixed, and terminating it again is not the fix — the fix is disabling the job. That makes it
/// an action on macOS configuration rather than on a process, and it outlives the click, so the
/// question of *which* jobs may be offered is a safety question rather than a UI one.
///
/// The policy is pure so the answer is the same whichever surface asks, and so the refusals can
/// be tested without a launchd to disable.
public enum MiloLaunchdDisablePolicy {
    /// The longest label the policy will consider well-formed. `launchctl` itself is more
    /// permissive; this bound exists so an absurd label cannot be rendered into UI or an argv.
    public static let maximumLabelLength = 256

    /// Characters a well-formed launchd label may contain. Deliberately narrower than what
    /// launchd accepts: every label Milo needs to act on is a reverse-DNS identifier, and a
    /// label carrying a slash could otherwise be read as a domain separator by the caller that
    /// builds `system/<label>`.
    private static let allowedLabelCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    /// Every launchd label Milo may own, current and retired. A running Milo also carries a
    /// label of the form `application.<bundle-id>.<hash>.<hash>`, which is why the bundle
    /// identifiers are matched as a component rather than compared whole.
    private static var miloOwnedIdentifiers: [String] {
        MiloUninstallPlan.currentIdentifiers
            + MiloUninstallPlan.legacyIdentifiers
            + [MiloUninstallPlan.helperServiceIdentifier]
            + MiloUninstallPlan.legacyHelperServiceIdentifiers
    }

    /// Whether Milo may offer to disable this launchd job.
    ///
    /// Returns `nil` when the job may be offered, and the reason otherwise. The order of the
    /// checks is the policy: well-formedness first because nothing else can be decided about a
    /// label that cannot be read, then session-critical, which outranks every other reason.
    public static func refusal(forLabel label: String?) -> MiloLaunchdDisableRefusal? {
        guard let label, isWellFormedLabel(label) else {
            return .malformedLabel
        }

        if MiloProcessSafetyPolicy.isCriticalLaunchdLabel(label) {
            return .sessionCritical
        }

        if isMiloOwnedLabel(label) {
            return .miloItself
        }

        if MiloProcessSafetyPolicy.isAppleManagedLaunchdLabel(label) {
            return .appleManaged
        }

        return nil
    }

    /// Convenience for the call sites that only need the verdict.
    public static func canDisable(label: String?) -> Bool {
        refusal(forLabel: label) == nil
    }

    /// Whether the label is one Milo can state exactly and pass as a single argv component.
    public static func isWellFormedLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maximumLabelLength else {
            return false
        }
        return label.unicodeScalars.allSatisfy(allowedLabelCharacters.contains)
    }

    /// Whether the label belongs to Milo itself, including a running Milo's
    /// `application.<bundle-id>.…` label and any pre-rename identifier.
    public static func isMiloOwnedLabel(_ label: String) -> Bool {
        let normalized = label.lowercased()
        return miloOwnedIdentifiers.contains { identifier in
            let candidate = identifier.lowercased()
            guard normalized != candidate else {
                return true
            }
            // A component match, so `com.gonggong.milo` does not match an unrelated vendor's
            // `com.gonggong.milometer` while still matching `application.com.gonggong.milo.1.2`.
            return normalized.hasPrefix(candidate + ".")
                || normalized.hasSuffix("." + candidate)
                || normalized.contains("." + candidate + ".")
        }
    }
}
