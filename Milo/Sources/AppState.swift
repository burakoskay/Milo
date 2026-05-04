import Foundation
import SwiftUI
import Combine
import UserNotifications

// MARK: - Sort Options

enum ProcessSortOrder: String, CaseIterable {
    case name = "Name"
    case cpuDesc = "CPU"
    case memoryDesc = "Memory"
}

struct ProcessItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String?
    let vendor: String
    let cpuUsage: Double      // percentage
    let memoryMB: Double      // megabytes
    let isLaunchdManaged: Bool  // Will respawn if just killed
    let isSystemProcess: Bool   // Requires SIP disabled to permanently stop
    var matchedPIDs: Set<Int32> = []
    var telemetryRuleID: String?
    var terminationStrategy: TelemetryTerminationStrategy?
    var launchdLabel: String?
    var launchdDomain: TelemetryLaunchdDomain?
    var isSelected: Bool = false
}

struct KillResult: Identifiable {
    let id = UUID()
    let name: String
    let success: Bool
    let isLaunchdManaged: Bool
    let requiresSIPDisabled: Bool

    init(name: String, success: Bool, isLaunchdManaged: Bool = false, requiresSIPDisabled: Bool = false) {
        self.name = name
        self.success = success
        self.isLaunchdManaged = isLaunchdManaged
        self.requiresSIPDisabled = requiresSIPDisabled
    }
}

class AppState: ObservableObject {
    @Published var isSIPEnabled: Bool = true
    @Published var detectedLaunchItems: [LaunchItem] = []

    @Published var activeBloat: [ProcessItem] = []
    @Published var activeIntelligence: [ProcessItem] = []

    @Published var showingKillConfirmation: Bool = false
    @Published var lastKillResults: [KillResult] = []
    @Published var showingResults: Bool = false

    // Scanning state
    @Published var isScanning: Bool = false
    @Published var lastScanDate: Date?

    // Sort order
    @Published var sortOrder: ProcessSortOrder = .name

    // Privilege setup
    @Published var isConfiguringPrivileges: Bool = false
    @Published var privilegeError: String?

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

    var whitelistedProcesses: [String] {
        WhitelistManager.shared.getWhitelistedProcesses()
    }

    // Computed: total bloat count for badge (excluding whitelisted)
    var totalBloatCount: Int {
        visibleBloat.count + visibleIntelligence.count
    }

    // Check if passwordless mode is configured
    var isPasswordlessConfigured: Bool {
        PrivilegeManager.shared.isConfigured
    }

    // Total resource usage of detected bloat
    var totalCPUUsage: Double {
        (visibleBloat + visibleIntelligence).reduce(0) { $0 + $1.cpuUsage }
    }

    var totalMemoryMB: Double {
        (visibleBloat + visibleIntelligence).reduce(0) { $0 + $1.memoryMB }
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

    init() {
        self.isSIPEnabled = SIPChecker.isSIPEnabled()
        self.refreshLaunchItems()
        self.scanProcesses()
        self.refreshMemoryStats()

        if !CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-destructive") {
            SettingsManager.shared.syncLoginItemState()
        }

        // Request notification permission if notifications are enabled
        if SettingsManager.shared.notifyOnDetection {
            requestNotificationPermission()
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
        PrivilegeManager.shared.configurePrivileges { [weak self] success in
            DispatchQueue.main.async {
                self?.isConfiguringPrivileges = false
                if success {
                    self?.privilegeError = nil
                } else {
                    self?.privilegeError = "Failed to configure privileges. Ensure you entered your password correctly."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self?.privilegeError = nil
                    }
                }
            }
        }
    }

    func refreshLaunchItems() {
        self.detectedLaunchItems = ProcessManager.shared.scanForLaunchItems()
    }

    func scanProcesses() {
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (bloat, intel) = ProcessManager.shared.scanForRunningTargetsWithResources()

            DispatchQueue.main.async {
                guard let self = self else { return }

                let previousCount = self.totalBloatCount

                self.activeBloat = bloat
                self.activeIntelligence = intel
                self.refreshLaunchItems()
                self.isScanning = false
                self.lastScanDate = Date()

                let newCount = self.totalBloatCount
                self.postCurrentBloatCount()

                // Send notification if new bloat appeared
                if SettingsManager.shared.notifyOnDetection && newCount > previousCount {
                    self.sendBloatNotification(count: newCount)
                }

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
            self?.scanProcesses()
            self?.refreshMemoryStats()
        }
    }

    func handlePopoverOpened() {
        if SettingsManager.shared.autoScanOnOpen {
            scanProcesses()
            refreshMemoryStats()
        }

        let interval = SettingsManager.shared.autoScanInterval
        if interval > 0 {
            configureAutoScan(interval: interval)
        }
    }

    func handlePopoverClosed() {
        autoScanTimer?.invalidate()
        autoScanTimer = nil
    }

    func postCurrentBloatCount() {
        NotificationCenter.default.post(name: .init("MiloBloatCountChanged"), object: totalBloatCount)
    }

    func confirmKill() {
        let toKill = pendingKillItems.isEmpty ? selectedForKill : pendingKillItems
        guard !toKill.isEmpty else {
            showingKillConfirmation = false
            return
        }
        showingKillConfirmation = false
        isKilling = true

        ProcessManager.shared.killProcessesGracefully(items: toKill) { [weak self] results in
            guard let self = self else { return }
            self.pendingKillItems = []

            // Record stats for successful kills
            let successfulKills = results.filter { $0.success }.map { $0.name }
            let killedProcesses = toKill.filter { successfulKills.contains($0.name) }
            StatsManager.shared.recordKills(killedProcesses)

            self.lastKillResults = results
            self.showingResults = true
            self.isKilling = false
            self.stats = StatsManager.shared.getStats()

            // Re-scan after a short delay to update UI
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.scanProcesses()
                self.refreshMemoryStats()
                // Auto-hide results after showing
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.showingResults = false
                }
            }
        }
    }

    func cancelKill() {
        pendingKillItems = []
        showingKillConfirmation = false
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
        let newState = !item.isLoaded
        ProcessManager.shared.toggleLaunchItem(path: item.path, enable: newState)

        // Give launchctl time to process, then refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
                DispatchQueue.main.async {
                    self?.memoryStats = stats
                }
            }
        }
    }

    func purgeMemory() {
        isPurgingMemory = true
        MemoryManager.shared.purgeMemory { [weak self] success, message in
            self?.isPurgingMemory = false
            self?.memoryMessage = message
            self?.showingMemoryMessage = true

            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.refreshMemoryStats()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.showingMemoryMessage = false
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
            self?.isClearingCaches = false
            self?.memoryMessage = message
            self?.showingMemoryMessage = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.showingMemoryMessage = false
            }
        }
    }

    func flushDNS() {
        isFlushingDNS = true
        MemoryManager.shared.clearDNSCache { [weak self] _, message in
            self?.isFlushingDNS = false
            self?.memoryMessage = message
            self?.showingMemoryMessage = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self?.showingMemoryMessage = false
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
        lines.append("- Estimated tracking events interrupted: ~\(currentStats.estimatedTrackingEventsInterrupted)")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.showingMemoryMessage = false
            }
        } catch {
            memoryMessage = "Failed to save report"
            showingMemoryMessage = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.showingMemoryMessage = false
            }
        }
    }
}
