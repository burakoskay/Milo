import Foundation

/// Why Milo considers the privileged helper answering it stale.
///
/// Both cases are reported by macOS from the running process's code identity, never inferred
/// from a version string the helper could get wrong or a timestamp that can be preserved by a
/// copy.
public enum MiloHelperStalenessReason: String, Sendable, Hashable, CaseIterable {
    /// The helper binary on disk no longer matches the image the running helper started from.
    /// This is the ordinary reinstall: the new bundle is in place while launchd keeps serving
    /// the process that started from the old one.
    case installedCodeReplaced = "installed-code-replaced"
    /// The running helper's code identity is not the identity of the installed helper binary.
    case differentCodeIdentity = "different-code-identity"

    /// Short label for a status row.
    public var summary: String {
        switch self {
        case .installedCodeReplaced:
            return "Helper is from a previous install"
        case .differentCodeIdentity:
            return "Helper does not match this copy of Milo"
        }
    }

    /// Sentence explaining what Milo measured.
    public var explanation: String {
        switch self {
        case .installedCodeReplaced:
            return "Milo was updated while its background helper kept running. The helper answering "
                + "requests started from the previous version's files, so it is running code this "
                + "copy of Milo did not install."
        case .differentCodeIdentity:
            return "The background helper answering requests is not the helper installed with this "
                + "copy of Milo."
        }
    }
}

/// Why Milo could not decide whether the helper is current.
///
/// Every case is presented as "not determined". Milo never reports a helper as current or as
/// stale on the strength of a measurement it could not make.
public enum MiloHelperFreshnessUnknownReason: Equatable, Sendable {
    /// The helper did not complete a health check, so there is no running helper to inspect.
    /// Helper availability is `MiloHelperStatus`'s question, not this one's.
    case helperNotAnswering
    /// The connection reported no peer process, so there is no process to inspect.
    case peerProcessUnknown
    /// The installed helper binary could not be read to establish what the helper should be.
    case installedHelperUnreadable(status: Int32)
    /// The installed helper binary carries no unique code identity to compare against.
    case installedHelperIdentityMissing
    /// The identity requirement could not be compiled from the installed binary's identity.
    case identityRequirementUnavailable(status: Int32)
    /// The running process's code identity could not be obtained.
    case codeIdentityUnavailable(status: Int32)
    /// Code validation returned a status that is neither success nor a recognised mismatch.
    case validationInconclusive(status: Int32)

    /// Compact, non-identifying detail for the log. Carries no path and no user data.
    public var diagnosticDetail: String {
        switch self {
        case .helperNotAnswering:
            return "helper-not-answering"
        case .peerProcessUnknown:
            return "peer-process-unknown"
        case .installedHelperUnreadable(let status):
            return "installed-helper-unreadable status=\(status)"
        case .installedHelperIdentityMissing:
            return "installed-helper-identity-missing"
        case .identityRequirementUnavailable(let status):
            return "identity-requirement-unavailable status=\(status)"
        case .codeIdentityUnavailable(let status):
            return "code-identity-unavailable status=\(status)"
        case .validationInconclusive(let status):
            return "validation-inconclusive status=\(status)"
        }
    }
}

/// Whether the privileged helper answering Milo is running the code Milo has installed.
public enum MiloHelperFreshness: Equatable, Sendable {
    /// The running helper is the binary installed in this copy of Milo.
    case current
    /// The running helper is not the installed binary.
    case stale(MiloHelperStalenessReason)
    /// Milo could not tell, and says so rather than guessing.
    case undetermined(MiloHelperFreshnessUnknownReason)

    /// True only when Milo positively measured a mismatch.
    public var isStale: Bool {
        if case .stale = self {
            return true
        }
        return false
    }
}

/// Decides helper freshness from a code-validation result.
///
/// This is a **correctness signal, not a security control.** A stale helper is genuinely signed
/// Milo helper code: it satisfies the XPC connection's code-signing requirement exactly as a
/// current helper does, and that requirement remains the security boundary. The question answered
/// here is a different one — *which build* is serving the request.
///
/// It matters because the helper carries its own independent refusal of session-critical
/// executables. A helper that predates that refusal enforces the policy of the build it was
/// compiled from, while the app enforces the policy of the build the user installed.
///
/// The policy is pure so it can be tested without a root process. Gathering the evidence is the
/// inspector's job, mirroring the `MiloProcessSafetyPolicy` / `ProcessSafetyInspector` split.
public enum MiloHelperFreshnessPolicy {
    /// `errSecSuccess`.
    public static let codeValidationSucceeded: Int32 = 0

    /// `errSecCSStaticCodeChanged` — "the code on disk does not match what is running".
    ///
    /// Measured on 2026-08-05 against a running process whose on-disk binary was replaced
    /// underneath it, which is exactly what installing over an existing Milo does.
    public static let staticCodeChanged: Int32 = -67034

    /// `errSecCSReqFailed` — "code failed to satisfy specified code requirement(s)".
    public static let requirementFailed: Int32 = -67050

    /// Maps the result of validating the running helper against the installed binary's identity.
    ///
    /// Unrecognised statuses are deliberately `undetermined` rather than stale: a transient
    /// failure to measure must not become a claim that the user's helper is wrong.
    public static func freshness(forCodeValidationStatus status: Int32) -> MiloHelperFreshness {
        switch status {
        case codeValidationSucceeded:
            return .current
        case staticCodeChanged:
            return .stale(.installedCodeReplaced)
        case requirementFailed:
            return .stale(.differentCodeIdentity)
        default:
            return .undetermined(.validationInconclusive(status: status))
        }
    }

    /// The password-free recovery, which is the same for either staleness reason.
    ///
    /// Restarting the helper otherwise needs root. Toggling the registration makes
    /// `SMAppService` tear down the old process and start the installed binary.
    public static let recoveryInstruction =
        "Turn the background helper off and on again in Settings. macOS then stops the old helper "
        + "and starts the one installed with this copy of Milo. This does not ask for a password."
}
