import Foundation
import AppKit
import MiloDomain
import MiloHardening
import SwiftUI

private enum SelfTestStatus: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

private struct SelfTestResult {
    let name: String
    let status: SelfTestStatus
    let detail: String
}

@MainActor
private struct SettingsSnapshot {
    let launchAtLogin: Bool
    let autoScanOnOpen: Bool
    let autoScanInterval: Int
    let confirmBeforeKill: Bool
    let showBadgeCount: Bool
    let showMemoryInHeader: Bool
    let notifyOnDetection: Bool
    let statsData: Data?
    let whitelistData: Data?
    let statsExisted: Bool
    let whitelistExisted: Bool

    static func capture() -> SettingsSnapshot {
        let appSupport = SelfTestRunner.appSupportDirectory()
        let statsURL = appSupport.appendingPathComponent("stats.json")
        let whitelistURL = appSupport.appendingPathComponent("whitelist.json")

        return SettingsSnapshot(
            launchAtLogin: SettingsManager.shared.launchAtLogin,
            autoScanOnOpen: SettingsManager.shared.autoScanOnOpen,
            autoScanInterval: SettingsManager.shared.autoScanInterval,
            confirmBeforeKill: SettingsManager.shared.confirmBeforeKill,
            showBadgeCount: SettingsManager.shared.showBadgeCount,
            showMemoryInHeader: SettingsManager.shared.showMemoryInHeader,
            notifyOnDetection: SettingsManager.shared.notifyOnDetection,
            statsData: SelfTestRunner.readDataIfPresent(at: statsURL),
            whitelistData: SelfTestRunner.readDataIfPresent(at: whitelistURL),
            statsExisted: FileManager.default.fileExists(atPath: statsURL.path),
            whitelistExisted: FileManager.default.fileExists(atPath: whitelistURL.path)
        )
    }

    func restore() {
        let defaults = UserDefaults.standard
        defaults.set(launchAtLogin, forKey: "Milo.launchAtLogin")
        defaults.set(autoScanOnOpen, forKey: "Milo.autoScanOnOpen")
        defaults.set(autoScanInterval, forKey: "Milo.autoScanInterval")
        defaults.set(confirmBeforeKill, forKey: "Milo.confirmBeforeKill")
        defaults.set(showBadgeCount, forKey: "Milo.showBadgeCount")
        defaults.set(showMemoryInHeader, forKey: "Milo.showMemoryInHeader")
        defaults.set(notifyOnDetection, forKey: "Milo.notifyOnDetection")

        let appSupport = SelfTestRunner.appSupportDirectory()
        SelfTestRunner.restoreFile(
            data: statsData,
            existed: statsExisted,
            to: appSupport.appendingPathComponent("stats.json")
        )
        SelfTestRunner.restoreFile(
            data: whitelistData,
            existed: whitelistExisted,
            to: appSupport.appendingPathComponent("whitelist.json")
        )
    }
}

private struct SyntheticProcessHandle {
    let name: String
    let vendor: String
    let task: Task<Void, Never>
    let completion: DispatchSemaphore
    let directory: URL
}

@MainActor
enum SelfTestRunner {
    private static func emit(_ message: String = "") {
        guard let data = (message + "\n").data(using: .utf8) else {
            MiloLog.error(.selfTestEncodingFailed, category: .selfTest)
            return
        }
        FileHandle.standardOutput.write(data)
    }

    static func run(includeDestructive: Bool = false) -> Int32 {
        let snapshot = SettingsSnapshot.capture()
        defer { snapshot.restore() }

        SettingsManager.shared.notifyOnDetection = false
        SettingsManager.shared.autoScanInterval = 0
        SettingsManager.shared.confirmBeforeKill = false

        var results: [SelfTestResult] = []

        results.append(testSearchBoxRemoval())

        do {
            let initialScan = try ProcessManager.shared.scanForRunningTargetsWithResources()
            results.append(contentsOf: testScannerCoverage(with: initialScan))
        } catch {
            results.append(
                SelfTestResult(
                    name: "Process scanner",
                    status: .fail,
                    detail: "The initial process scan failed with \(error.localizedDescription)"
                )
            )
        }
        results.append(testProtectedToolsExcludedFromDefaultTargets())
        results.append(contentsOf: testOpenDiscoverySafety())
        results.append(testDiscoveredProcessTermination(includeDestructive: includeDestructive))
        results.append(testDirectCommandArgumentsDoNotInvokeShell())

        let appState = AppState()
        _ = waitUntil(timeout: 8) { !appState.isScanning }

        results.append(testWhitelist(using: appState))
        results.append(contentsOf: testPopoverScanBehavior(using: appState))
        results.append(testScanDoesNotKillAutomatically(using: appState))
        results.append(testBulkKillConfirmation(using: appState))
        results.append(testSelectedKillAndStats(using: appState))
        results.append(testVendorKill(using: appState))
        results.append(
            includeDestructive
            ? testLaunchItemToggle()
            : SelfTestResult(name: "Launch item toggle", status: .skip, detail: "Run with --self-test-destructive to create and toggle a real LaunchAgent")
        )
        results.append(contentsOf: testMemoryFeatures(includeDestructive: includeDestructive))
        results.append(contentsOf: testSettingsPersistence(includeDestructive: includeDestructive))
        results.append(testDebloatSheetConstruction())
        results.append(testDebloatCommandCatalog())
        results.append(contentsOf: testDebloatTweaks(includeDestructive: includeDestructive))

        emit("Milo self-test")
        emit("Mode: \(includeDestructive ? "destructive integration" : "safe")")
        emit("Bundle: \(Bundle.main.bundlePath)")
        emit("Date: \(ISO8601DateFormatter().string(from: Date()))")
        emit()

        for result in results {
            emit("[\(result.status.rawValue)] \(result.name): \(result.detail)")
        }

        let failures = results.filter { $0.status == .fail }
        let passes = results.filter { $0.status == .pass }.count
        let skips = results.filter { $0.status == .skip }.count
        emit()
        emit("Summary: \(passes) passed, \(failures.count) failed, \(skips) skipped")

        return failures.isEmpty ? 0 : 1
    }

    static func runPreviewSmoke() -> Int32 {
        var results: [SelfTestResult] = []
        results.append(testProtectedToolsExcludedFromDefaultTargets())
        results.append(contentsOf: testOpenDiscoverySafety())
        results.append(testDirectCommandArgumentsDoNotInvokeShell())
        results.append(testDebloatCommandCatalog())

        do {
            let scan = try ProcessManager.shared.scanForRunningTargetsWithResources()
            let items = scan.bloat + scan.intelligence
            let identitiesAreComplete = items.allSatisfy { item in
                item.matchedPIDs == Set(item.matchedIdentities.map(\.pid))
                    && item.matchedIdentities.allSatisfy { identity in
                        identity.pid > 1
                            && identity.executablePath.hasPrefix("/")
                            && identity.startSeconds > 0
                    }
            }
            results.append(
                SelfTestResult(
                    name: "Process identity capture",
                    status: identitiesAreComplete ? .pass : .fail,
                    detail: identitiesAreComplete
                        ? "Every detected target has a stable PID, path, and start-time identity"
                        : "One or more detected targets lacked complete process identity metadata"
                )
            )
        } catch {
            results.append(
                SelfTestResult(
                    name: "Process identity capture",
                    status: .fail,
                    detail: "The read-only process scan failed: \(error.localizedDescription)"
                )
            )
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/MiloPrivilegedHelper")
        let helperIsEmbedded = FileManager.default.isExecutableFile(atPath: helperURL.path)
        results.append(
            SelfTestResult(
                name: "Privileged helper embedding",
                status: helperIsEmbedded ? .pass : .fail,
                detail: helperIsEmbedded
                    ? "The signed helper executable is embedded at the SMAppService bundle path"
                    : "The helper executable is missing from the app bundle"
            )
        )
        let signatureIsTrusted = MiloIntegrity.check(.launch)
        results.append(
            SelfTestResult(
                name: "Runtime code signature",
                status: signatureIsTrusted ? .pass : .fail,
                detail: signatureIsTrusted
                    ? "The running preview satisfies Milo's exact team and bundle requirement"
                    : "The running preview failed Milo's code-signing requirement"
            )
        )

        emit("Milo Public Preview smoke test")
        for result in results {
            emit("[\(result.status.rawValue)] \(result.name): \(result.detail)")
        }
        let failures = results.filter { $0.status == .fail }
        emit("Summary: \(results.count - failures.count) passed, \(failures.count) failed")
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - Feature Tests

    private static func testSearchBoxRemoval() -> SelfTestResult {
        let root = FileManager.default.currentDirectoryPath
        let contentViewPath = root + "/Milo/Sources/ContentView.swift"
        let appStatePath = root + "/Milo/Sources/AppState.swift"

        guard let contentView = readStringIfPresent(atPath: contentViewPath),
              let appState = readStringIfPresent(atPath: appStatePath) else {
            return SelfTestResult(name: "Search box removal", status: .skip, detail: "Source files not readable from current working directory")
        }

        let removedUI = !contentView.contains("Search processes")
        let removedState = !appState.contains("@Published var searchText")

        if removedUI && removedState {
            return SelfTestResult(name: "Search box removal", status: .pass, detail: "Main process search UI and state are gone")
        }

        return SelfTestResult(name: "Search box removal", status: .fail, detail: "Search UI or search state still exists in the main view")
    }

    /// Exercises open discovery against the live process table.
    ///
    /// This is the check the 0.2.0-preview.2 handoff could not offer. Its smoke step told the
    /// reader to terminate a synthetic process such as `sleep 600 &`, which could never
    /// appear, because Milo listed a process only when a shipped rule named it. Discovery
    /// makes that observable, so the safety properties are now assertable on real data rather
    /// than argued for in prose.
    private static func testOpenDiscoverySafety() -> [SelfTestResult] {
        let options = ProcessScanOptions(
            includesDiscovery: true,
            foregroundApplicationPIDs: ProcessSafetyInspector.shared.foregroundApplicationPIDs(),
            protectedProcessNames: []
        )

        let discovered: [DiscoveredProcess]
        do {
            discovered = try ProcessManager.shared.scanForRunningTargetsWithResources(options: options).discovered
        } catch {
            return [
                SelfTestResult(
                    name: "Open discovery",
                    status: .fail,
                    detail: "The discovery scan failed with \(error.localizedDescription)"
                )
            ]
        }

        var results: [SelfTestResult] = []

        let actionable = discovered.filter(\.isActionable)
        // Naming a few makes the smoke check falsifiable by eye. The previous handoff's step
        // ("terminate `sleep 600 &`") looked reasonable and was impossible; printing what was
        // actually found is what makes the difference visible.
        let sample = actionable.prefix(5).map { "\($0.name)(\($0.pid))" }.joined(separator: ", ")
        results.append(
            SelfTestResult(
                name: "Open discovery finds background processes",
                status: discovered.isEmpty ? .fail : .pass,
                detail: "\(discovered.count) classified, \(actionable.count) actionable"
                    + (sample.isEmpty ? "" : " — e.g. \(sample)")
            )
        )

        // No actionable row may be operating-system infrastructure.
        let actionableSystemPaths = discovered
            .filter(\.isActionable)
            .filter { MiloProcessSafetyPolicy.isCriticalSystemExecutable($0.executablePath) }
            .map(\.executablePath)
        results.append(
            SelfTestResult(
                name: "Discovery never offers a session-critical service",
                status: actionableSystemPaths.isEmpty ? .pass : .fail,
                detail: actionableSystemPaths.isEmpty
                    ? "No critical service was actionable"
                    : "Actionable critical services: \(actionableSystemPaths.joined(separator: ", "))"
            )
        )

        // The privileged path is the one that can break the machine.
        let privilegedAppleTargets = discovered
            .filter(\.requiresPrivilegedHelper)
            .filter { MiloProcessSafetyPolicy.isOnSealedSystemVolume($0.executablePath) }
            .map(\.executablePath)
        results.append(
            SelfTestResult(
                name: "Root helper is never offered an Apple system binary",
                status: privilegedAppleTargets.isEmpty ? .pass : .fail,
                detail: privilegedAppleTargets.isEmpty
                    ? "No sealed-volume executable was routed to the helper"
                    : "Sealed-volume targets: \(privilegedAppleTargets.joined(separator: ", "))"
            )
        )

        let selfIsActionable = discovered.contains { $0.isActionable && $0.pid == getpid() }
        results.append(
            SelfTestResult(
                name: "Discovery never offers Milo itself",
                status: selfIsActionable ? .fail : .pass,
                detail: selfIsActionable ? "Milo appeared as an actionable target" : "Milo is not a target"
            )
        )

        let initIsPresent = discovered.contains { $0.pid <= 1 && $0.isActionable }
        results.append(
            SelfTestResult(
                name: "Discovery never offers the kernel or launchd",
                status: initIsPresent ? .fail : .pass,
                detail: initIsPresent ? "pid <= 1 was actionable" : "pid 0 and pid 1 are protected"
            )
        )

        // Every actionable process must carry a revalidatable identity; a PID-only target
        // races process exit and can signal a reused pid.
        let identitiesAreComplete = discovered.filter(\.isActionable).allSatisfy { candidate in
            candidate.identity.pid == candidate.pid
                && candidate.identity.executablePath.hasPrefix("/")
                && candidate.identity.startSeconds > 0
        }
        results.append(
            SelfTestResult(
                name: "Actionable discoveries carry a full process identity",
                status: identitiesAreComplete ? .pass : .fail,
                detail: identitiesAreComplete
                    ? "Every actionable row has pid, path and start time"
                    : "At least one actionable row lacks a revalidatable identity"
            )
        )

        return results
    }

    /// Discovers a process this test started, then terminates it through the shipped path.
    ///
    /// The fixture is a copy of `/bin/sleep` under a temporary directory: a user-owned,
    /// non-launchd background job — exactly the shape open discovery exists to reach, and one
    /// whose loss costs nothing.
    private static func testDiscoveredProcessTermination(includeDestructive: Bool) -> SelfTestResult {
        let name = "Discovered process termination"
        guard includeDestructive else {
            return SelfTestResult(
                name: name,
                status: .skip,
                detail: "Run with --self-test-destructive to discover and terminate a real background process"
            )
        }

        guard let handle = spawnSyntheticProcess(named: "milo-discovery-fixture", vendor: "Self Test") else {
            return SelfTestResult(name: name, status: .fail, detail: "Could not start the fixture process")
        }
        defer { cleanupSyntheticProcesses([handle]) }

        // The kernel reports `/private/var/folders/...` while NSTemporaryDirectory() reports
        // `/var/folders/...`, and Foundation's path-resolving APIs strip a leading `/private`
        // rather than adding it, so the two never compare equal. The fixture directory name
        // carries a UUID, so matching on the trailing components is unambiguous.
        let fixtureURL = handle.directory.appendingPathComponent(handle.name)
        let fixturePath = fixtureURL.path
        let fixtureSuffix = "/\(handle.directory.lastPathComponent)/\(handle.name)"
        let options = ProcessScanOptions(
            includesDiscovery: true,
            foregroundApplicationPIDs: [],
            protectedProcessNames: []
        )

        let discovered: [DiscoveredProcess]
        do {
            discovered = try ProcessManager.shared.scanForRunningTargetsWithResources(options: options).discovered
        } catch {
            return SelfTestResult(name: name, status: .fail, detail: "Discovery scan failed: \(error.localizedDescription)")
        }

        guard let target = discovered.first(where: { $0.executablePath.hasSuffix(fixtureSuffix) }) else {
            return SelfTestResult(
                name: name,
                status: .fail,
                detail: "Discovery did not find the fixture at \(fixturePath)"
            )
        }

        guard target.safety == .userOwned else {
            return SelfTestResult(
                name: name,
                status: .fail,
                detail: "Fixture classified as \(target.safety) rather than userOwned"
            )
        }

        // The completion is delivered on the main queue, so the run loop has to keep turning
        // while the test waits. Blocking on a semaphore here deadlocks against it.
        let outcome = SelfTestResultBox(
            SelfTestResult(name: name, status: .fail, detail: "Termination did not report a result")
        )
        let finished = MainActorFlagBox()
        ProcessManager.shared.terminateDiscoveredProcesses([target]) { results in
            let reported = results.allSatisfy(\.success)
            outcome.set(
                SelfTestResult(
                    name: name,
                    status: reported ? .pass : .fail,
                    detail: reported ? "Termination reported success" : "Termination reported failure"
                )
            )
            finished.set()
        }
        guard waitUntil(timeout: 20, condition: { finished.isSet }) else {
            return SelfTestResult(name: name, status: .fail, detail: "Termination timed out")
        }

        let reported = outcome.get().status == .pass
        let stillRunning = syntheticProcessIsRunning(at: URL(fileURLWithPath: fixturePath))

        return SelfTestResult(
            name: name,
            status: reported && !stillRunning ? .pass : .fail,
            detail: reported && !stillRunning
                ? "Discovered \(target.name) (pid \(target.pid)) as userOwned and terminated it without the helper"
                : "reported=\(reported) stillRunning=\(stillRunning)"
        )
    }

    private static func testScannerCoverage(with scan: ProcessScanResult) -> [SelfTestResult] {
        let rawProcesses = CommandRunner.run("/bin/ps", arguments: ["-Axo", "command"]).stdout.lowercased()
        let detected = Set((scan.bloat.map { $0.name.lowercased() } + scan.intelligence.map { $0.name.lowercased() }))

        var results: [SelfTestResult] = []

        let names = scan.bloat.map(\.name) + scan.intelligence.map(\.name)
        if Set(names).count == names.count {
            results.append(SelfTestResult(name: "Scanner deduplication", status: .pass, detail: "No duplicate target names in the live scan"))
        } else {
            results.append(SelfTestResult(name: "Scanner deduplication", status: .fail, detail: "Duplicate target names still appear in the live scan"))
        }

        let coverageChecks: [(label: String, pattern: String, expected: String, kind: String)] = [
            ("BiomeAgent detection", "biomeagent", "biomeagent", "intelligence"),
            ("contextstored detection", "contextstored", "contextstored", "intelligence"),
            ("ContextStoreAgent detection", "contextstoreagent", "contextstoreagent", "intelligence"),
            ("IntelligencePlatformComputeService detection", "intelligenceplatformcomputeservice", "intelligenceplatformcomputeservice", "intelligence"),
            ("SAExtensionOrchestrator detection", "saextensionorchestrator", "saextensionorchestrator", "intelligence"),
            ("BiomeSELFIngestor detection", "biomeselfingestor", "biomeselfingestor", "intelligence"),
            ("simdiskimaged detection", "simdiskimaged", "simdiskimaged", "bloat"),
            ("SimLaunchHost detection", "simlaunchhost.arm64", "simlaunchhost.arm64", "bloat")
        ]

        for check in coverageChecks {
            if rawProcesses.contains(check.pattern) {
                if detected.contains(check.expected) {
                    results.append(SelfTestResult(name: check.label, status: .pass, detail: "Live \(check.kind) process is now detected"))
                } else {
                    results.append(SelfTestResult(name: check.label, status: .fail, detail: "Live process matched '\(check.pattern)' but scan missed '\(check.expected)'"))
                }
            } else {
                results.append(SelfTestResult(name: check.label, status: .skip, detail: "No live process matched '\(check.pattern)' during this run"))
            }
        }

        let widgetsRunning = rawProcesses.contains(".appex/contents/macos/") && rawProcesses.contains("widget")
        if widgetsRunning {
            let detectedWidgets = scan.bloat.filter { $0.name.localizedCaseInsensitiveContains("widget") }
            if detectedWidgets.isEmpty {
                results.append(SelfTestResult(name: "Widget detection", status: .fail, detail: "Widget extension processes were live but none were detected"))
            } else {
                results.append(SelfTestResult(name: "Widget detection", status: .pass, detail: "Detected widget processes: \(detectedWidgets.prefix(5).map(\.name).joined(separator: ", "))"))
            }
        } else {
            results.append(SelfTestResult(name: "Widget detection", status: .skip, detail: "No live widget extension processes were present before widget disable"))
        }

        return results
    }

    private static func testProtectedToolsExcludedFromDefaultTargets() -> SelfTestResult {
        let protectedPatterns = [
            "1password", "lastpass", "dashlane", "bitwarden",
            "nordvpn", "expressvpn", "surfshark", "cloudflare", "adguard",
            "little-snitch", "obdev", "lulu",
            "backblaze", "carbonite", "crashplan", "arq", "chronosync"
        ]

        let bloatTargets = ProcessData.bloatTargets.map { $0.lowercased() }
        let launchKeywords = ProcessData.launchItemKeywords.map { $0.lowercased() }

        let targetHits = protectedPatterns.filter { pattern in
            bloatTargets.contains { $0.contains(pattern) } || launchKeywords.contains { $0.contains(pattern) }
        }

        if targetHits.isEmpty {
            return SelfTestResult(name: "Protected tools excluded", status: .pass, detail: "Password managers, VPNs, firewalls, and backup tools are absent from default targets")
        }

        return SelfTestResult(name: "Protected tools excluded", status: .fail, detail: "Protected defaults still matched: \(targetHits.joined(separator: ", "))")
    }

    private static func testDirectCommandArgumentsDoNotInvokeShell() -> SelfTestResult {
        let marker = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("milo-shell-injection-marker")
        removeIfExists(at: marker)
        defer { removeIfExists(at: marker) }

        let payload = "hello; touch milo-shell-injection-marker"
        let result = CommandRunner.run("/bin/echo", arguments: [payload])
        let markerExists = FileManager.default.fileExists(atPath: marker.path)

        if result.succeeded && !markerExists && result.stdout.contains(payload) {
            return SelfTestResult(name: "Direct command arguments", status: .pass, detail: "Metacharacters stayed inside argv and did not execute as shell")
        }

        return SelfTestResult(name: "Direct command arguments", status: .fail, detail: "Command metacharacters escaped argv isolation")
    }

    private static func testWhitelist(using appState: AppState) -> SelfTestResult {
        guard let target = (appState.visibleBloat + appState.visibleIntelligence).first else {
            return SelfTestResult(name: "Whitelist", status: .skip, detail: "No detected processes were available to whitelist")
        }

        WhitelistManager.shared.removeFromWhitelist(target.name)
        appState.scanProcesses()
        _ = waitUntil(timeout: 8) { !appState.isScanning }

        appState.addToWhitelist(target.name)
        _ = waitUntil(timeout: 8) { !appState.isScanning }
        let hidden = !(appState.visibleBloat + appState.visibleIntelligence).contains { $0.name == target.name }

        appState.removeFromWhitelist(target.name)
        _ = waitUntil(timeout: 8) { !appState.isScanning }
        let visibleAgain = (appState.visibleBloat + appState.visibleIntelligence).contains { $0.name == target.name }

        if hidden && visibleAgain {
            return SelfTestResult(name: "Whitelist", status: .pass, detail: "Whitelisting hid '\(target.name)' and removing it brought the item back")
        }

        return SelfTestResult(name: "Whitelist", status: .fail, detail: "Whitelist visibility did not round-trip correctly for '\(target.name)'")
    }

    private static func testPopoverScanBehavior(using appState: AppState) -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        appState.handleSurfaceClosed()
        SettingsManager.shared.autoScanOnOpen = false
        SettingsManager.shared.autoScanInterval = 0
        appState.lastScanDate = nil
        appState.handleSurfaceOpened()
        let stayedIdle = waitUntil(timeout: 1.5) { appState.lastScanDate == nil }

        results.append(
            stayedIdle
            ? SelfTestResult(name: "Scan on Open disabled", status: .pass, detail: "Opening the popover did not trigger a scan when the setting was off")
            : SelfTestResult(name: "Scan on Open disabled", status: .fail, detail: "Opening the popover still triggered a scan when the setting was off")
        )

        appState.handleSurfaceClosed()
        SettingsManager.shared.autoScanOnOpen = true
        SettingsManager.shared.autoScanInterval = 0
        appState.lastScanDate = nil
        appState.handleSurfaceOpened()
        let scannedOnOpen = waitUntil(timeout: 8) { appState.lastScanDate != nil && !appState.isScanning }

        results.append(
            scannedOnOpen
            ? SelfTestResult(name: "Scan on Open enabled", status: .pass, detail: "Opening the popover triggered a scan when the setting was on")
            : SelfTestResult(name: "Scan on Open enabled", status: .fail, detail: "Opening the popover did not trigger a scan when the setting was on")
        )

        appState.handleSurfaceClosed()
        SettingsManager.shared.autoScanOnOpen = false
        SettingsManager.shared.autoScanInterval = 1
        appState.lastScanDate = Date(timeIntervalSince1970: 1)
        let baseline = appState.lastScanDate ?? Date(timeIntervalSince1970: 1)
        appState.handleSurfaceOpened()
        let rescannedWhileOpen = waitUntil(timeout: 4) { (appState.lastScanDate ?? baseline) > baseline && !appState.isScanning }

        let openResult = rescannedWhileOpen
            ? SelfTestResult(name: "Auto-rescan while open", status: .pass, detail: "The timer refreshed the scan only while the popover was open")
            : SelfTestResult(name: "Auto-rescan while open", status: .fail, detail: "The timer did not refresh the scan while the popover was open")
        results.append(openResult)

        appState.handleSurfaceClosed()
        let closedStamp = appState.lastScanDate ?? Date()
        let stayedStopped = waitUntil(timeout: 1.8) { (appState.lastScanDate ?? closedStamp) == closedStamp }
        results.append(
            stayedStopped
            ? SelfTestResult(name: "Auto-rescan stops on close", status: .pass, detail: "No extra scan fired after the popover closed")
            : SelfTestResult(name: "Auto-rescan stops on close", status: .fail, detail: "The timer kept scanning after the popover closed")
        )

        SettingsManager.shared.autoScanInterval = 0
        appState.handleSurfaceClosed()
        return results
    }

    private static func testSelectedKillAndStats(using appState: AppState) -> SelfTestResult {
        guard let handle = spawnSyntheticProcess(named: "Notion Helper", vendor: "Notion") else {
            return SelfTestResult(name: "Selected kill", status: .fail, detail: "Failed to spawn synthetic Notion Helper process")
        }
        defer { cleanupSyntheticProcesses([handle]) }

        appState.scanProcesses()
        let detected = waitUntil(timeout: 8) {
            !appState.isScanning && appState.activeBloat.contains { $0.name == handle.name }
        }
        guard detected else {
            return SelfTestResult(name: "Selected kill", status: .fail, detail: "Synthetic '\(handle.name)' process did not appear in the scan")
        }

        appState.selectAll(false)
        guard let index = appState.activeBloat.firstIndex(where: { $0.name == handle.name }) else {
            return SelfTestResult(name: "Selected kill", status: .fail, detail: "Synthetic '\(handle.name)' target was not selectable")
        }
        let target = appState.activeBloat[index]
        appState.activeBloat[index].isSelected = true
        let beforeStats = StatsManager.shared.getStats().totalProcessesKilled
        appState.lastKillResults = []

        appState.confirmKill()
        let completed = waitUntil(timeout: 20) { !appState.isKilling && !appState.lastKillResults.isEmpty }
        guard completed else {
            return SelfTestResult(name: "Selected kill", status: .fail, detail: "Kill completion callback never arrived for '\(target.name)'")
        }

        let result = appState.lastKillResults.first { $0.name == target.name }
        let updatedStats = StatsManager.shared.getStats().totalProcessesKilled
        appState.scanProcesses()
        _ = waitUntil(timeout: 8) { !appState.isScanning }
        let gone = !appState.activeBloat.contains { $0.name == handle.name }

        if result?.success == true && updatedStats > beforeStats && gone {
            return SelfTestResult(name: "Selected kill", status: .pass, detail: "Killed '\(target.name)' and stats increased from \(beforeStats) to \(updatedStats)")
        }

        return SelfTestResult(name: "Selected kill", status: .fail, detail: "Kill result or stats update failed for '\(target.name)'")
    }

    private static func testScanDoesNotKillAutomatically(using appState: AppState) -> SelfTestResult {
        guard let handle = spawnSyntheticProcess(named: "Evernote Helper", vendor: "Evernote") else {
            return SelfTestResult(name: "Scan is read-only", status: .fail, detail: "Failed to spawn synthetic Evernote Helper process")
        }
        defer { cleanupSyntheticProcesses([handle]) }

        appState.lastKillResults = []
        appState.scanProcesses()
        let detected = waitUntil(timeout: 8) {
            !appState.isScanning && appState.activeBloat.contains { $0.name == handle.name }
        }

        guard detected else {
            return SelfTestResult(name: "Scan is read-only", status: .fail, detail: "Synthetic '\(handle.name)' process did not appear in the scan")
        }

        let stillRunning = syntheticProcessIsRunning(
            at: handle.directory.appendingPathComponent(handle.name)
        )
        let noKillTriggered = appState.lastKillResults.isEmpty

        if stillRunning && noKillTriggered {
            return SelfTestResult(name: "Scan is read-only", status: .pass, detail: "Scanning detected '\(handle.name)' without trying to kill it")
        }

        return SelfTestResult(name: "Scan is read-only", status: .fail, detail: "Scan triggered an unexpected kill path for '\(handle.name)'")
    }

    private static func testBulkKillConfirmation(using appState: AppState) -> SelfTestResult {
        let oldBloat = appState.activeBloat
        let oldIntel = appState.activeIntelligence
        let oldConfirm = SettingsManager.shared.confirmBeforeKill
        defer {
            appState.cancelKill()
            appState.activeBloat = oldBloat
            appState.activeIntelligence = oldIntel
            SettingsManager.shared.confirmBeforeKill = oldConfirm
        }

        appState.activeBloat = [
            ProcessItem(
                name: "Milo Confirmation Target",
                description: "Synthetic confirmation target",
                vendor: "SelfTestVendor",
                cpuUsage: 0,
                memoryMB: 0,
                isLaunchdManaged: false,
                isSystemProcess: false
            )
        ]
        appState.activeIntelligence = []
        SettingsManager.shared.confirmBeforeKill = true

        appState.killVendor("SelfTestVendor")
        let vendorPrompts = appState.showingKillConfirmation && appState.pendingKillCount == 1 && !appState.isKilling
        appState.cancelKill()

        appState.killAllDetected()
        let allPrompts = appState.showingKillConfirmation && appState.pendingKillCount == 1 && !appState.isKilling

        if vendorPrompts && allPrompts {
            return SelfTestResult(name: "Bulk kill confirmation", status: .pass, detail: "Vendor Kill All and global Kill All both honor confirmation")
        }

        return SelfTestResult(name: "Bulk kill confirmation", status: .fail, detail: "A bulk kill path bypassed confirmation")
    }

    private static func testVendorKill(using appState: AppState) -> SelfTestResult {
        let scenarios: [(vendor: String, names: [String])] = [
            ("Slack", ["Slack Helper", "Slack Helper (GPU)"]),
            ("Discord", ["Discord Helper", "Discord Helper (GPU)"])
        ]

        appState.scanProcesses()
        _ = waitUntil(timeout: 8) { !appState.isScanning }

        guard let scenario = scenarios.first(where: { vendor, _ in
            !(appState.activeBloat + appState.activeIntelligence).contains { $0.vendor == vendor }
        }) else {
            return SelfTestResult(name: "Vendor kill", status: .skip, detail: "Slack or Discord are already active on this Mac, so synthetic vendor-kill would interfere with real apps")
        }

        let handles = scenario.names.compactMap { spawnSyntheticProcess(named: $0, vendor: scenario.vendor) }
        guard handles.count == scenario.names.count else {
            cleanupSyntheticProcesses(handles)
            return SelfTestResult(name: "Vendor kill", status: .fail, detail: "Failed to spawn synthetic \(scenario.vendor) helper processes")
        }
        defer { cleanupSyntheticProcesses(handles) }

        appState.scanProcesses()
        let detected = waitUntil(timeout: 8) {
            !appState.isScanning && scenario.names.allSatisfy { name in
                appState.activeBloat.contains { $0.name == name }
            }
        }
        guard detected else {
            return SelfTestResult(name: "Vendor kill", status: .fail, detail: "Synthetic \(scenario.vendor) helpers did not appear in the scan")
        }

        appState.lastKillResults = []
        appState.killVendor(scenario.vendor)
        let completed = waitUntil(timeout: 25) { !appState.isKilling && !appState.lastKillResults.isEmpty }
        guard completed else {
            return SelfTestResult(name: "Vendor kill", status: .fail, detail: "Vendor kill did not finish for \(scenario.vendor)")
        }

        appState.scanProcesses()
        _ = waitUntil(timeout: 8) { !appState.isScanning }
        let remainingVendor = appState.activeBloat.filter { item in
            item.vendor == scenario.vendor && scenario.names.contains(item.name)
        }

        if remainingVendor.isEmpty {
            return SelfTestResult(name: "Vendor kill", status: .pass, detail: "Removed all synthetic \(scenario.vendor) background processes")
        }

        return SelfTestResult(name: "Vendor kill", status: .fail, detail: "\(scenario.vendor) processes still detected after vendor kill: \(remainingVendor.map(\.name).joined(separator: ", "))")
    }

    private static func testLaunchItemToggle() -> SelfTestResult {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.adobe.milo.selftest.agent.plist")
        let label = "com.adobe.milo.selftest.agent"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sleep", "600"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background"
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url)
        } catch {
            return SelfTestResult(name: "Launch item toggle", status: .fail, detail: "Failed to write self-test plist: \(error.localizedDescription)")
        }

        defer {
            ProcessManager.shared.toggleLaunchItem(path: url.path, enable: false)
            _ = waitUntil(timeout: 4) {
                !ProcessManager.shared.scanForLaunchItems().contains { $0.label == label && $0.isLoaded }
            }
            removeIfExists(at: url)
        }

        ProcessManager.shared.toggleLaunchItem(path: url.path, enable: true)
        let enabled = waitUntil(timeout: 6) {
            ProcessManager.shared.scanForLaunchItems().contains { $0.label == label && $0.isLoaded }
        }
        guard enabled else {
            return SelfTestResult(name: "Launch item toggle", status: .fail, detail: "The self-test launch agent did not enable correctly")
        }

        ProcessManager.shared.toggleLaunchItem(path: url.path, enable: false)
        let disabled = waitUntil(timeout: 6) {
            ProcessManager.shared.scanForLaunchItems().contains { $0.label == label && !$0.isLoaded }
        }
        guard disabled else {
            return SelfTestResult(name: "Launch item toggle", status: .fail, detail: "The self-test launch agent did not disable correctly")
        }

        ProcessManager.shared.toggleLaunchItem(path: url.path, enable: true)
        let reenabled = waitUntil(timeout: 6) {
            ProcessManager.shared.scanForLaunchItems().contains { $0.label == label && $0.isLoaded }
        }

        if reenabled {
            return SelfTestResult(name: "Launch item toggle", status: .pass, detail: "User LaunchAgent enabled, disabled, and re-enabled correctly")
        }

        return SelfTestResult(name: "Launch item toggle", status: .fail, detail: "The self-test launch agent did not re-enable correctly")
    }

    private static func testMemoryFeatures(includeDestructive: Bool) -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        if let stats = MemoryManager.shared.getMemoryStats(), stats.totalGB > 0 {
            results.append(SelfTestResult(name: "Memory stats", status: .pass, detail: String(format: "Read %.1f GB total RAM with %@ pressure", stats.totalGB, stats.memoryPressure.description)))
        } else {
            results.append(SelfTestResult(name: "Memory stats", status: .fail, detail: "Memory statistics could not be read"))
        }

        results.append(testCacheClearingInTemporaryDirectory())

        if includeDestructive {
            let dnsResult = waitForCompletion(timeout: 20) { finish in
                MemoryManager.shared.clearDNSCache { success, message in
                    finish(SelfTestResult(name: "DNS flush", status: success ? .pass : .fail, detail: message))
                }
            }
            results.append(dnsResult)

            let purgeResult = waitForCompletion(timeout: 60) { finish in
                MemoryManager.shared.purgeMemory { success, message in
                    finish(SelfTestResult(name: "Memory purge", status: success ? .pass : .fail, detail: message))
                }
            }
            results.append(purgeResult)
        } else {
            results.append(SelfTestResult(name: "DNS flush", status: .skip, detail: "Run with --self-test-destructive to flush the real DNS cache"))
            results.append(SelfTestResult(name: "Memory purge", status: .skip, detail: "Run with --self-test-destructive to purge real system memory"))
        }

        return results
    }

    private static func testCacheClearingInTemporaryDirectory() -> SelfTestResult {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("milo-selftest-\(UUID().uuidString)", isDirectory: true)
        let keep = root.appendingPathComponent("com.gonggong.milo")
        let remove = root.appendingPathComponent("com.example.Cache")

        do {
            try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: remove, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: keep.appendingPathComponent("keep.txt"))
            try Data("remove".utf8).write(to: remove.appendingPathComponent("remove.txt"))
        } catch {
            return SelfTestResult(name: "Cache clearing", status: .fail, detail: "Failed to create temporary cache fixture: \(error.localizedDescription)")
        }

        defer { removeIfExists(at: root) }

        let result = MemoryManager.shared.clearCaches(at: root.path)
        let keptOwnCache = FileManager.default.fileExists(atPath: keep.path)
        let removedForeignCache = !FileManager.default.fileExists(atPath: remove.path)

        if result.success && keptOwnCache && removedForeignCache {
            return SelfTestResult(name: "Cache clearing", status: .pass, detail: "Temporary cache fixture cleared while preserving Milo-owned cache")
        }

        return SelfTestResult(name: "Cache clearing", status: .fail, detail: "Temporary cache fixture did not clear safely: \(result.message)")
    }

    private static func testSettingsPersistence(includeDestructive: Bool) -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        let legacyAutoKillKeyPresent = UserDefaults.standard.dictionaryRepresentation().keys.contains("Milo.autoKillOnDetect")
        results.append(
            !legacyAutoKillKeyPresent && !SettingsManager.shared.autoKillOnDetect
            ? SelfTestResult(name: "Automatic kill disabled", status: .pass, detail: "Legacy auto-kill setting is absent and scans remain user-driven")
            : SelfTestResult(name: "Automatic kill disabled", status: .fail, detail: "Legacy auto-kill state is still present in settings")
        )

        SettingsManager.shared.showBadgeCount = false
        SettingsManager.shared.showMemoryInHeader = false
        SettingsManager.shared.confirmBeforeKill = false
        SettingsManager.shared.autoScanOnOpen = false
        SettingsManager.shared.autoScanInterval = 30
        SettingsManager.shared.notifyOnDetection = false

        let persisted = !SettingsManager.shared.showBadgeCount &&
            !SettingsManager.shared.showMemoryInHeader &&
            !SettingsManager.shared.confirmBeforeKill &&
            !SettingsManager.shared.autoScanOnOpen &&
            SettingsManager.shared.autoScanInterval == 30 &&
            !SettingsManager.shared.notifyOnDetection

        results.append(
            persisted
            ? SelfTestResult(name: "Settings persistence", status: .pass, detail: "Preference writes round-tripped through SettingsManager")
            : SelfTestResult(name: "Settings persistence", status: .fail, detail: "One or more preference writes did not persist")
        )

        guard includeDestructive else {
            results.append(SelfTestResult(name: "Launch at login", status: .skip, detail: "Run with --self-test-destructive to toggle the real login item"))
            return results
        }

        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            results.append(SelfTestResult(name: "Launch at login", status: .skip, detail: "Self-test is not running from an app bundle"))
            return results
        }

        let original = SettingsManager.shared.isLoginItemEnabled()
        let target = !original
        SettingsManager.shared.launchAtLogin = target
        let toggled = waitUntil(timeout: 6) { SettingsManager.shared.isLoginItemEnabled() == target }

        SettingsManager.shared.launchAtLogin = original
        let restored = waitUntil(timeout: 6) { SettingsManager.shared.isLoginItemEnabled() == original }

        if toggled && restored {
            results.append(SelfTestResult(name: "Launch at login", status: .pass, detail: "Login item registration toggled to \(target) and restored to \(original)"))
        } else {
            results.append(SelfTestResult(name: "Launch at login", status: .fail, detail: "Login item registration did not match the requested state"))
        }

        return results
    }

    private static func testDebloatSheetConstruction() -> SelfTestResult {
        MainActor.assumeIsolated {
            let appState = AppState()
            let manager = DebloatManager.shared
            let controller = NSHostingController(rootView: DebloatView(appState: appState, manager: manager))
            _ = controller.view

            if !manager.categories.isEmpty && !manager.tweakStates.isEmpty {
                return SelfTestResult(name: "Debloat sheet construction", status: .pass, detail: "Debloat view and manager loaded without crashing")
            }

            return SelfTestResult(name: "Debloat sheet construction", status: .fail, detail: "Debloat view loaded but categories or tweak states were empty")
        }
    }

    private static func testDebloatCommandCatalog() -> SelfTestResult {
        var failures: [String] = []
        for tweak in DebloatManager.shared.categories.flatMap(\.tweaks) {
            let commands = tweak.applyCommands + tweak.revertCommands + tweak.applyPrivileged + tweak.revertPrivileged
            for command in commands where !DebloatManager.canParseValidatedCommand(command) {
                failures.append("\(tweak.id): \(command)")
            }
        }

        if failures.isEmpty {
            return SelfTestResult(name: "Debloat command catalog", status: .pass, detail: "Every debloat recipe is accepted by the validated command parser")
        }

        return SelfTestResult(name: "Debloat command catalog", status: .fail, detail: failures.prefix(3).joined(separator: " | "))
    }

    private static func testDebloatTweaks(includeDestructive: Bool) -> [SelfTestResult] {
        var results: [SelfTestResult] = []

        let syntheticDomain = "com.gonggong.milo.SelfTest"
        let syntheticKey = "DebloatEnabled"
        let syntheticTweak = DebloatTweak(
            id: "selftest.defaults",
            name: "Self-test Defaults",
            description: "Synthetic defaults write used by the safe self-test",
            category: "Self-test",
            requiresSIP: false,
            risk: .safe,
            needsRestart: false,
            applyCommands: ["defaults write \(syntheticDomain) \(syntheticKey) -bool true"],
            applyPrivileged: [],
            revertCommands: ["defaults delete \(syntheticDomain) \(syntheticKey) 2>/dev/null || true"],
            revertPrivileged: [],
            detect: { DebloatManager.defaultsIs(syntheticDomain, syntheticKey, expected: true) }
        )

        let syntheticApplied = runTweak(syntheticTweak, apply: true) && waitUntil(timeout: 4) { syntheticTweak.detect() }
        let syntheticReverted = runTweak(syntheticTweak, apply: false) && waitUntil(timeout: 4) { !syntheticTweak.detect() }
        _ = CommandRunner.run("/usr/bin/defaults", arguments: ["delete", syntheticDomain])

        results.append(
            syntheticApplied && syntheticReverted
            ? SelfTestResult(name: "Defaults-based debloat runner", status: .pass, detail: "Synthetic defaults tweak applied and reverted without touching macOS feature settings")
            : SelfTestResult(name: "Defaults-based debloat runner", status: .fail, detail: "Synthetic defaults tweak did not round-trip cleanly")
        )

        guard includeDestructive else {
            results.append(SelfTestResult(name: "Real debloat tweaks", status: .skip, detail: "Run with --self-test-destructive to mutate real macOS debloat settings"))
            return results
        }

        guard let sampleTweak = findTweak(id: "anim.banner") else {
            results.append(SelfTestResult(name: "Defaults-based debloat tweak", status: .fail, detail: "Could not find anim.banner"))
            return results
        }

        let sampleWasApplied = sampleTweak.detect()
        let appliedSample = runTweak(sampleTweak, apply: true) && waitUntil(timeout: 4) { sampleTweak.detect() }
        let revertedSample = runTweak(sampleTweak, apply: false) && waitUntil(timeout: 4) { !sampleTweak.detect() }
        let restoredSample = sampleWasApplied
            ? (runTweak(sampleTweak, apply: true) && waitUntil(timeout: 4) { sampleTweak.detect() })
            : true
        results.append(
            appliedSample && revertedSample && restoredSample
            ? SelfTestResult(name: "Defaults-based debloat tweak", status: .pass, detail: "anim.banner applied, reverted, and restored to initial state")
            : SelfTestResult(name: "Defaults-based debloat tweak", status: .fail, detail: "anim.banner did not round-trip cleanly")
        )

        guard let widgetTweak = findTweak(id: "svc.widgets") else {
            results.append(SelfTestResult(name: "Widget debloat tweak", status: .fail, detail: "Could not find svc.widgets"))
            return results
        }

        let presentWidgetIDs = DebloatManager.presentWidgetBundleIDs()
        if presentWidgetIDs.isEmpty {
            results.append(SelfTestResult(name: "Widget debloat tweak", status: .skip, detail: "No known widget bundle identifiers were present on this macOS build"))
            return results
        }

        let widgetsWereIgnored = DebloatManager.areWidgetExtensionsIgnored()
        let applyWidgets = runTweak(widgetTweak, apply: true) &&
            waitUntil(timeout: 12) { DebloatManager.areWidgetExtensionsIgnored() && !DebloatManager.anyWidgetProcessesRunning() }

        let revertWidgets = runTweak(widgetTweak, apply: false) &&
            waitUntil(timeout: 8) { !DebloatManager.areWidgetExtensionsIgnored() }

        let restoredWidgets = widgetsWereIgnored
            ? (runTweak(widgetTweak, apply: true) && waitUntil(timeout: 12) { DebloatManager.areWidgetExtensionsIgnored() })
            : true

        if applyWidgets && revertWidgets && restoredWidgets {
            results.append(SelfTestResult(
                name: "Widget debloat tweak",
                status: .pass,
                detail: "Ignored \(DebloatManager.ignoredWidgetBundleIDs().count)/\(presentWidgetIDs.count) live widget extensions and restored the initial widget state"
            ))
        } else {
            results.append(SelfTestResult(name: "Widget debloat tweak", status: .fail, detail: "Widget disable did not apply, revert, and restore cleanly"))
        }

        return results
    }

    // MARK: - Helpers

    fileprivate static func appSupportDirectory() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = baseURL
            .appendingPathComponent("Milo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return FileManager.default.temporaryDirectory
        }
        return url
    }

    fileprivate static func restoreFile(data: Data?, existed: Bool, to url: URL) {
        if existed, let data {
            do {
                try data.write(to: url)
            } catch {
                MiloLog.error(
                    .selfTestRestoreFailed,
                    category: .selfTest,
                    detail: "path=\(url.path) error=\(error.localizedDescription)"
                )
            }
        } else if !existed {
            removeIfExists(at: url)
        }
    }

    private static func findTweak(id: String) -> DebloatTweak? {
        for category in DebloatManager.shared.categories {
            if let tweak = category.tweaks.first(where: { $0.id == id }) {
                return tweak
            }
        }
        return nil
    }

    private static func runTweak(_ tweak: DebloatTweak, apply: Bool) -> Bool {
        let userCommands = apply ? tweak.applyCommands : tweak.revertCommands
        let privilegedCommands = apply ? tweak.applyPrivileged : tweak.revertPrivileged

        var success = true
        var touchedDefaults = false

        for command in userCommands {
            if command.contains("defaults ") {
                touchedDefaults = true
            }
            if !DebloatManager.runValidatedCommand(command, privileged: false) {
                success = false
            }
        }

        for command in privilegedCommands {
            if command.contains("defaults ") {
                touchedDefaults = true
            }
            if !runAdminCommand(command) {
                success = false
            }
        }

        if touchedDefaults {
            _ = CommandRunner.run("/usr/bin/killall", arguments: ["cfprefsd"])
        }

        Thread.sleep(forTimeInterval: 0.8)
        return success
    }

    private static func runAdminCommand(_ command: String) -> Bool {
        DebloatManager.runValidatedCommand(command, privileged: true)
    }

    /// SAFETY: `value` is accessed only while `lock` is held.
    private final class SelfTestResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SelfTestResult

        init(_ value: SelfTestResult) {
            self.value = value
        }

        func set(_ newValue: SelfTestResult) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> SelfTestResult {
            lock.lock()
            let currentValue = value
            lock.unlock()
            return currentValue
        }
    }

    private static func waitForCompletion(
        timeout: TimeInterval,
        _ body: (@escaping @Sendable (SelfTestResult) -> Void) -> Void
    ) -> SelfTestResult {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = SelfTestResultBox(SelfTestResult(name: "Async operation", status: .fail, detail: "No result"))

        body {
            resultBox.set($0)
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success {
                return resultBox.get()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let result = resultBox.get()
        return SelfTestResult(name: result.name, status: .fail, detail: "Timed out waiting for completion")
    }

    /// A one-way completion flag readable from the waiting run loop.
    ///
    /// SAFETY: the single mutable property is read and written only while `lock` is held, by
    /// the two accessors below. No other stored property exists.
    private final class MainActorFlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            let current = flag
            lock.unlock()
            return current
        }
    }

    private static func waitUntil(timeout: TimeInterval, interval: TimeInterval = 0.1, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
        }
        return condition()
    }

    private static func spawnSyntheticProcess(named name: String, vendor: String) -> SyntheticProcessHandle? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("milo-selftest-\(UUID().uuidString)", isDirectory: true)
        let executable = directory.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let completion = DispatchSemaphore(value: 0)
            let task = Task.detached(priority: .utility) {
                _ = MiloSubprocessRunner.run(
                    executable: executable.path,
                    arguments: ["600"],
                    maximumOutputBytes: 1_024,
                    deadline: .seconds(60),
                    cancellationRequested: { Task<Never, Never>.isCancelled }
                )
                completion.signal()
            }
            let handle = SyntheticProcessHandle(
                name: name,
                vendor: vendor,
                task: task,
                completion: completion,
                directory: directory
            )
            guard waitUntil(timeout: 1.5, interval: 0.05, condition: {
                syntheticProcessIsRunning(at: executable)
            }) else {
                cleanupSyntheticProcesses([handle])
                return nil
            }
            return handle
        } catch {
            removeIfExists(at: directory)
            return nil
        }
    }

    private static func cleanupSyntheticProcesses(_ handles: [SyntheticProcessHandle]) {
        for handle in handles {
            handle.task.cancel()
            if handle.completion.wait(timeout: .now() + 2) == .timedOut {
                MiloLog.error(
                    .selfTestCleanupFailed,
                    category: .selfTest,
                    detail: "Synthetic process cleanup timed out for \(handle.name)"
                )
            }
            removeIfExists(at: handle.directory)
        }
    }

    private static func syntheticProcessIsRunning(at executable: URL) -> Bool {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "pid=,command="])
        return result.succeeded && result.stdout.contains(executable.path)
    }

    fileprivate static func readDataIfPresent(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            MiloLog.error(
                .selfTestReadFailed,
                category: .selfTest,
                detail: "path=\(url.path) error=\(error.localizedDescription)"
            )
            return nil
        }
    }

    private static func readStringIfPresent(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func removeIfExists(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            MiloLog.error(
                .selfTestCleanupFailed,
                category: .selfTest,
                detail: "path=\(url.path) error=\(error.localizedDescription)"
            )
        }
    }
}
