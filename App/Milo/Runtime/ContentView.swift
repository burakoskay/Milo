import SwiftUI
import AppKit

private enum ContentSheet: String, Identifiable {
    case stats
    case whitelist
    case debloat
    case settings

    var id: String { rawValue }
}

private struct SectionHeader: View {
    let title: String
    let count: Int?
    let symbol: String
    var onKillAll: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let onKillAll {
                Button {
                    onKillAll()
                } label: {
                    Text("Kill All")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .accessibilityLabel("Kill all \(title) processes")
            }
        }
    }
}

private struct ProcessRow: View {
    let name: String
    let description: String?
    let cpuUsage: Double
    let memoryMB: Double
    let isLaunchdManaged: Bool
    let isSystemProcess: Bool
    @Binding var isSelected: Bool
    var onWhitelist: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isLaunchdManaged {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 9))
                            Text(isSystemProcess ? "System" : "Daemon")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSystemProcess ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                        )
                        .foregroundStyle(isSystemProcess ? .red : .blue)
                        .help(isSystemProcess ? "System process — respawns unless SIP is disabled" : "Launchd daemon — will be disabled")
                    }
                }

                HStack(spacing: 8) {
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 4) {
                        if cpuUsage >= 0 {
                            ResourceBadge(icon: "cpu", value: String(format: "%.1f%%", cpuUsage), isHigh: cpuUsage > 10)
                        }
                        if memoryMB >= 0 {
                            ResourceBadge(icon: "memorychip", value: String(format: "%.0fMB", memoryMB), isHigh: memoryMB > 100)
                        }
                    }
                }
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(description.map { "\(name), \($0)" } ?? name))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .hoverHighlight()
        .contextMenu {
            Button {
                onWhitelist?()
            } label: {
                Label("Don't Show Again", systemImage: "eye.slash")
            }
        }
    }
}

struct ResourceBadge: View {
    let icon: String
    let value: String
    let isHigh: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isHigh ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.1))
        )
        .foregroundStyle(isHigh ? .orange : .secondary)
    }
}

private struct SIPPill: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isEnabled ? Color.red : Color.green)
                .frame(width: 7, height: 7)
            Text(isEnabled ? "SIP Enabled" : "SIP Disabled")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

private struct ResultsToast: View {
    let results: [KillResult]
    let isSIPEnabled: Bool

    var successCount: Int { results.filter { $0.success }.count }
    var failCount: Int { results.filter { !$0.success }.count }
    var systemProcessCount: Int { results.filter { $0.requiresSIPDisabled && isSIPEnabled }.count }

    var body: some View {
        Group {
            if systemProcessCount > 0 {
                ToastView(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    message: "Killed \(successCount) process\(successCount == 1 ? "" : "es")",
                    detail: "\(systemProcessCount) system process\(systemProcessCount == 1 ? "" : "es") will respawn (SIP enabled)"
                )
            } else if failCount == 0 {
                ToastView(
                    icon: "checkmark.circle.fill",
                    iconColor: .green,
                    message: "Killed \(successCount) process\(successCount == 1 ? "" : "es")"
                )
            } else {
                ToastView(
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    message: "\(successCount) killed, \(failCount) failed",
                    detail: results.filter { !$0.success }.map { $0.name }.joined(separator: ", ")
                )
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var activeSheet: ContentSheet?
    @State private var showPaywall: Bool = false

    @AppStorage("Milo.appThemeColor") var appThemeColor: String = "System"

    private var isKillDisabled: Bool {
        appState.selectedForKill.isEmpty || appState.isKilling
    }

    private var tintColorOverride: Color? {
        switch appThemeColor {
        case "Blue": return .blue
        case "Purple": return .purple
        case "Pink": return .pink
        case "Red": return .red
        case "Orange": return .orange
        case "Yellow": return .yellow
        case "Green": return .green
        case "Gray": return .gray
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            VisualEffectBlur()
                .ignoresSafeArea()

            VStack(spacing: 12) {
                header

                ScrollView {
                    VStack(spacing: 12) {
                        if appState.showMemoryInHeader {
                            memoryCard
                        }
                        processCards
                        launchItemsCard
                    }
                    .padding(12)
                }

                footer
            }
            .padding(10)

            // Results toast overlay
            if appState.showingResults {
                VStack {
                    Spacer()
                    ResultsToast(results: appState.lastKillResults, isSIPEnabled: appState.isSIPEnabled)
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: appState.showingResults)
            }

            // Memory/general message toast
            if appState.showingMemoryMessage {
                VStack {
                    Spacer()
                    ToastView(
                        icon: appState.memoryMessage.contains("Failed") || appState.memoryMessage.contains("Error") ? "xmark.circle.fill" : "checkmark.circle.fill",
                        iconColor: appState.memoryMessage.contains("Failed") || appState.memoryMessage.contains("Error") ? .red : .green,
                        message: appState.memoryMessage
                    )
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.4), value: appState.showingMemoryMessage)
            }
        }
        .frame(width: 360, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MiloOpenSettings"))) { _ in
            activeSheet = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MiloPopoverWillOpen"))) { _ in
            appState.handlePopoverOpened()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MiloPopoverDidClose"))) { _ in
            appState.handlePopoverClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MiloRequestCurrentBloatCount"))) { _ in
            appState.postCurrentBloatCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MiloCloudSignaturesChanged"))) { _ in
            appState.scanProcesses()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                StatsView(appState: appState)
            case .whitelist:
                WhitelistView(appState: appState)
            case .debloat:
                DebloatView(appState: appState, manager: DebloatManager.shared)
            case .settings:
                SettingsView(appState: appState)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .alert("Confirm Kill", isPresented: $appState.showingKillConfirmation) {
            Button("Cancel", role: .cancel) {
                appState.cancelKill()
            }
            Button("Kill \(appState.pendingKillCount) Process\(appState.pendingKillCount == 1 ? "" : "es")", role: .destructive) {
                appState.confirmKill()
            }
        } message: {
            Text("This will terminate the requested processes. Some apps may lose unsaved data.")
        }
        .alert("Clear User Caches?", isPresented: $appState.showingCacheConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear Caches", role: .destructive) {
                appState.confirmClearUserCaches()
            }
        } message: {
            Text("This removes cached files from your user Library Caches folder. Apps may rebuild caches the next time they open.")
        }
        .alert("Enable Faster Privileged Actions?", isPresented: $appState.showingFirstLaunchPrivilegePrompt) {
            Button("Later", role: .cancel) {
                appState.deferFirstLaunchPrivilegePrompt()
            }
            Button("Enable") {
                appState.setupPrivileges()
            }
        } message: {
            Text("Milo can install a narrow sudoers rule for cache, DNS, Spotlight, and memory maintenance. Process termination still uses explicit per-action approval when macOS requires administrator privileges.")
        }
        // Keyboard shortcuts
        .background(
            Group {
                Button("") { handleKillRequest() }
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)

                Button("") { appState.scanProcesses() }
                    .keyboardShortcut("r", modifiers: .command)
                    .opacity(0)

                Button("") { appState.selectAll(appState.selectedForKill.isEmpty) }
                    .keyboardShortcut("a", modifiers: .command)
                    .opacity(0)

                Button("") { activeSheet = .settings }
                    .keyboardShortcut(",", modifiers: .command)
                    .opacity(0)

                Button("") {
                    if licenseManager.isSubscribed {
                        appState.killAllDetected()
                    } else {
                        showPaywall = true
                    }
                }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .opacity(0)
            }
        )
        .tint(tintColorOverride)
    }

    private func handleKillRequest() {
        if licenseManager.isSubscribed {
            appState.requestKill()
        } else {
            showPaywall = true
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if let imagePath = Bundle.main.path(forResource: NSApp.effectiveAppearance.name == .darkAqua ? "milo_white" : "milo_black", ofType: "png"),
                       let nsImage = NSImage(contentsOfFile: imagePath) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Milo")
                        .font(.headline)
                        .lineLimit(1)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()

                Spacer()

                Picker("", selection: $appState.sortOrder) {
                    ForEach(ProcessSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 78)
                .controlSize(.small)

                SIPPill(isEnabled: appState.isSIPEnabled)

                Button {
                    appState.scanProcesses()
                } label: {
                    if appState.isScanning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Rescan (⌘R)")
                .accessibilityLabel("Rescan processes")
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(appState.isScanning)
            }

            // Resource summary bar
            if appState.totalBloatCount > 0 {
                HStack(spacing: 12) {
                    Label("\(appState.totalBloatCount) processes", systemImage: "cpu")
                    Label(String(format: "%.1f%% CPU", appState.totalCPUUsage), systemImage: "gauge.medium")
                    Label(String(format: "%.0f MB", appState.totalMemoryMB), systemImage: "memorychip")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var memoryCard: some View {
        if let memory = appState.memoryStats {
            GlassCard {
                HStack(spacing: 8) {
                    Image(systemName: "memorychip.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                    Text("Memory")
                        .font(.headline)
                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(memory.memoryPressure.color)
                            .frame(width: 6, height: 6)
                        Text(memory.memoryPressure.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.35)

                VStack(spacing: 8) {
                    HStack {
                        Text("Used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f / %.1f GB (%.0f%%)",
                                    memory.wiredGB + memory.activeGB + memory.compressedGB,
                                    memory.totalGB,
                                    memory.usedPercentage))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary.opacity(0.5))

                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(
                                    colors: memory.usedPercentage > 85 ? [.red, .orange] :
                                            memory.usedPercentage > 70 ? [.yellow, .orange] :
                                            [.blue, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: geometry.size.width * min(memory.usedPercentage / 100, 1.0))
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 8) {
                        Button {
                            appState.purgeMemory()
                        } label: {
                            HStack(spacing: 4) {
                                if appState.isPurgingMemory {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text("Purge")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Purge inactive memory")
                        .accessibilityLabel("Purge inactive memory")
                        .disabled(appState.isPurgingMemory)

                        Button {
                            appState.requestClearUserCaches()
                        } label: {
                            HStack(spacing: 4) {
                                if appState.isClearingCaches {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "trash")
                                }
                                Text("Caches")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Clear user caches")
                        .accessibilityLabel("Clear user caches")
                        .disabled(appState.isClearingCaches)

                        Button {
                            appState.flushDNS()
                        } label: {
                            HStack(spacing: 4) {
                                if appState.isFlushingDNS {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("DNS")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Flush DNS cache")
                        .accessibilityLabel("Flush DNS cache")
                        .disabled(appState.isFlushingDNS)

                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var processCards: some View {
        if appState.visibleBloat.isEmpty && appState.visibleIntelligence.isEmpty {
            GlassCard {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)

                    Text("Your system is clean")
                        .font(.headline)

                    Text("No target processes are currently running.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let lastScan = appState.lastScanDate {
                        Text("Last scanned \(lastScan, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        } else {
            if !appState.visibleBloat.isEmpty {
                let vendors = appState.bloatByVendor.keys.sorted()

                ForEach(vendors, id: \.self) { vendor in
                    let items = appState.bloatByVendor[vendor] ?? []
                    GlassCard {
                        SectionHeader(
                            title: vendor,
                            count: items.count,
                            symbol: vendorSymbol(for: vendor),
                            onKillAll: { appState.killVendor(vendor) }
                        )
                        Divider().opacity(0.35)
                        VStack(spacing: 4) {
                            ForEach(items) { item in
                                ProcessRow(
                                    name: item.name,
                                    description: item.description,
                                    cpuUsage: item.cpuUsage,
                                    memoryMB: item.memoryMB,
                                    isLaunchdManaged: item.isLaunchdManaged,
                                    isSystemProcess: item.isSystemProcess,
                                    isSelected: appState.bloatSelectionBinding(for: item.id),
                                    onWhitelist: { appState.addToWhitelist(item.name) }
                                )
                            }
                        }
                    }
                }
            }

            if !appState.visibleIntelligence.isEmpty {
                GlassCard {
                    SectionHeader(title: "Apple Intelligence", count: appState.visibleIntelligence.count, symbol: "waveform.circle.fill")
                    Divider().opacity(0.35)
                    VStack(spacing: 4) {
                        ForEach(appState.visibleIntelligence) { item in
                            ProcessRow(
                                name: item.name,
                                description: item.description,
                                cpuUsage: item.cpuUsage,
                                memoryMB: item.memoryMB,
                                isLaunchdManaged: item.isLaunchdManaged,
                                isSystemProcess: item.isSystemProcess,
                                isSelected: appState.intelligenceSelectionBinding(for: item.id),
                                onWhitelist: { appState.addToWhitelist(item.name) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func vendorSymbol(for vendor: String) -> String {
        switch vendor.lowercased() {
        case "adobe": return "paintbrush"
        case "microsoft": return "window.shade.closed"
        case "google": return "globe"
        case "spotify": return "music.note"
        case "dropbox": return "externaldrive.badge.icloud"
        case "zoom": return "video"
        case "slack": return "message"
        case "figma": return "square.on.square"
        case "notion": return "doc.text"
        case "discord": return "gamecontroller"
        case "ilok", "pace", "avid": return "music.note.house"
        default: return "waveform.path.ecg"
        }
    }

    @ViewBuilder
    private var launchItemsCard: some View {
        if !appState.visibleLaunchItems.isEmpty {
            GlassCard {
                SectionHeader(title: "Persistent Launch Items", count: appState.visibleLaunchItems.count, symbol: "bolt.fill")
                Divider().opacity(0.35)

                VStack(spacing: 10) {
                    ForEach(appState.visibleLaunchItems, id: \.self) { item in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if let desc = item.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Text(item.isLoaded ? "Running" : "Stopped")
                                    .font(.system(size: 10))
                                    .foregroundStyle(item.isLoaded ? .green : .secondary)
                            }
                            Spacer(minLength: 12)
                            Button(item.isLoaded ? "Disable" : "Enable") {
                                appState.toggleLaunchItem(item)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("\(item.isLoaded ? "Disable" : "Enable") \(item.label)")
                        }
                        .hoverHighlight()
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // Selection summary
            if !appState.selectedForKill.isEmpty {
                HStack(spacing: 12) {
                    Text("\(appState.selectedForKill.count) selected")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(format: "%.1f%% CPU", appState.selectedCPUUsage))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f MB", appState.selectedMemoryMB))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Kill button
            Button(role: .destructive) {
                handleKillRequest()
            } label: {
                HStack(spacing: 8) {
                    if appState.isKilling {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                    Text("Kill Selected")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isKillDisabled)
            .help("Kill selected processes (⌘K)")
            .accessibilityLabel("Kill selected processes")

            // Bottom row: tool buttons
            HStack(spacing: 8) {
                Button {
                    activeSheet = .stats
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("View Statistics")
                .accessibilityLabel("View statistics")

                Button {
                    activeSheet = .whitelist
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Manage Hidden Processes")
                .accessibilityLabel("Manage hidden processes")

                Button {
                    activeSheet = .debloat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Debloat")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("System Debloat")
                .accessibilityLabel("Open system debloat")

                Spacer()

                Button {
                    activeSheet = .settings
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Settings (⌘,)")
                .accessibilityLabel("Open settings")

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}
