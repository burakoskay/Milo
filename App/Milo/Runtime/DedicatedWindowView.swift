import SwiftUI

// MARK: - Tab Enumeration

enum WindowTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case debloat = "System Tuning"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .debloat: return "wand.and.stars"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum WindowSheet: String, Identifiable {
    case stats
    case whitelist

    var id: String { rawValue }
}

// MARK: - Dedicated Window Root

struct DedicatedWindowView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updateManager: MiloUpdateManager
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var debloatManager = DebloatManager.shared
    @State private var selectedTab: WindowTab = .home
    @State private var showPaywall: Bool = false
    @State private var activeSheet: WindowSheet?
    @Namespace private var tabAnimation

    @AppStorage("Milo.appThemeColor") var appThemeColor: String = "System"

    private var hasProAccess: Bool {
        MiloBuildMode.isDevelopmentPreview || licenseManager.isSubscribed
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
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if MiloBuildMode.isDevelopmentPreview, !appState.helperStatus.isEnabled {
                BackgroundHelperBanner(
                    status: appState.helperStatus,
                    enable: appState.setupPrivileges,
                    openSettings: appState.openHelperApprovalSettings
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            // Content area — fills remaining space
            Group {
                switch selectedTab {
                case .home:
                    homeContent
                case .debloat:
                    DebloatView(appState: appState, manager: debloatManager, isEmbedded: true)
                case .settings:
                    SettingsView(appState: appState, updateManager: updateManager, isEmbedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 520)
        .background(VisualEffectBlur().ignoresSafeArea())
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .stats:
                StatsView(appState: appState)
            case .whitelist:
                WhitelistView(appState: appState)
            }
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
        .alert("Enable Milo Background Helper?", isPresented: $appState.showingFirstLaunchPrivilegePrompt) {
            Button("Later", role: .cancel) {
                appState.deferFirstLaunchPrivilegePrompt()
            }
            Button("Enable") {
                appState.setupPrivileges()
            }
        } message: {
            Text("Milo uses one narrowly scoped background helper for system-level actions. macOS may ask you to approve Milo once in Login Items.")
        }
        .alert("Background Helper Required", isPresented: $appState.showingHelperRequiredAlert) {
            Button("Not Now", role: .cancel) {}
            Button("Enable Helper") {
                appState.setupPrivileges()
            }
        } message: {
            Text("This action needs Milo's approved background helper. Enabling it is a one-time macOS permission step.")
        }
        .tint(tintColorOverride)
        .onReceive(NotificationCenter.default.publisher(for: .miloOpenSettings)) { _ in
            selectedTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .miloSurfaceDidOpen)) { _ in
            appState.handleSurfaceOpened()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miloSurfaceDidClose)) { _ in
            appState.handleSurfaceClosed()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miloSurfaceDidActivate)) { _ in
            appState.refreshHelperStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miloRequestCurrentBloatCount)) { _ in
            appState.postCurrentBloatCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .miloCloudSignaturesChanged)) { _ in
            appState.scanProcesses()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // Space for macOS traffic light buttons
            Spacer().frame(width: 70)

            // Left: Milo colored logo
            if let imagePath = Bundle.main.path(forResource: "milo_color", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
            } else {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }

            if MiloBuildMode.isDevelopmentPreview {
                Text("Public Preview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }

            Spacer()

            // Center: Animated tab bar
            animatedTabBar

            Spacer()

            // Only the rescan control lives here. Everything else moved to the bottom bar:
            // crowding this row squeezed the tab bar until its labels wrapped one letter per line.
            Button {
                appState.scanProcesses()
            } label: {
                if appState.isScanning {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appState.isScanning)
            .help("Rescan (⌘R)")
            .accessibilityLabel("Rescan processes")
        }
    }

    // MARK: - Animated Tab Bar (GooeyNav equivalent)

    private var animatedTabBar: some View {
        HStack(spacing: 2) {
            ForEach(WindowTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(.thinMaterial)
                                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "activeTab", in: tabAnimation)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
        )
        // The tab bar must never be compressed; without this it absorbs the shortfall when the
        // surrounding row runs out of width and wraps each label to one character per line.
        .fixedSize()
    }

    // MARK: - Home (Dashboard + Processes + Memory)

    private var homeContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Stats bar
                statsRow

                // Memory
                if let memory = appState.memoryStats {
                    memoryCard(memory: memory)
                }

                // Processes
                processesContent

                // Persistent launch items
                launchItemsCard

                // Toast overlay
                if appState.showingMemoryMessage {
                    Text(appState.memoryMessage)
                        .font(.subheadline)
                        .foregroundStyle(appState.memoryMessage.contains("Failed") ? .red : .green)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.thinMaterial))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(
                title: "Detected",
                value: "\(appState.totalBloatCount)",
                icon: "exclamationmark.triangle.fill",
                color: appState.totalBloatCount > 0 ? .red : .green
            )
            StatCard(
                title: "CPU Bloat",
                value: String(format: "%.1f%%", appState.totalCPUUsage),
                icon: "gauge.medium",
                color: appState.totalCPUUsage > 10 ? .orange : .blue
            )
            StatCard(
                title: "RAM Wasted",
                value: String(format: "%.0f MB", appState.totalMemoryMB),
                icon: "memorychip",
                color: appState.totalMemoryMB > 500 ? .orange : .blue
            )
            if !appState.selectedForKill.isEmpty {
                StatCard(
                    title: "Selected",
                    value: "\(appState.selectedForKill.count)",
                    icon: "target",
                    color: .red
                )
            }
        }
    }

    // MARK: - Memory Card

    private func memoryCard(memory: MemoryStats) -> some View {
        GlassCard {
            HStack(spacing: 8) {
                Image(systemName: "memorychip.fill")
                    .foregroundStyle(.secondary)
                Text("System Memory")
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

            HStack {
                Text("Used")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f / %.1f GB (%.0f%%)",
                            memory.wiredGB + memory.activeGB + memory.compressedGB,
                            memory.totalGB,
                            memory.usedPercentage))
                    .fontWeight(.medium)
            }
            .font(.subheadline)

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
                        .frame(width: geometry.size.width * CGFloat(min(memory.usedPercentage, 100)) / 100)
                }
            }
            .frame(height: 8)

            // Quick actions
            HStack(spacing: 8) {
                Button {
                    appState.purgeMemory()
                } label: {
                    HStack(spacing: 4) {
                        if appState.isPurgingMemory {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Purge")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isPurgingMemory)

                if !MiloBuildMode.isDevelopmentPreview {
                    Button {
                        appState.requestClearUserCaches()
                    } label: {
                        HStack(spacing: 4) {
                            if appState.isClearingCaches {
                                ProgressView().scaleEffect(0.5)
                            } else {
                                Image(systemName: "trash")
                            }
                            Text("Caches")
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isClearingCaches)
                }

                Button {
                    appState.flushDNS()
                } label: {
                    HStack(spacing: 4) {
                        if appState.isFlushingDNS {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "globe")
                        }
                        Text("DNS")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isFlushingDNS)

                Spacer()
            }
        }
    }

    // MARK: - Bottom Bar

    /// Persistent tool and kill affordances.
    ///
    /// The kill action deliberately lives here rather than inside the memory card: that card
    /// only renders once `memoryStats` resolves, and the window's primary action must never
    /// depend on an unrelated subsystem succeeding.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Button {
                    activeSheet = .stats
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Statistics & Impact")
                .accessibilityLabel("View statistics")

                Button {
                    activeSheet = .whitelist
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Manage Hidden Processes")
                .accessibilityLabel("Manage hidden processes")

                Divider().frame(height: 16)

                selectionControls

                Spacer(minLength: 8)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quit Milo (⌘Q)")
            }
            .frame(height: 24)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if appState.isKilling || !appState.selectedForKill.isEmpty {
            HStack(spacing: 10) {
                if appState.isKilling {
                    // A vendor "Kill All" runs from a pending set rather than the selection, so
                    // reporting the selection count here would read "0" mid-termination.
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)

                    Text("Terminating \(appState.pendingKillCount) process\(appState.pendingKillCount == 1 ? "" : "es")…")
                        .font(.system(size: 12, weight: .medium))

                    Spacer()
                } else {
                    Text("\(appState.selectedForKill.count) selected")
                        .font(.system(size: 12, weight: .semibold))

                    Text(String(format: "%.1f%% CPU", appState.selectedCPUUsage))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(format: "%.0f MB", appState.selectedMemoryMB))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear") {
                        appState.selectAll(false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        handleKillRequest()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle.fill")
                            Text("Kill Selected (\(appState.selectedForKill.count))")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .help("Kill selected processes (⌘K)")
                    .accessibilityLabel("Kill selected processes")
                }
            }
        }
    }

    // MARK: - Processes

    private var processesContent: some View {
        VStack(spacing: 12) {
            // Vendor-grouped bloat
            ForEach(appState.bloatByVendor.keys.sorted(), id: \.self) { vendor in
                if let items = appState.bloatByVendor[vendor] {
                    GlassCard {
                        HStack(spacing: 8) {
                            Image(systemName: vendorIcon(for: vendor))
                                .foregroundStyle(vendorColor(for: vendor))
                            Text(vendor)
                                .font(.headline)
                            Spacer()
                            Text("\(items.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Kill All") {
                                if hasProAccess {
                                    appState.killVendor(vendor)
                                } else {
                                    showPaywall = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(.red)
                        }

                        Divider().opacity(0.35)

                        ForEach(items) { item in
                            processRow(item: item, isBloat: true)
                            if item.id != items.last?.id {
                                Divider().opacity(0.15)
                            }
                        }
                    }
                }
            }

            // Apple Intelligence
            if !appState.visibleIntelligence.isEmpty {
                GlassCard {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(.purple)
                        Text("Apple Intelligence")
                            .font(.headline)
                        Spacer()
                        Text("\(appState.visibleIntelligence.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Divider().opacity(0.35)

                    ForEach(appState.visibleIntelligence) { item in
                        processRow(item: item, isBloat: false)
                        if item.id != appState.visibleIntelligence.last?.id {
                            Divider().opacity(0.15)
                        }
                    }
                }
            }

            if let scanFailure = appState.scanFailureMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text("Scan unavailable")
                        .font(.title3.weight(.semibold))
                    Text(scanFailure)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        appState.scanProcesses()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else if appState.scanResultIsClean {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("System Clean")
                        .font(.title3.weight(.semibold))
                    Text("No bloatware or telemetry daemons detected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }

            // Scanning indicator
            if appState.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Scanning...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Launch Items

    @ViewBuilder
    private var launchItemsCard: some View {
        if !appState.visibleLaunchItems.isEmpty {
            GlassCard {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                    Text("Persistent Launch Items")
                        .font(.headline)
                    Spacer()
                    Text("\(appState.visibleLaunchItems.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.35)

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

                    if item != appState.visibleLaunchItems.last {
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    // MARK: - Process Row

    private func processRow(item: ProcessItem, isBloat: Bool) -> some View {
        let binding = isBloat
            ? appState.bloatSelectionBinding(for: item.id)
            : appState.intelligenceSelectionBinding(for: item.id)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)

                    if item.isLaunchdManaged {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 9))
                            Text(item.isSystemProcess ? "System" : "Daemon")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.isSystemProcess ? Color.red.opacity(0.15) : Color.blue.opacity(0.15)))
                        .foregroundStyle(item.isSystemProcess ? .red : .blue)
                    }
                }

                HStack(spacing: 8) {
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        if item.cpuUsage >= 0 {
                            ResourceBadge(icon: "cpu", value: String(format: "%.1f%%", item.cpuUsage), isHigh: item.cpuUsage > 10)
                        }
                        if item.memoryMB >= 0 {
                            ResourceBadge(icon: "memorychip", value: String(format: "%.0fMB", item.memoryMB), isHigh: item.memoryMB > 100)
                        }
                    }
                }
            }

            Spacer()

            Toggle("", isOn: binding)
                .toggleStyle(.checkbox)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .hoverHighlight()
    }

    // MARK: - Helpers

    private func handleKillRequest() {
        if hasProAccess {
            appState.requestKill()
        } else {
            showPaywall = true
        }
    }

    private func vendorIcon(for vendor: String) -> String {
        let lower = vendor.lowercased()
        if lower.contains("adobe") { return "paintbrush.fill" }
        if lower.contains("microsoft") { return "building.columns.fill" }
        if lower.contains("google") { return "globe" }
        if lower.contains("apple") { return "apple.logo" }
        if lower.contains("spotify") { return "waveform" }
        if lower.contains("zoom") { return "video.fill" }
        if lower.contains("slack") { return "number" }
        return "puzzlepiece.extension.fill"
    }

    private func vendorColor(for vendor: String) -> Color {
        let lower = vendor.lowercased()
        if lower.contains("adobe") { return .red }
        if lower.contains("microsoft") { return .blue }
        if lower.contains("google") { return .green }
        if lower.contains("apple") { return .purple }
        if lower.contains("spotify") { return .green }
        return .secondary
    }
}
