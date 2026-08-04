import Foundation
import SwiftUI
import Combine
import MiloDomain
import UserNotifications

// MARK: - Sort Options

enum ProcessSortOrder: String, CaseIterable, Sendable {
    case name = "Name"
    case cpuDesc = "CPU"
    case memoryDesc = "Memory"
}

struct ProcessItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let description: String?
    let vendor: String
    let cpuUsage: Double      // percentage
    let memoryMB: Double      // megabytes
    let isLaunchdManaged: Bool  // Will respawn if just killed
    let isSystemProcess: Bool   // Requires SIP disabled to permanently stop
    var matchedPIDs: Set<Int32> = []
    var matchedIdentities: Set<ProcessIdentity> = []
    var telemetryRuleID: String?
    var terminationStrategy: TelemetryTerminationStrategy?
    var launchdLabel: String?
    var launchdDomain: TelemetryLaunchdDomain?
    var isSelected: Bool = false
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct KillResult: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let success: Bool
    let isLaunchdManaged: Bool
    let requiresSIPDisabled: Bool
    /// The signal was delivered and the process exited, but launchd started it again.
    ///
    /// This is a distinct outcome from failure: nothing went wrong, and reporting it as a
    /// failure told the user their action did not work when in fact it did.
    let wasRespawned: Bool

    init(
        name: String,
        success: Bool,
        isLaunchdManaged: Bool = false,
        requiresSIPDisabled: Bool = false,
        wasRespawned: Bool = false
    ) {
        self.name = name
        self.success = success
        self.isLaunchdManaged = isLaunchdManaged
        self.requiresSIPDisabled = requiresSIPDisabled
        self.wasRespawned = wasRespawned
    }
}

struct ProcessScanSnapshot: Equatable, Sendable {
    let bloat: [ProcessItem]
    let intelligence: [ProcessItem]
    let discovered: [DiscoveredProcess]
    let launchItems: [LaunchItem]
    let completedAt: Date
}

@MainActor
final class AppState: ObservableObject {
    @Published var isSIPEnabled: Bool = true
    @Published var detectedLaunchItems: [LaunchItem] = []

    @Published var activeBloat: [ProcessItem] = []
    @Published var activeIntelligence: [ProcessItem] = []

    // Open discovery: background processes outside the shipped catalogue
    @Published var discoveredProcesses: [DiscoveredProcess] = []
    @Published var discoverySearchText: String = ""
    @Published var showsDiscovery: Bool = SettingsManager.shared.showsDiscovery
    @Published var showsProtectedProcesses: Bool = SettingsManager.shared.showsProtectedProcesses

    @Published var showingKillConfirmation: Bool = false
    @Published var showingDiscoveryKillConfirmation: Bool = false
    @Published var lastKillResults: [KillResult] = []
    @Published var showingResults: Bool = false

    // Scanning state
    @Published private(set) var scanState = MiloOperationState<ProcessScanSnapshot>.idle
    @Published var lastScanDate: Date?

    // Sort order
    @Published var sortOrder: ProcessSortOrder = .name

    // Privilege setup
    @Published var isConfiguringPrivileges: Bool = false
    @Published var privilegeError: String?
    @Published var showingFirstLaunchPrivilegePrompt: Bool = false
    @Published var showingHelperRequiredAlert: Bool = false
    @Published private(set) var helperStatus: MiloHelperStatus = .notRegistered

    // Memory management
    @Published var memoryStats: MemoryStats?
    @Published var isPurgingMemory: Bool = false
    @Published var isClearingCaches: Bool = false
    @Published var isFlushingDNS: Bool = false
    @Published var memoryMessage: String = ""
    @Published var showingMemoryMessage: Bool = false
    @Published var showingCacheConfirmation: Bool = false
    @Published var showMemoryInHeader: Bool = SettingsManager.shared.showMemoryInHeader

    // Kill in progress
    @Published var isKilling: Bool = false

    // Stats and history
    @Published var stats: AggregatedStats = StatsManager.shared.getStats()

    // Auto-scan timer
    private var autoScanTimer: Timer?
    private var pendingKillItems: [ProcessItem] = []
    private var pendingDiscovered: [DiscoveredProcess] = []
    private var scanLifecycle = MiloOperationLifecycle<ProcessScanSnapshot>()
    private var scanWorker: Task<ProcessScanSnapshot, Error>?
    private var scanCompletionTask: Task<Void, Never>?

    var isScanning: Bool {
        scanState.isRunning
    }

    var scanFailureMessage: String? {
        guard case .failed(_, let failure) = scanState else {
            return nil
        }
        return failure.message
    }

    var scanResultIsClean: Bool {
        guard case .succeeded(_, let snapshot) = scanState else {
            return false
        }
        return snapshot.bloat.isEmpty && snapshot.intelligence.isEmpty
    }

    var whitelistedProcesses: [String] {
        WhitelistManager.shared.getWhitelistedProcesses()
    }

    // Computed: total bloat count for badge (excluding whitelisted)
    var totalBloatCount: Int {
        visibleBloat.count + visibleIntelligence.count
    }

    // Check if passwordless mode is configured
    var isPasswordlessConfigured: Bool {
        helperStatus.isEnabled
    }

    // Total resource usage of detected bloat
    var totalCPUUsage: Double {
        (visibleBloat + visibleIntelligence).reduce(0) { $0 + $1.cpuUsage }
    }

    var totalMemoryMB: Double {
        (visibleBloat + visibleIntelligence).reduce(0) { $0 + $1.memoryMB }
    }

    nonisolated private static func runOnMain(
        after delay: TimeInterval = 0,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { @MainActor in
            if delay > 0 {
                let boundedDelay = min(delay, 60)
                let nanoseconds = UInt64(boundedDelay * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch is CancellationError {
                    return
                } catch {
                    MiloLog.error(.mainActorDelayFailed, detail: error.localizedDescription)
                    return
                }
            }
            work()
        }
    }

    // Selected process summary
    var selectedCPUUsage: Double {
        selectedForKill.reduce(0) { $0 + $1.cpuUsage }
    }

    var selectedMemoryMB: Double {
        selectedForKill.reduce(0) { $0 + $1.memoryMB }
    }

    var visibleBloat: [ProcessItem] {
        sortedProcesses(activeBloat.filter { !WhitelistManager.shared.isWhitelisted($0.name) })
    }

    var visibleIntelligence: [ProcessItem] {
        sortedProcesses(activeIntelligence.filter { !WhitelistManager.shared.isWhitelisted($0.name) })
    }

    var visibleLaunchItems: [LaunchItem] {
        detectedLaunchItems
    }

    /// Discovered processes after the user's own filters.
    ///
    /// Protected rows stay hidden by default. They are not dangerous to *show* — the point is
    /// that a list dominated by rows nobody can act on buries the handful that matter.
    var visibleDiscovered: [DiscoveredProcess] {
        let query = discoverySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return discoveredProcesses.filter { candidate in
            if !showsProtectedProcesses, !candidate.isActionable {
                return false
            }
            guard !query.isEmpty else { return true }
            return candidate.name.localizedCaseInsensitiveContains(query)
                || candidate.executablePath.localizedCaseInsensitiveContains(query)
                || (candidate.launchdLabel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var discoveredActionableCount: Int {
        discoveredProcesses.filter(\.isActionable).count
    }

    var selectedDiscovered: [DiscoveredProcess] {
        discoveredProcesses.filter { $0.isSelected && $0.isActionable }
    }

    var discoveredSelectionSummary: (cpu: Double, memory: Double) {
        selectedDiscovered.reduce(into: (cpu: 0.0, memory: 0.0)) { total, item in
            total.cpu += item.cpuUsage
            total.memory += item.memoryMB
        }
    }

    // Group bloat by vendor
    var bloatByVendor: [String: [ProcessItem]] {
        Dictionary(grouping: visibleBloat, by: { $0.vendor })
    }

    // Items selected for kill
    var selectedForKill: [ProcessItem] {
        activeBloat.filter { $0.isSelected } + activeIntelligence.filter { $0.isSelected }
    }

    var pendingKillCount: Int {
        pendingKillItems.isEmpty ? selectedForKill.count : pendingKillItems.count
    }

    /// The discovered processes awaiting confirmation, for the dialog to enumerate.
    var pendingDiscoveredProcesses: [DiscoveredProcess] {
        pendingDiscovered
    }

    var pendingDiscoveredRequiresHelper: Bool {
        pendingDiscovered.contains(where: \.requiresPrivilegedHelper)
    }

    // MARK: - Selection Bindings (breaks AttributeGraph cycle)

    /// Creates a Binding for a bloat item's isSelected property without directly
    /// subscripting the @Published array from the view body (which causes a cycle
    /// when the same array is also read through computed properties).
    func bloatSelectionBinding(for itemID: UUID) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.activeBloat.first(where: { $0.id == itemID })?.isSelected ?? false
            },
            set: { [weak self] newValue in
                if let idx = self?.activeBloat.firstIndex(where: { $0.id == itemID }) {
                    self?.activeBloat[idx].isSelected = newValue
                }
            }
        )
    }

    func intelligenceSelectionBinding(for itemID: UUID) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.activeIntelligence.first(where: { $0.id == itemID })?.isSelected ?? false
            },
            set: { [weak self] newValue in
                if let idx = self?.activeIntelligence.firstIndex(where: { $0.id == itemID }) {
                    self?.activeIntelligence[idx].isSelected = newValue
                }
            }
        )
    }

    /// Selection binding for a discovered row.
    ///
    /// The setter refuses protected rows outright, so no view can select something the
    /// policy classified as read-only, whatever its own enablement logic does.
    func discoveredSelectionBinding(for pid: Int32) -> Binding<Bool> {
        Binding<Bool>(
            get: { [weak self] in
                self?.discoveredProcesses.first(where: { $0.pid == pid })?.isSelected ?? false
            },
            set: { [weak self] newValue in
                guard let index = self?.discoveredProcesses.firstIndex(where: { $0.pid == pid }),
                      self?.discoveredProcesses[index].isActionable == true else {
                    return
                }
                self?.discoveredProcesses[index].isSelected = newValue
            }
        )
    }

    init() {
        self.isSIPEnabled = SIPChecker.isSIPEnabled()
        self.helperStatus = PrivilegeManager.shared.status
        self.scanProcesses()
        self.refreshMemoryStats()

        if !CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-destructive") {
            SettingsManager.shared.syncLoginItemState()
            prepareFirstLaunchPrivilegePrompt()
        }
    }

    // MARK: - Sorting

    private func sortedProcesses(_ items: [ProcessItem]) -> [ProcessItem] {
        switch sortOrder {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cpuDesc:
            return items.sorted { $0.cpuUsage > $1.cpuUsage }
        case .memoryDesc:
            return items.sorted { $0.memoryMB > $1.memoryMB }
        }
    }

    func setupPrivileges() {
        isConfiguringPrivileges = true
        privilegeError = nil
        SettingsManager.shared.privilegeOnboardingPrompted = true
        showingFirstLaunchPrivilegePrompt = false
        PrivilegeManager.shared.configurePrivileges { [weak self] result in
            guard let appState = self else { return }
            Self.runOnMain {
                appState.isConfiguringPrivileges = false
                appState.refreshHelperStatus()
                switch result {
                case .enabled:
                    appState.privilegeError = nil
                case .requiresApproval:
                    appState.privilegeError = "Approve Milo under System Settings › General › Login Items, then return to Milo. This is a one-time step."
                case .failed(let message):
                    appState.privilegeError = message
                }
            }
        }
    }

    func refreshHelperStatus() {
        helperStatus = PrivilegeManager.shared.status
        if helperStatus.isEnabled {
            privilegeError = nil
        }
    }

    func openHelperApprovalSettings() {
        PrivilegeManager.shared.openApprovalSettings()
    }

    func removeHelper() {
        PrivilegeManager.shared.removePrivileges { [weak self] success in
            guard let self else {
                return
            }
            refreshHelperStatus()
            privilegeError = success ? nil : "Milo could not unregister its background helper."
        }
    }

    func deferFirstLaunchPrivilegePrompt() {
        SettingsManager.shared.privilegeOnboardingPrompted = true
        showingFirstLaunchPrivilegePrompt = false
    }

    private func prepareFirstLaunchPrivilegePrompt() {
        guard !SettingsManager.shared.privilegeOnboardingPrompted,
              !helperStatus.isEnabled else {
            return
        }
        showingFirstLaunchPrivilegePrompt = true
    }

    func refreshLaunchItems() {
        self.detectedLaunchItems = ProcessManager.shared.scanForLaunchItems()
    }

    func scanProcesses() {
        scanWorker?.cancel()
        scanCompletionTask?.cancel()

        let startedAt = Date()
        let context = scanLifecycle.begin(
            operation: .scan,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(15)
        )
        scanState = scanLifecycle.state

        let processManager = ProcessManager.shared
        // NSWorkspace and the protected list are main-actor state, so they are read here and
        // handed to the detached worker rather than reached for from inside it.
        let options = ProcessScanOptions(
            includesDiscovery: showsDiscovery,
            foregroundApplicationPIDs: ProcessSafetyInspector.shared.foregroundApplicationPIDs(),
            protectedProcessNames: Set(WhitelistManager.shared.getWhitelistedProcesses())
        )
        let previousSelection = Set(discoveredProcesses.filter(\.isSelected).map(\.pid))

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try processManager.scanForRunningTargetsWithResources(options: options)
            let launchItems = processManager.scanForLaunchItems()
            try Task.checkCancellation()
            // A rescan must not silently drop a selection the user made moments ago.
            let discovered = result.discovered.map { process -> DiscoveredProcess in
                guard previousSelection.contains(process.pid), process.isActionable else {
                    return process
                }
                var restored = process
                restored.isSelected = true
                return restored
            }
            return ProcessScanSnapshot(
                bloat: result.bloat,
                intelligence: result.intelligence,
                discovered: discovered,
                launchItems: launchItems,
                completedAt: Date()
            )
        }
        scanWorker = worker
        scanCompletionTask = Task { [weak self] in
            let result = await worker.result
            guard let self else {
                return
            }
            finishScan(result, context: context)
        }
    }

    private func finishScan(
        _ result: Result<ProcessScanSnapshot, Error>,
        context: MiloOperationContext
    ) {
        switch result {
        case .success(let snapshot):
            guard scanLifecycle.succeed(snapshot, for: context) else {
                return
            }
            let previousCount = totalBloatCount
            activeBloat = snapshot.bloat
            activeIntelligence = snapshot.intelligence
            discoveredProcesses = snapshot.discovered
            detectedLaunchItems = snapshot.launchItems
            lastScanDate = snapshot.completedAt
            scanState = scanLifecycle.state

            let newCount = totalBloatCount
            postCurrentBloatCount()
            if SettingsManager.shared.notifyOnDetection && newCount > previousCount {
                sendBloatNotification(count: newCount)
            }
        case .failure(let error) where error is CancellationError:
            if scanLifecycle.cancel(context) {
                scanState = scanLifecycle.state
            }
        case .failure(let error):
            let failure = error as? MiloOperationFailure ?? MiloOperationFailure(
                operation: .scan,
                code: .unknown,
                message: "Milo could not complete the process scan.",
                recovery: "Try scanning again. If the problem continues, restart Milo."
            )
            if scanLifecycle.fail(failure, for: context) {
                scanState = scanLifecycle.state
            }
        }
    }

    func requestKill() {
        requestKill(items: selectedForKill)
    }

    private func requestKill(items: [ProcessItem]) {
        guard !items.isEmpty else { return }
        pendingKillItems = items
        if SettingsManager.shared.confirmBeforeKill {
            showingKillConfirmation = true
        } else {
            confirmKill()
        }
    }

    // MARK: - Auto-Scan

    func configureAutoScan(interval: Int) {
        autoScanTimer?.invalidate()
        autoScanTimer = nil
        guard interval > 0 else { return }
        autoScanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Self.runOnMain {
                self?.scanProcesses()
                self?.refreshMemoryStats()
            }
        }
    }

    func handleSurfaceOpened() {
        refreshHelperStatus()
        if SettingsManager.shared.autoScanOnOpen {
            scanProcesses()
            refreshMemoryStats()
        }

        configureAutoScan(interval: SettingsManager.shared.autoScanInterval)
    }

    func handleSurfaceClosed() {
        autoScanTimer?.invalidate()
        autoScanTimer = nil
    }

    func postCurrentBloatCount() {
        NotificationCenter.default.post(name: .miloBloatCountChanged, object: totalBloatCount)
    }

    func confirmKill() {
        let toKill = pendingKillItems.isEmpty ? selectedForKill : pendingKillItems
        guard !toKill.isEmpty else {
            showingKillConfirmation = false
            return
        }
        if toKill.contains(where: { ProcessManager.shared.requiresPrivilegedHelper(for: $0) }),
           !helperStatus.isEnabled {
            showingKillConfirmation = false
            showingHelperRequiredAlert = true
            return
        }
        showingKillConfirmation = false
        isKilling = true

        ProcessManager.shared.killProcessesGracefully(items: toKill) { [weak self] results in
            Self.runOnMain {
                guard let appState = self else { return }
                appState.pendingKillItems = []

                let successfulKills = results.filter { $0.success }.map(\.name)
                let killedProcesses = toKill.filter { successfulKills.contains($0.name) }
                StatsManager.shared.recordKills(killedProcesses)

                appState.lastKillResults = results
                appState.showingResults = true
                appState.isKilling = false
                appState.stats = StatsManager.shared.getStats()

                Self.runOnMain(after: 1.5) {
                    appState.scanProcesses()
                    appState.refreshMemoryStats()
                    Self.runOnMain(after: 3.0) {
                        appState.showingResults = false
                    }
                }
            }
        }
    }

    func cancelKill() {
        pendingKillItems = []
        pendingDiscovered = []
        showingKillConfirmation = false
        showingDiscoveryKillConfirmation = false
    }

    // MARK: - Discovered Processes

    func setShowsDiscovery(_ enabled: Bool) {
        showsDiscovery = enabled
        SettingsManager.shared.showsDiscovery = enabled
        if !enabled {
            discoveredProcesses = []
        }
        scanProcesses()
    }

    func setShowsProtectedProcesses(_ enabled: Bool) {
        showsProtectedProcesses = enabled
        SettingsManager.shared.showsProtectedProcesses = enabled
    }

    func requestKillDiscovered() {
        let selected = selectedDiscovered
        guard !selected.isEmpty else { return }

        if selected.contains(where: \.requiresPrivilegedHelper), !helperStatus.isEnabled {
            showingHelperRequiredAlert = true
            return
        }

        pendingDiscovered = selected
        // Discovery reaches processes Milo ships no reviewed opinion about, so the
        // confirmation is always shown — the "don't ask again" preference covers catalogued
        // targets, where Milo knows what the process is and that it comes back.
        showingDiscoveryKillConfirmation = true
    }

    func confirmKillDiscovered() {
        let targets = pendingDiscovered
        showingDiscoveryKillConfirmation = false
        guard !targets.isEmpty else { return }
        isKilling = true

        ProcessManager.shared.terminateDiscoveredProcesses(targets) { [weak self] results in
            Self.runOnMain {
                guard let appState = self else { return }
                appState.pendingDiscovered = []
                appState.lastKillResults = results
                appState.showingResults = true
                appState.isKilling = false

                Self.runOnMain(after: 1.5) {
                    appState.scanProcesses()
                    appState.refreshMemoryStats()
                    Self.runOnMain(after: 3.0) {
                        appState.showingResults = false
                    }
                }
            }
        }
    }

    func selectAllDiscovered(_ selected: Bool) {
        for index in discoveredProcesses.indices where discoveredProcesses[index].isActionable {
            discoveredProcesses[index].isSelected = selected
        }
    }

    func protectDiscovered(_ process: DiscoveredProcess) {
        addToWhitelist(process.name)
        scanProcesses()
    }

    // MARK: - Vendor Quick Kill

    func killVendor(_ vendor: String) {
        let vendorProcesses = activeBloat.filter { $0.vendor == vendor && !WhitelistManager.shared.isWhitelisted($0.name) }
        guard !vendorProcesses.isEmpty else { return }
        requestKill(items: vendorProcesses)
    }

    /// Kill all detected processes at once
    func killAllDetected() {
        requestKill(items: visibleBloat + visibleIntelligence)
    }

    func toggleLaunchItem(_ item: LaunchItem) {
        if ProcessManager.shared.requiresPrivilegedHelper(forLaunchItem: item),
           !helperStatus.isEnabled {
            showingHelperRequiredAlert = true
            return
        }
        let newState = !item.isLoaded
        ProcessManager.shared.toggleLaunchItem(path: item.path, enable: newState)

        // Give launchctl time to process, then refresh
        Self.runOnMain(after: 1.0) {
            self.refreshLaunchItems()
        }
    }

    func selectAll(_ selected: Bool) {
        for i in activeBloat.indices {
            activeBloat[i].isSelected = selected
        }
        for i in activeIntelligence.indices {
            activeIntelligence[i].isSelected = selected
        }
    }

    // MARK: - Memory Management

    func refreshMemoryStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let stats = MemoryManager.shared.getMemoryStats() {
                guard let appState = self else { return }
                Self.runOnMain {
                    appState.memoryStats = stats
                }
            }
        }
    }

    func purgeMemory() {
        guard helperStatus.isEnabled else {
            showingHelperRequiredAlert = true
            return
        }
        isPurgingMemory = true
        MemoryManager.shared.purgeMemory { [weak self] success, message in
            Self.runOnMain {
                guard let appState = self else { return }
                appState.isPurgingMemory = false
                appState.memoryMessage = message
                appState.showingMemoryMessage = true

                if success {
                    Self.runOnMain(after: 1.0) {
                        appState.refreshMemoryStats()
                    }
                }

                Self.runOnMain(after: 3.0) {
                    appState.showingMemoryMessage = false
                }
            }
        }
    }

    func requestClearUserCaches() {
        showingCacheConfirmation = true
    }

    func confirmClearUserCaches() {
        showingCacheConfirmation = false
        isClearingCaches = true
        MemoryManager.shared.clearUserCaches { [weak self] _, message in
            Self.runOnMain {
                guard let appState = self else { return }
                appState.isClearingCaches = false
                appState.memoryMessage = message
                appState.showingMemoryMessage = true

                Self.runOnMain(after: 3.0) {
                    appState.showingMemoryMessage = false
                }
            }
        }
    }

    func flushDNS() {
        guard helperStatus.isEnabled else {
            showingHelperRequiredAlert = true
            return
        }
        isFlushingDNS = true
        MemoryManager.shared.clearDNSCache { [weak self] _, message in
            Self.runOnMain {
                guard let appState = self else { return }
                appState.isFlushingDNS = false
                appState.memoryMessage = message
                appState.showingMemoryMessage = true

                Self.runOnMain(after: 3.0) {
                    appState.showingMemoryMessage = false
                }
            }
        }
    }

    // MARK: - Whitelist Management

    func addToWhitelist(_ processName: String) {
        WhitelistManager.shared.addToWhitelist(processName)
        scanProcesses()
    }

    func removeFromWhitelist(_ processName: String) {
        WhitelistManager.shared.removeFromWhitelist(processName)
        scanProcesses()
    }

    func isWhitelisted(_ processName: String) -> Bool {
        return WhitelistManager.shared.isWhitelisted(processName)
    }

    // MARK: - Stats

    func refreshStats() {
        stats = StatsManager.shared.getStats()
    }

    func resetStats() {
        StatsManager.shared.reset()
        stats = StatsManager.shared.getStats()
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendBloatNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Milo"
        content.body = "\(count) bloat process\(count == 1 ? "" : "es") detected"
        content.sound = .default

        let request = UNNotificationRequest(identifier: "bloat-detected-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Export

    func exportStatsReport() -> String {
        let currentStats = stats
        var lines: [String] = []
        lines.append("# Milo Statistics Report")
        lines.append("Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))")
        lines.append("")
        lines.append("## Summary")
        lines.append("- Total processes killed: \(currentStats.totalProcessesKilled)")
        lines.append("- Total RAM freed: \(String(format: "%.1f GB", currentStats.totalRAMSavedMB / 1024))")
        lines.append("- Estimated battery saved: \(String(format: "~%.1f hours", currentStats.estimatedBatteryHoursSaved))")
        lines.append("")

        if !currentStats.killedProcessesByVendor.isEmpty {
            lines.append("## Kills by Vendor")
            for (vendor, count) in currentStats.killedProcessesByVendor.sorted(by: { $0.value > $1.value }) {
                lines.append("- \(vendor): \(count)")
            }
            lines.append("")
        }

        if !currentStats.topMemoryHogs.isEmpty {
            lines.append("## Top Memory Hogs")
            for hog in currentStats.topMemoryHogs.prefix(10) {
                lines.append("- \(hog.processName) (\(hog.vendor)): \(String(format: "%.0f MB", hog.memoryMB))")
            }
            lines.append("")
        }

        if let first = currentStats.firstKillDate, let last = currentStats.lastKillDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            lines.append("## Timeline")
            lines.append("- First kill: \(fmt.string(from: first))")
            lines.append("- Latest kill: \(fmt.string(from: last))")
        }

        return lines.joined(separator: "\n")
    }

    func saveStatsReport() {
        let report = exportStatsReport()
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let filename = "Milo-Report-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).md"
        let url = desktop.appendingPathComponent(filename)

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            memoryMessage = "Report saved to Desktop"
            showingMemoryMessage = true
            Self.runOnMain(after: 3.0) { [weak self] in
                self?.showingMemoryMessage = false
            }
        } catch {
            memoryMessage = "Failed to save report"
            showingMemoryMessage = true
            Self.runOnMain(after: 3.0) { [weak self] in
                self?.showingMemoryMessage = false
            }
        }
    }
}
