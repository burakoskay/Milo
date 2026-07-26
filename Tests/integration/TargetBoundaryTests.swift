import Foundation
import XCTest

final class TargetBoundaryTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLiteTargetHasNoProDependenciesOrNetworkEntitlement() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))
        let liteSection = try section(
            named: "MiloLite",
            before: "MiloPrivilegedHelper",
            in: projectSpec
        )

        XCTAssertTrue(liteSection.contains("ENABLE_APP_SANDBOX: YES"))
        XCTAssertTrue(liteSection.contains("PRODUCT_BUNDLE_IDENTIFIER: $(MILO_BUNDLE_ID)"))
        let liteConfiguration = try readText(
            at: repositoryRoot.appendingPathComponent("Configurations/MiloLite.Release.xcconfig")
        )
        XCTAssertTrue(liteConfiguration.contains("MILO_BUNDLE_ID = com.monomacaw.milo.lite"))
        XCTAssertFalse(liteSection.contains("MiloLicense"))
        XCTAssertFalse(liteSection.contains("MiloSparkle"))
        XCTAssertFalse(liteSection.contains("MiloPrivilegedHelper"))

        let entitlements = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent("App/MiloLite/MiloLite.entitlements")
        )
        XCTAssertEqual(entitlements.keys.sorted(), ["com.apple.security.app-sandbox"])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
    }

    func testHelperBundleLayoutAndAuthenticatedPolicyAreFrozen() throws {
        let helperPlist = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent(
                "Helper/MiloPrivilegedHelper/com.monomacaw.milo.helper.plist"
            )
        )

        XCTAssertEqual(helperPlist["Label"] as? String, "com.monomacaw.milo.helper")
        XCTAssertEqual(
            helperPlist["BundleProgram"] as? String,
            "Contents/Resources/MiloPrivilegedHelper"
        )
        guard let machServices = helperPlist["MachServices"] as? [String: Any] else {
            XCTFail("MachServices must be a dictionary")
            return
        }
        XCTAssertEqual(machServices["com.monomacaw.milo.helper"] as? Bool, true)
        XCTAssertNil(helperPlist["Program"])
        XCTAssertNil(helperPlist["ProgramArguments"])
        XCTAssertNil(helperPlist["RunAtLoad"])

        let helperSource = try readText(
            at: repositoryRoot.appendingPathComponent("Helper/MiloPrivilegedHelper/main.swift")
        )
        XCTAssertTrue(helperSource.contains("setCodeSigningRequirement"))
        XCTAssertTrue(helperSource.contains("certificate leaf[subject.OU]"))
        XCTAssertTrue(helperSource.contains("HelperPolicy.decode"))
        XCTAssertTrue(helperSource.contains("expectedProcessIdentity"))
        XCTAssertTrue(helperSource.contains("processIdentityStatus"))
        XCTAssertTrue(helperSource.contains("MiloSubprocessRunner.run"))
        XCTAssertFalse(helperSource.contains("Process("))
        XCTAssertFalse(helperSource.contains("/bin/sh"))
        XCTAssertFalse(helperSource.contains("NSAppleScript"))

        let privilegeManager = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/PrivilegeManager.swift")
        )
        XCTAssertTrue(privilegeManager.contains("SMAppService.daemon"))
        XCTAssertFalse(privilegeManager.contains("administrator privileges"))
    }

    func testDevelopmentPreviewIsExplicitAndBackendIndependentAtRuntime() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))
        let previewConfiguration = try readText(
            at: repositoryRoot.appendingPathComponent("Configurations/MiloPro.Preview.xcconfig")
        )
        let previewEntitlements = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent("App/Milo/MiloPreview.entitlements")
        )
        let licenseManager = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/LicenseManager.swift")
        )

        XCTAssertTrue(projectSpec.contains("Preview: release"))
        XCTAssertTrue(projectSpec.contains("MILO_DEVELOPMENT_PREVIEW"))
        XCTAssertTrue(previewConfiguration.contains("com.monomacaw.milo.preview"))
        XCTAssertTrue(previewConfiguration.contains("MILO_CONFIGURATION_ENVIRONMENT = development-preview"))
        XCTAssertTrue(previewEntitlements.isEmpty)
        XCTAssertTrue(licenseManager.contains("MiloBuildMode.isDevelopmentPreview"))
        XCTAssertTrue(licenseManager.contains("expiresAt: .distantFuture"))
    }

    func testPrivilegedExecutionHasNoPromptOrSudoFallback() throws {
        let commandRunner = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/CommandRunner.swift")
        )
        let processManager = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/ProcessManager.swift")
        )
        let helperClient = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/PrivilegedHelperClient.swift")
        )

        XCTAssertTrue(commandRunner.contains("MiloPrivilegedHelperClient.shared"))
        XCTAssertFalse(commandRunner.contains("NSAppleScript"))
        XCTAssertFalse(commandRunner.contains("with administrator privileges"))
        XCTAssertTrue(processManager.contains("processIdentityStatus"))
        XCTAssertTrue(processManager.contains("matchedIdentities"))
        XCTAssertTrue(helperClient.contains("expectedStartSeconds"))
        XCTAssertTrue(helperClient.contains("expectedStartMicroseconds"))
    }

    func testProSchemeLaunchesAppAndEmbedsHelperOnlyAsDependency() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))
        let proTargetSection = try section(named: "MiloPro", before: "MiloLite", in: projectSpec)

        XCTAssertTrue(proTargetSection.contains("target: MiloPrivilegedHelper"))
        XCTAssertTrue(proTargetSection.contains("destination: resources"))
        XCTAssertTrue(proTargetSection.contains("Contents/Library/LaunchDaemons"))

        let scheme = try readText(
            at: repositoryRoot.appendingPathComponent(
                "Milo.xcodeproj/xcshareddata/xcschemes/MiloPro.xcscheme"
            )
        )
        let launchAction = try contents(between: "<LaunchAction", and: "</LaunchAction>", in: scheme)
        let profileAction = try contents(between: "<ProfileAction", and: "</ProfileAction>", in: scheme)

        XCTAssertTrue(launchAction.contains("BuildableName = \"Milo.app\""))
        XCTAssertTrue(launchAction.contains("BlueprintName = \"MiloPro\""))
        XCTAssertFalse(launchAction.contains("MiloPrivilegedHelper"))
        XCTAssertTrue(profileAction.contains("BuildableName = \"Milo.app\""))
        XCTAssertFalse(profileAction.contains("MiloPrivilegedHelper"))
    }

    func testReleaseConfigurationRejectsCompilerWarningsAndDebugEntitlementInjection() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))

        XCTAssertTrue(projectSpec.contains("GCC_TREAT_WARNINGS_AS_ERRORS: YES"))
        let releaseSection = try contents(
            between: "    Release:\n",
            and: "\ntargets:\n",
            in: projectSpec
        )
        XCTAssertTrue(releaseSection.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO"))
        XCTAssertTrue(releaseSection.contains("VALIDATE_PRODUCT: YES"))
    }

    func testLitePrivacyManifestDeclaresNoCollectionOrTracking() throws {
        let manifest = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent("App/MiloLite/PrivacyInfo.xcprivacy")
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertTrue((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        XCTAssertTrue((manifest["NSPrivacyAccessedAPITypes"] as? [Any])?.isEmpty == true)
    }

    func testGeneratedProjectPreservesCanonicalResourceFilenameCase() throws {
        let resourcesDirectory = repositoryRoot.appendingPathComponent("Milo/Resources")
        let resourceNames = try FileManager.default.contentsOfDirectory(atPath: resourcesDirectory.path)
        XCTAssertTrue(resourceNames.contains("Milo_black.png"))
        XCTAssertFalse(resourceNames.contains("milo_black.png"))

        let generatedProject = try readText(
            at: repositoryRoot.appendingPathComponent("Milo.xcodeproj/project.pbxproj")
        )
        XCTAssertTrue(generatedProject.contains("Milo_black.png"))
        XCTAssertFalse(generatedProject.contains("milo_black.png"))
    }

    func testProcessScanCannotPublishFailureAsCleanOrOverwriteNewerResults() throws {
        let appState = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/AppState.swift")
        )
        let processManager = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/ProcessManager.swift")
        )
        let contentView = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/ContentView.swift")
        )
        let dedicatedView = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/DedicatedWindowView.swift")
        )

        XCTAssertTrue(appState.contains("MiloOperationLifecycle<ProcessScanSnapshot>"))
        XCTAssertTrue(appState.contains("scanWorker?.cancel()"))
        XCTAssertTrue(appState.contains("scanLifecycle.succeed(snapshot, for: context)"))
        XCTAssertTrue(appState.contains("scanLifecycle.fail(failure, for: context)"))
        XCTAssertTrue(processManager.contains("scanForRunningTargetsWithResources() throws"))
        XCTAssertTrue(contentView.contains("appState.scanFailureMessage"))
        XCTAssertTrue(contentView.contains("appState.scanResultIsClean"))
        XCTAssertTrue(dedicatedView.contains("appState.scanFailureMessage"))
        XCTAssertTrue(dedicatedView.contains("appState.scanResultIsClean"))
    }

    func testProcessScanningReceivesCloudRulesByInjection() throws {
        let processManager = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/ProcessManager.swift")
        )

        XCTAssertTrue(processManager.contains("init(cloudSignatureManager: CloudSignatureManager = .shared)"))
        XCTAssertTrue(processManager.contains("cloudSignatureManager.hasCloudLocatorCandidate"))
        XCTAssertTrue(processManager.contains("cloudSignatureManager.matchCloudSignature"))
        XCTAssertFalse(processManager.contains("CloudSignatureManager.shared.hasCloudLocatorCandidate"))
        XCTAssertFalse(processManager.contains("CloudSignatureManager.shared.matchCloudSignature"))
    }

    func testCommandOutputIsBoundedAcrossEveryExecutionPath() throws {
        let commandRunner = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/CommandRunner.swift")
        )
        let subprocessRunner = try readText(
            at: repositoryRoot.appendingPathComponent(
                "Packages/MiloKit/Sources/MiloDomain/SubprocessRunner.swift"
            )
        )
        let selfTestRunner = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/SelfTestRunner.swift")
        )

        XCTAssertTrue(commandRunner.contains("MiloBoundedCommandOutput"))
        XCTAssertTrue(commandRunner.contains("maximumOutputBytes: Int = defaultMaximumOutputBytes"))
        XCTAssertTrue(commandRunner.contains("maximumOutputBytes <= defaultMaximumOutputBytes"))
        XCTAssertTrue(commandRunner.contains("MiloSubprocessRunner.run"))
        XCTAssertTrue(commandRunner.contains("deadline: Duration = defaultDeadline"))
        XCTAssertTrue(commandRunner.contains("Task<Never, Never>.isCancelled"))
        XCTAssertTrue(commandRunner.contains("case outputLimitExceeded"))
        XCTAssertTrue(commandRunner.contains("output.wasTruncated ? 74 : status"))
        XCTAssertFalse(commandRunner.contains("waitUntilExit()"))
        XCTAssertFalse(commandRunner.contains("let task = Process()"))
        XCTAssertFalse(commandRunner.contains("private var storage = Data()"))
        XCTAssertTrue(subprocessRunner.contains("POSIX_SPAWN_SETPGROUP"))
        XCTAssertTrue(subprocessRunner.contains("POSIX_SPAWN_CLOEXEC_DEFAULT"))
        XCTAssertTrue(subprocessRunner.contains("terminateProcessGroup"))
        XCTAssertTrue(subprocessRunner.contains("case timedOut"))
        XCTAssertTrue(subprocessRunner.contains("case cancelled"))
        XCTAssertTrue(selfTestRunner.contains("MiloSubprocessRunner.run"))
        XCTAssertTrue(selfTestRunner.contains("handle.task.cancel()"))
        XCTAssertFalse(selfTestRunner.contains("Process()"))
    }

    func testOnlyOnePresentationSurfaceCanOwnASwiftUIHost() throws {
        let appDelegate = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/MenuBarAppDelegate.swift")
        )

        // Both root views bind alerts to the same AppState flags. Two live hosting controllers
        // would each present the same confirmation, forcing the inactive surface's window on
        // screen at an unpositioned frame. Tearing down the host is the only defence.
        XCTAssertTrue(appDelegate.contains("private var activeSurface: MiloSurface?"))
        XCTAssertTrue(appDelegate.contains("private func tearDownSurface(_ surface: MiloSurface)"))
        XCTAssertTrue(appDelegate.contains("panel?.contentViewController = nil"))
        XCTAssertTrue(appDelegate.contains("dedicatedWindow?.contentViewController = nil"))

        // The hosting controllers must be built on demand, never eagerly in `init`, or the
        // menu bar host would stay alive while the dedicated window is the active surface.
        let initializer = try contents(
            between: "override init() {",
            and: "func applicationDidFinishLaunching",
            in: appDelegate
        )
        XCTAssertFalse(initializer.contains("NSHostingController"))
    }

    func testViewModeChangesDoNotReactToUnrelatedDefaultsWrites() throws {
        let appDelegate = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/MenuBarAppDelegate.swift")
        )

        // `UserDefaults.didChangeNotification` fires for window frame autosaves and status item
        // positions too. Acting on it unconditionally resurrects surfaces the user dismissed.
        XCTAssertTrue(appDelegate.contains("guard let current = activeSurface, current != desired else { return }"))
        XCTAssertTrue(appDelegate.contains("guard mode != appliedAppearance else { return }"))
    }

    func testQuitConfirmationReturnsTheUsersDecisionToAppKit() throws {
        let appDelegate = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/MenuBarAppDelegate.swift")
        )

        // Once applicationShouldTerminate returns .terminateCancel, a later deferred reply is
        // a no-op and the user's "Quit" choice is silently discarded.
        XCTAssertFalse(appDelegate.contains("reply(toApplicationShouldTerminate: "))
        XCTAssertTrue(appDelegate.contains("private func runQuitConfirmation() -> QuitDecision"))
        XCTAssertTrue(appDelegate.contains("case .quit:\n                return .terminateNow"))

        // Closing the dedicated window hides Milo to the menu bar; it must not run the
        // termination flow from a delegate callback that cannot report a decision.
        XCTAssertTrue(appDelegate.contains("appDelegate.hideDedicatedWindow()"))
    }

    func testBothSurfacesHandleEverySharedNotification() throws {
        let contentView = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/ContentView.swift")
        )
        let dedicatedView = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/DedicatedWindowView.swift")
        )

        for notification in [
            ".miloOpenSettings",
            ".miloSurfaceDidOpen",
            ".miloSurfaceDidClose",
            ".miloSurfaceDidActivate",
            ".miloRequestCurrentBloatCount",
            ".miloCloudSignaturesChanged"
        ] {
            XCTAssertTrue(
                contentView.contains("publisher(for: \(notification))"),
                "ContentView must handle \(notification)"
            )
            XCTAssertTrue(
                dedicatedView.contains("publisher(for: \(notification))"),
                "DedicatedWindowView must handle \(notification)"
            )
        }

        // Stringly-typed names silently stop matching when one call site is renamed.
        XCTAssertFalse(contentView.contains("Notification.Name(\""))
        XCTAssertFalse(dedicatedView.contains("Notification.Name(\""))
    }

    func testPrimaryKillActionDoesNotDependOnMemoryStatistics() throws {
        let dedicatedView = try readText(
            at: repositoryRoot.appendingPathComponent("App/Milo/Runtime/DedicatedWindowView.swift")
        )

        // `memoryCard` only renders once `memoryStats` resolves. The kill affordance must live
        // outside it so a failed memory read cannot remove the window's primary action.
        let memoryCard = try contents(
            between: "private func memoryCard(memory: MemoryStats) -> some View {",
            and: "// MARK: - Bottom Bar",
            in: dedicatedView
        )
        XCTAssertFalse(memoryCard.contains("handleKillRequest()"))
        XCTAssertTrue(dedicatedView.contains("private var bottomBar: some View"))
    }

    private func readText(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func readPropertyListDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw TargetBoundaryTestError.expectedDictionary(url.path)
        }
        return dictionary
    }

    private func section(named name: String, before nextName: String, in source: String) throws -> String {
        let startMarker = "\n  \(name):\n"
        let endMarker = "\n  \(nextName):\n"
        guard let startRange = source.range(of: startMarker) else {
            throw TargetBoundaryTestError.missingSection(name)
        }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: endMarker) else {
            throw TargetBoundaryTestError.missingSection(nextName)
        }
        return String(remainder[..<endRange.lowerBound])
    }

    private func contents(between startMarker: String, and endMarker: String, in source: String) throws -> String {
        guard let startRange = source.range(of: startMarker) else {
            throw TargetBoundaryTestError.missingMarker(startMarker)
        }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: endMarker) else {
            throw TargetBoundaryTestError.missingMarker(endMarker)
        }
        return String(remainder[..<endRange.lowerBound])
    }
}

private enum TargetBoundaryTestError: LocalizedError {
    case expectedDictionary(String)
    case missingMarker(String)
    case missingSection(String)

    var errorDescription: String? {
        switch self {
        case .expectedDictionary(let path):
            return "Expected a property-list dictionary at \(path)"
        case .missingMarker(let marker):
            return "Missing marker \(marker)"
        case .missingSection(let name):
            return "Missing project section \(name)"
        }
    }
}
