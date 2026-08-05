import Foundation

/// Why Milo refuses to signal a process.
///
/// Every case is derived from measured evidence — a kernel-reported pid, an effective user
/// id, a code-signature anchor, a launchd label — never from a display name, which any
/// process can choose for itself.
public enum MiloProcessProtectionReason: String, Sendable, Hashable, CaseIterable {
    /// The kernel task or `launchd` itself. Signalling either ends the boot session.
    case kernelOrInit = "kernel-or-init"
    /// A reviewed, explicitly enumerated service whose loss wedges the login session.
    case criticalSystemService = "critical-system-service"
    /// Signed directly by Apple and running as another user: operating-system infrastructure.
    case appleSystemDaemon = "apple-system-daemon"
    /// Signed by Apple and managed by launchd under a `com.apple.` label: part of the
    /// per-user service graph rather than a job the user started.
    case appleManagedAgent = "apple-managed-agent"
    /// Milo, or the privileged helper Milo owns.
    case miloItself = "milo-itself"
    /// An ancestor of Milo. Signalling it takes Milo down with it.
    case miloAncestor = "milo-ancestor"
    /// The user added this process to their protected list.
    case userProtected = "user-protected"

    /// Short label for a process row.
    public var summary: String {
        switch self {
        case .kernelOrInit:
            return "Core system"
        case .criticalSystemService:
            return "Critical service"
        case .appleSystemDaemon:
            return "System daemon"
        case .appleManagedAgent:
            return "Managed by macOS"
        case .miloItself:
            return "Milo"
        case .miloAncestor:
            return "Milo's parent"
        case .userProtected:
            return "Protected by you"
        }
    }

    /// Sentence shown when the user asks why the row has no action.
    public var explanation: String {
        switch self {
        case .kernelOrInit:
            return "This is the kernel or launchd. Stopping it would end the current boot session, so Milo never signals it."
        case .criticalSystemService:
            return "macOS depends on this service for the login session. Stopping it would leave the Mac unusable until restart, so Milo never signals it."
        case .appleSystemDaemon:
            return "This is an Apple-signed system process running under another account. Milo only acts on Apple system processes it ships a reviewed rule for."
        case .appleManagedAgent:
            return "macOS manages this process through launchd. Milo only acts on Apple processes it ships a reviewed rule for, so this row is read-only."
        case .miloItself:
            return "This is Milo or its background helper. Milo will not signal itself."
        case .miloAncestor:
            return "Milo runs inside this process. Stopping it would quit Milo, so this row is read-only."
        case .userProtected:
            return "You added this process to your protected list. Remove it from the list to act on it."
        }
    }
}

/// What Milo is permitted to do with a process.
public enum MiloProcessSafetyClass: Sendable, Hashable {
    /// Matched a shipped catalogue entry or a signed telemetry rule. Behaviour is unchanged
    /// from the reviewed rule path: this is the only route by which Milo signals an
    /// Apple-signed system process.
    case reviewedRule
    /// Runs under the user's own account and is not part of the managed service graph.
    /// The user's uid may already signal it with `kill(1)`; Milo escalates nothing.
    case userOwned
    /// Runs under another account and is not operating-system infrastructure. Requires the
    /// privileged helper and an explicit confirmation.
    case requiresPrivilege
    /// Visible, never actionable.
    case protected(MiloProcessProtectionReason)

    public var isActionable: Bool {
        switch self {
        case .reviewedRule, .userOwned, .requiresPrivilege:
            return true
        case .protected:
            return false
        }
    }

    public var requiresPrivilegedHelper: Bool {
        self == .requiresPrivilege
    }

    public var protectionReason: MiloProcessProtectionReason? {
        guard case .protected(let reason) = self else {
            return nil
        }
        return reason
    }
}

/// Measured facts about one running process.
///
/// The scanner fills this in from `proc_pidinfo`, `proc_pidpath`, the Security framework and
/// launchd. The policy below is a pure function of these facts so that it can be tested
/// exhaustively without a running system.
public struct MiloProcessEvidence: Sendable, Hashable {
    public let pid: Int32
    public let executablePath: String
    public let effectiveUserID: UInt32
    /// The process satisfies the `anchor apple` code requirement — signed by Apple's own
    /// root, as opposed to `anchor apple generic`, which any Developer ID binary satisfies.
    public let isAppleSigned: Bool
    /// The launchd label that owns this pid, when launchd reports one.
    public let launchdLabel: String?
    public let matchesReviewedRule: Bool
    public let isMiloItself: Bool
    public let isMiloAncestor: Bool
    public let isUserProtected: Bool

    public init(
        pid: Int32,
        executablePath: String,
        effectiveUserID: UInt32,
        isAppleSigned: Bool,
        launchdLabel: String? = nil,
        matchesReviewedRule: Bool = false,
        isMiloItself: Bool = false,
        isMiloAncestor: Bool = false,
        isUserProtected: Bool = false
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.effectiveUserID = effectiveUserID
        self.isAppleSigned = isAppleSigned
        self.launchdLabel = launchdLabel
        self.matchesReviewedRule = matchesReviewedRule
        self.isMiloItself = isMiloItself
        self.isMiloAncestor = isMiloAncestor
        self.isUserProtected = isUserProtected
    }
}

/// The rule that decides what Milo may signal.
///
/// The problem this solves: Milo used to be blind to any process outside its shipped
/// catalogue, so a background job the user started themselves — the canonical example being
/// `sleep 600 &` — was neither listed nor actionable. Widening the catalogue is the wrong
/// fix; it would eventually swallow the operating system.
///
/// Instead, visibility and actionability are separated. Everything is visible. Actionability
/// is decided by evidence, and the load-bearing invariant is narrow enough to state in one
/// sentence:
///
/// > Milo signals an Apple-signed process only when a reviewed rule names it, and never
/// > signals a reviewed-rule-exempt process through the root helper.
///
/// A process running under the user's own account that launchd does not manage is not
/// operating-system infrastructure by any available measure, and the user's uid can already
/// signal it without Milo. Refusing to act on those would be theatre, not safety.
public enum MiloProcessSafetyPolicy {
    /// Roots that live on the sealed, read-only system volume. A binary here was placed by
    /// Apple's installer and is covered by the volume's cryptographic seal.
    public static let sealedSystemRoots: [String] = [
        "/System/",
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/libexec/",
        "/usr/lib/"
    ]

    /// Writable paths that must never be treated as sealed even though a prefix comparison
    /// might one day be widened to reach them.
    public static let writableSystemExceptions: [String] = [
        "/usr/local/"
    ]

    /// Services whose loss wedges the login session until restart.
    ///
    /// This list is deliberately short, absolute-path keyed, and reviewed. It is a second
    /// gate, not the primary one: every entry is also an Apple-signed system binary and
    /// would be protected on that basis alone. It exists so that the guarantee survives a
    /// future catalogue mistake, and so the root helper can enforce it without needing to
    /// know the catalogue.
    public static let criticalExecutablePaths: Set<String> = [
        "/sbin/launchd",
        "/usr/libexec/launchd",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
        "/usr/libexec/opendirectoryd",
        "/usr/libexec/configd",
        "/usr/libexec/diskarbitrationd",
        "/usr/libexec/syspolicyd",
        "/usr/libexec/amfid",
        "/usr/libexec/trustd",
        "/usr/libexec/secinitd",
        "/usr/libexec/kernelmanagerd",
        "/usr/sbin/notifyd",
        "/usr/sbin/distnoted",
        "/usr/sbin/securityd",
        "/usr/sbin/cfprefsd"
    ]

    /// The launchd labels that own the executables in `criticalExecutablePaths`.
    ///
    /// This list exists because the two privileged verbs carry different evidence. A kill
    /// request carries an absolute executable path, so the helper gates it with
    /// `isCriticalSystemExecutable`. A `launchctl disable` or `bootout` request carries only a
    /// *label* — there is no path to check — so that gate cannot reach it, and without this
    /// list the helper's launchctl grammar would accept `disable system/com.apple.WindowServer`
    /// on nothing but a character-set check.
    ///
    /// Every entry was read from the `Label` key of the `LaunchDaemons`/`LaunchAgents` plist
    /// whose `Program` or `ProgramArguments[0]` is the corresponding critical path, on macOS
    /// 27.0. They are **not** derivable from the executable name: `syspolicyd` is owned by
    /// `com.apple.security.syspolicy` and `amfid` by `com.apple.MobileFileIntegrity`. Do not
    /// extend this list by pattern; re-read the plists.
    ///
    /// `launchd` itself has no label — it is pid 1 and is refused by pid, not by name.
    public static let criticalLaunchdLabels: Set<String> = [
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.opendirectoryd",
        "com.apple.configd",
        "com.apple.diskarbitrationd",
        "com.apple.security.syspolicy",
        "com.apple.MobileFileIntegrity",
        "com.apple.trustd",
        "com.apple.trustd.agent",
        "com.apple.secinitd",
        "com.apple.kernelmanagerd",
        "com.apple.notifyd",
        "com.apple.distnoted.xpc.daemon",
        "com.apple.distnoted.xpc.agent",
        "com.apple.securityd",
        "com.apple.cfprefsd.xpc.daemon",
        "com.apple.cfprefsd.xpc.agent"
    ]

    /// Prefix of every launchd label that belongs to Apple's own service graph.
    ///
    /// Note that a running application carries a label of the form
    /// `application.<bundle-id>.<hash>.<hash>`, which deliberately does not match: an app the
    /// user opened is not infrastructure.
    public static let appleLaunchdLabelPrefix = "com.apple."

    /// Whether the executable lives on the sealed, read-only system volume.
    public static func isOnSealedSystemVolume(_ path: String) -> Bool {
        let standardized = standardizedPath(path)
        guard !writableSystemExceptions.contains(where: { standardized.hasPrefix($0) }) else {
            return false
        }
        return sealedSystemRoots.contains { standardized.hasPrefix($0) }
    }

    /// Whether the executable is one whose loss wedges the login session.
    public static func isCriticalSystemExecutable(_ path: String) -> Bool {
        criticalExecutablePaths.contains(standardizedPath(path))
    }

    /// Whether disabling or booting out this launchd label would wedge the login session.
    ///
    /// The comparison is case-insensitive. `launchctl` itself matches labels exactly, so a
    /// differently-cased label would not in fact stop the service — but a refusal list that
    /// can be stepped around by changing one character is not a refusal list, and being
    /// stricter than `launchctl` costs nothing here.
    public static func isCriticalLaunchdLabel(_ label: String?) -> Bool {
        guard let label else {
            return false
        }
        let normalized = label.lowercased()
        return criticalLaunchdLabels.contains { $0.lowercased() == normalized }
    }

    /// Whether the launchd label belongs to Apple's own service graph rather than to an
    /// application the user opened.
    public static func isAppleManagedLaunchdLabel(_ label: String?) -> Bool {
        guard let label else {
            return false
        }
        return label.hasPrefix(appleLaunchdLabelPrefix)
    }

    /// Classifies one process. Pure; the order of the checks is the policy.
    public static func classify(
        _ evidence: MiloProcessEvidence,
        currentUserID: UInt32
    ) -> MiloProcessSafetyClass {
        // The kernel task (0) and launchd (1) are never candidates, whatever else is true.
        guard evidence.pid > 1 else {
            return .protected(.kernelOrInit)
        }

        // Deliberately ahead of the reviewed-rule check: a catalogue entry must never be
        // able to name a session-critical service into being actionable.
        if isCriticalSystemExecutable(evidence.executablePath) {
            return .protected(.criticalSystemService)
        }

        if evidence.isMiloItself {
            return .protected(.miloItself)
        }

        if evidence.isMiloAncestor {
            return .protected(.miloAncestor)
        }

        if evidence.isUserProtected {
            return .protected(.userProtected)
        }

        // The only route by which Milo acts on Apple-signed system software.
        if evidence.matchesReviewedRule {
            return .reviewedRule
        }

        let isOperatingSystemBinary = evidence.isAppleSigned
            || isOnSealedSystemVolume(evidence.executablePath)

        guard evidence.effectiveUserID == currentUserID else {
            // Another account. Apple's own daemons are off limits without a reviewed rule;
            // anything else needs the privileged helper and an explicit confirmation.
            return isOperatingSystemBinary ? .protected(.appleSystemDaemon) : .requiresPrivilege
        }

        // The user's own account. An Apple binary that launchd manages under a `com.apple.`
        // label is part of the session's service graph, so it stays read-only. An Apple
        // binary with no such label is a job the user started — `/bin/sleep`, `/usr/bin/python3`,
        // a shell script — and the user's uid can already signal it.
        if isOperatingSystemBinary, isAppleManagedLaunchdLabel(evidence.launchdLabel) {
            return .protected(.appleManagedAgent)
        }

        return .userOwned
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
