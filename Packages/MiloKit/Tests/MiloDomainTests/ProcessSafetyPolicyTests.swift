import Foundation
import MiloDomain
import Testing

@Suite("Process safety classification")
struct ProcessSafetyPolicyTests {
    private let currentUser: UInt32 = 501
    private let otherUser: UInt32 = 0

    private func evidence(
        pid: Int32 = 4_242,
        path: String = "/opt/homebrew/bin/node",
        uid: UInt32 = 501,
        appleSigned: Bool = false,
        label: String? = nil,
        reviewedRule: Bool = false,
        miloItself: Bool = false,
        miloAncestor: Bool = false,
        userProtected: Bool = false
    ) -> MiloProcessEvidence {
        MiloProcessEvidence(
            pid: pid,
            executablePath: path,
            effectiveUserID: uid,
            isAppleSigned: appleSigned,
            launchdLabel: label,
            matchesReviewedRule: reviewedRule,
            isMiloItself: miloItself,
            isMiloAncestor: miloAncestor,
            isUserProtected: userProtected
        )
    }

    private func classify(_ evidence: MiloProcessEvidence) -> MiloProcessSafetyClass {
        MiloProcessSafetyPolicy.classify(evidence, currentUserID: currentUser)
    }

    // MARK: - The case that motivated discovery

    @Test("a shell job the user started is actionable without privilege")
    func userStartedShellJobIsActionable() {
        // `sleep 600 &`. /bin/sleep is Apple-signed and sits on the sealed system volume, so
        // a naive "Apple binary is untouchable" rule would hide it forever — which is exactly
        // the failure the 0.2.0-preview.2 checkpoint recorded.
        let job = evidence(path: "/bin/sleep", appleSigned: true, label: nil)
        #expect(classify(job) == .userOwned)
        #expect(classify(job).isActionable)
        #expect(!classify(job).requiresPrivilegedHelper)
    }

    @Test("an interpreter run from the user's shell is actionable")
    func userStartedInterpreterIsActionable() {
        #expect(classify(evidence(path: "/usr/bin/python3", appleSigned: true)) == .userOwned)
        #expect(classify(evidence(path: "/opt/homebrew/bin/node")) == .userOwned)
    }

    @Test("an application the user opened is not treated as infrastructure")
    func runningApplicationLabelIsNotInfrastructure() {
        // launchd labels a running app `application.<bundle-id>.<hash>.<hash>`, which must not
        // be mistaken for Apple's own service graph.
        let application = evidence(
            path: "/Applications/Safari.app/Contents/MacOS/Safari",
            appleSigned: true,
            label: "application.com.apple.Safari.1803361.1804027"
        )
        #expect(classify(application) == .userOwned)
    }

    // MARK: - The operating system stays intact

    @Test("the kernel task and launchd are never actionable")
    func kernelAndInitAreProtected() {
        #expect(classify(evidence(pid: 0, path: "")) == .protected(.kernelOrInit))
        #expect(classify(evidence(pid: 1, path: "/sbin/launchd", uid: otherUser)) == .protected(.kernelOrInit))
    }

    @Test("a reviewed rule cannot make a session-critical service actionable")
    func criticalServicesOutrankReviewedRules() {
        for path in MiloProcessSafetyPolicy.criticalExecutablePaths {
            let named = evidence(path: path, uid: otherUser, appleSigned: true, reviewedRule: true)
            #expect(
                classify(named) == .protected(.criticalSystemService),
                "\(path) must stay protected even when a catalogue entry names it"
            )
        }
    }

    @Test("WindowServer and loginwindow are protected under any account")
    func sessionCriticalProcessesAreProtected() {
        let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
        let loginWindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        #expect(classify(evidence(path: windowServer, uid: otherUser, appleSigned: true)) == .protected(.criticalSystemService))
        // loginwindow runs as the logged-in user, so the uid branch alone would not catch it.
        #expect(classify(evidence(path: loginWindow, uid: currentUser, appleSigned: true)) == .protected(.criticalSystemService))
    }

    @Test("Apple daemons under another account are read-only without a reviewed rule")
    func appleSystemDaemonsAreProtected() {
        let daemon = evidence(path: "/usr/libexec/nsurlsessiond", uid: otherUser, appleSigned: true)
        #expect(classify(daemon) == .protected(.appleSystemDaemon))

        let reviewed = evidence(path: "/usr/libexec/nsurlsessiond", uid: otherUser, appleSigned: true, reviewedRule: true)
        #expect(classify(reviewed) == .reviewedRule)
    }

    @Test("Apple agents in the user's own service graph are read-only")
    func appleManagedAgentsAreProtected() {
        let agent = evidence(
            path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            appleSigned: true,
            label: "com.apple.Finder"
        )
        #expect(classify(agent) == .protected(.appleManagedAgent))
    }

    @Test("an unsigned binary on the sealed volume is still treated as system software")
    func sealedVolumePathSurvivesSignatureFailure() {
        // Belt and braces: if the signature query fails, the path alone must still protect
        // an operating-system daemon running under another account.
        let daemon = evidence(path: "/usr/libexec/somethingd", uid: otherUser, appleSigned: false)
        #expect(classify(daemon) == .protected(.appleSystemDaemon))
    }

    @Test("third-party root daemons require the privileged helper")
    func thirdPartyRootDaemonsRequirePrivilege() {
        let daemon = evidence(path: "/Library/Application Support/Adobe/adobedaemon", uid: otherUser)
        #expect(classify(daemon) == .requiresPrivilege)
        #expect(classify(daemon).requiresPrivilegedHelper)
    }

    @Test("third-party agents in the user's own account stay user-level")
    func thirdPartyUserAgentsAreUserOwned() {
        let agent = evidence(
            path: "/Applications/Dropbox.app/Contents/MacOS/Dropbox",
            label: "com.dropbox.DropboxMacUpdate.agent"
        )
        #expect(classify(agent) == .userOwned)
    }

    // MARK: - Milo does not shoot itself

    @Test("Milo and its ancestors are never actionable")
    func miloProtectsItself() {
        #expect(classify(evidence(miloItself: true)) == .protected(.miloItself))
        #expect(classify(evidence(miloAncestor: true)) == .protected(.miloAncestor))
    }

    @Test("self-protection outranks a reviewed rule")
    func selfProtectionOutranksReviewedRule() {
        #expect(classify(evidence(reviewedRule: true, miloItself: true)) == .protected(.miloItself))
        #expect(classify(evidence(reviewedRule: true, miloAncestor: true)) == .protected(.miloAncestor))
    }

    @Test("the user's protected list outranks a reviewed rule")
    func userProtectionOutranksReviewedRule() {
        #expect(classify(evidence(reviewedRule: true, userProtected: true)) == .protected(.userProtected))
    }

    // MARK: - Path predicates

    @Test("sealed roots are recognised and /usr/local is excluded")
    func sealedVolumeDetection() {
        #expect(MiloProcessSafetyPolicy.isOnSealedSystemVolume("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))
        #expect(MiloProcessSafetyPolicy.isOnSealedSystemVolume("/bin/sleep"))
        #expect(MiloProcessSafetyPolicy.isOnSealedSystemVolume("/usr/libexec/trustd"))
        #expect(!MiloProcessSafetyPolicy.isOnSealedSystemVolume("/usr/local/bin/anything"))
        #expect(!MiloProcessSafetyPolicy.isOnSealedSystemVolume("/opt/homebrew/bin/node"))
        #expect(!MiloProcessSafetyPolicy.isOnSealedSystemVolume("/Applications/Milo.app/Contents/MacOS/Milo"))
    }

    @Test("path traversal cannot disguise a critical service")
    func traversalIsStandardizedBeforeComparison() {
        #expect(MiloProcessSafetyPolicy.isCriticalSystemExecutable("/usr/libexec/../libexec/opendirectoryd"))
        #expect(MiloProcessSafetyPolicy.isOnSealedSystemVolume("/System/Library/../Library/CoreServices/x"))
    }

    @Test("only Apple's own launchd label prefix counts as managed")
    func appleLabelPrefix() {
        #expect(MiloProcessSafetyPolicy.isAppleManagedLaunchdLabel("com.apple.cloudd"))
        #expect(!MiloProcessSafetyPolicy.isAppleManagedLaunchdLabel("application.com.apple.Safari.1.2"))
        #expect(!MiloProcessSafetyPolicy.isAppleManagedLaunchdLabel("com.dropbox.agent"))
        #expect(!MiloProcessSafetyPolicy.isAppleManagedLaunchdLabel(nil))
    }

    // MARK: - Invariant

    @Test("the root helper is never asked to signal Apple system software")
    func privilegedPathNeverTargetsAppleBinaries() {
        // The single sentence the whole policy exists to guarantee. Exhaustive over the
        // evidence dimensions that can produce a privileged classification.
        for appleSigned in [true, false] {
            for sealed in [true, false] {
                for label in [nil, "com.apple.something", "com.vendor.agent"] as [String?] {
                    let candidate = MiloProcessEvidence(
                        pid: 900,
                        executablePath: sealed ? "/usr/libexec/vendord" : "/Library/Vendor/vendord",
                        effectiveUserID: otherUser,
                        isAppleSigned: appleSigned,
                        launchdLabel: label
                    )
                    let classification = classify(candidate)
                    if classification.requiresPrivilegedHelper {
                        #expect(!appleSigned)
                        #expect(!sealed)
                    }
                }
            }
        }
    }
}
