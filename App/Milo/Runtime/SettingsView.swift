import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updateManager: MiloUpdateManager
    var isEmbedded: Bool = false
    @Environment(\.dismiss) var dismiss

    @State private var launchAtLogin: Bool = SettingsManager.shared.isLoginItemEnabled()
    @State private var autoScanOnOpen: Bool = SettingsManager.shared.autoScanOnOpen
    @State private var confirmBeforeKill: Bool = SettingsManager.shared.confirmBeforeKill
    @State private var showBadgeCount: Bool = SettingsManager.shared.showBadgeCount
    @State private var showMemoryInHeader: Bool = SettingsManager.shared.showMemoryInHeader
    @State private var autoScanInterval: Int = SettingsManager.shared.autoScanInterval
    @State private var notifyOnDetection: Bool = SettingsManager.shared.notifyOnDetection

    @AppStorage("Milo.appAppearance") var appAppearance: String = "Auto"
    @AppStorage("Milo.appThemeColor") var appThemeColor: String = "System"
    @AppStorage("Milo.liquidGlass") var liquidGlass: String = "Auto"
    @AppStorage("Milo.viewMode") var viewMode: String = "menuBar"
    @AppStorage(MiloDefaultsKey.windowCloseBehavior) var windowCloseBehavior: String = MiloWindowCloseBehavior.hide.rawValue

    private let scanIntervalOptions = [0, 60, 120, 300, 600]

    var body: some View {
        ZStack {
            if !isEmbedded {
                VisualEffectBlur()
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                if !isEmbedded {
                    SheetHeader(title: "Settings", subtitle: "Preferences & configuration", dismiss: dismiss)
                    Divider()
                }

                ScrollView {
                    VStack(spacing: 16) {
                        viewSection
                        generalSection
                        automationSection
                        scanSection
                        uiSection
                        shortcutsSection
                        privilegesSection
                        aboutSection
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: isEmbedded ? nil : MiloPanelMetrics.width, height: isEmbedded ? nil : MiloPanelMetrics.height)
        .onAppear {
            refreshState()
            appState.refreshHelperStatus()
        }
        .tint(tintColorOverride)
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

    // MARK: - View Mode

    private var viewSection: some View {
        GlassCard {
            Label("View", systemImage: "macwindow")
                .font(.headline)

            HStack {
                Text("Mode")
                Spacer()
                Picker("", selection: $viewMode) {
                    Text("Menu Bar").tag("menuBar")
                    Text("Window").tag("dedicatedWindow")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Text(viewMode == "menuBar" ? "Compact panel below the menu bar icon." : "Full-size window with sidebar navigation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewMode == "dedicatedWindow" {
                Divider()

                HStack {
                    Text("Closing the window")
                    Spacer()
                    Picker("", selection: $windowCloseBehavior) {
                        Text("Hides Milo").tag(MiloWindowCloseBehavior.hide.rawValue)
                        Text("Quits Milo").tag(MiloWindowCloseBehavior.quit.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                Text(windowCloseBehavior == MiloWindowCloseBehavior.quit.rawValue
                     ? "The red close button quits Milo entirely."
                     : "The red close button leaves Milo running in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    private var shortcutsSection: some View {
        GlassCard {
            Label("Keyboard Shortcuts", systemImage: "command")
                .font(.headline)

            ForEach(Self.shortcutReference, id: \.action) { entry in
                HStack {
                    Text(entry.action)
                        .font(.subheadline)
                    Spacer()
                    Text(entry.keys)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.quaternary.opacity(0.5))
                        )
                }
            }

            Text("All of these are also listed in the Actions menu in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Mirrors the Actions menu built in `MenuBarAppDelegate`.
    private static let shortcutReference: [(action: String, keys: String)] = [
        ("Rescan now", "⌘R"),
        ("Select all detected", "⇧⌘A"),
        ("Deselect all", "⇧⌘D"),
        ("Kill selected", "⌘K"),
        ("Kill all detected", "⇧⌘K"),
        ("Settings", "⌘,"),
        ("Show Milo", "⌘0"),
        ("Quit Milo", "⌘Q")
    ]

    // MARK: - General

    private var generalSection: some View {
        GlassCard {
            Label("General", systemImage: "gearshape.fill")
                .font(.headline)

            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Milo at Login")
                    Text("Automatically launch when you log in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: launchAtLogin) { newValue in
                SettingsManager.shared.launchAtLogin = newValue
            }

            Divider()

            Toggle(isOn: $confirmBeforeKill) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm Before Kill")
                    Text("Show confirmation dialog before terminating processes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: confirmBeforeKill) { newValue in
                SettingsManager.shared.confirmBeforeKill = newValue
            }
        }
    }

    // MARK: - Automation

    private var automationSection: some View {
        GlassCard {
            Label("Automation", systemImage: "bolt.circle.fill")
                .font(.headline)

            Toggle(isOn: $notifyOnDetection) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify on Detection")
                    Text("Send a macOS notification when new bloat appears")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: notifyOnDetection) { newValue in
                SettingsManager.shared.notifyOnDetection = newValue
                if newValue {
                    appState.requestNotificationPermission()
                }
            }
        }
    }

    // MARK: - Scanning

    private var scanSection: some View {
        GlassCard {
            Label("Scanning", systemImage: "magnifyingglass")
                .font(.headline)

            Toggle(isOn: $autoScanOnOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan on Open")
                    Text("Automatically scan for bloat when popover opens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: autoScanOnOpen) { newValue in
                SettingsManager.shared.autoScanOnOpen = newValue
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Rescan Interval")
                    Text("Periodically re-scan while open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $autoScanInterval) {
                    Text("Off").tag(0)
                    Text("1m").tag(60)
                    Text("2m").tag(120)
                    Text("5m").tag(300)
                    Text("10m").tag(600)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .onChange(of: autoScanInterval) { newValue in
                    SettingsManager.shared.autoScanInterval = newValue
                    appState.configureAutoScan(interval: newValue)
                }
            }
        }
    }

    // MARK: - UI

    private var uiSection: some View {
        GlassCard {
            Label("Appearance", systemImage: "paintpalette.fill")
                .font(.headline)

            HStack {
                Text("Mode")
                Spacer()
                Picker("", selection: $appAppearance) {
                    Text("Auto").tag("Auto")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Divider()

            HStack {
                Text("Liquid Glass")
                Spacer()
                Picker("", selection: $liquidGlass) {
                    Text("Auto").tag("Auto")
                    Text("Clear").tag("Clear")
                    Text("Tinted").tag("Tinted")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            Divider()

            HStack {
                Text("Accent Color")
                Spacer()
                Picker("", selection: $appThemeColor) {
                    Text("System Default").tag("System")
                    Text("Blue").tag("Blue")
                    Text("Purple").tag("Purple")
                    Text("Pink").tag("Pink")
                    Text("Red").tag("Red")
                    Text("Orange").tag("Orange")
                    Text("Yellow").tag("Yellow")
                    Text("Green").tag("Green")
                    Text("Gray").tag("Gray")
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            Divider()

            Toggle(isOn: $showBadgeCount) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Status Bar Badge")
                    Text("Show bloat count next to menu bar icon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: showBadgeCount) { newValue in
                SettingsManager.shared.showBadgeCount = newValue
            }

            Divider()

            Toggle(isOn: $showMemoryInHeader) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Dashboard")
                    Text("Show memory usage card with purge/cache actions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: showMemoryInHeader) { newValue in
                SettingsManager.shared.showMemoryInHeader = newValue
                appState.showMemoryInHeader = newValue
            }
        }
    }

    // MARK: - Privileges

    private var privilegesSection: some View {
        GlassCard {
            Label("Background Helper", systemImage: "lock.shield.fill")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(helperStatusTitle)
                    Text(helperStatusDetail)
                        .font(.caption)
                        .foregroundStyle(appState.helperStatus.isEnabled ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if appState.helperStatus.isEnabled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if appState.helperStatus == .requiresApproval {
                    Button("Open Settings") {
                        appState.openHelperApprovalSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Enable") {
                        appState.setupPrivileges()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isConfiguringPrivileges)
                    .help("Register Milo's signed, narrowly scoped launch daemon.")
                }
            }

            Text("Milo never installs sudoers rules. macOS approval is requested once; the helper then accepts only signed Milo requests and a fixed command policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = appState.privilegeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.helperStatus.isEnabled {
                Divider()

                Button(role: .destructive) {
                    appState.removeHelper()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Disable Background Helper")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        }
    }

    private var helperStatusTitle: String {
        switch appState.helperStatus {
        case .notRegistered:
            return "Not Enabled"
        case .requiresApproval:
            return "Waiting for macOS Approval"
        case .enabled:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        }
    }

    private var helperStatusDetail: String {
        switch appState.helperStatus {
        case .notRegistered:
            return "Enable once for system-level process and tuning actions."
        case .requiresApproval:
            return "Enable Milo under General › Login Items, then return here."
        case .enabled:
            return "System-level actions run without repeated password prompts."
        case .unavailable(let message):
            return message
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        GlassCard {
            Label("About", systemImage: "info.circle.fill")
                .font(.headline)

            HStack {
                Text("Milo")
                    .fontWeight(.medium)
                Spacer()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundStyle(.secondary)
            }

            if MiloBuildMode.isDevelopmentPreview {
                HStack {
                    Text("Build")
                    Spacer()
                    Text("Development Preview")
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                }
            }

            HStack {
                Text("SIP Status")
                Spacer()
                Text(appState.isSIPEnabled ? "Enabled" : "Disabled")
                    .foregroundStyle(appState.isSIPEnabled ? .orange : .green)
                    .fontWeight(.medium)
            }

            HStack {
                Text("macOS")
                Spacer()
                Text(ProcessInfo.processInfo.operatingSystemVersionString)
                    .foregroundStyle(.secondary)
            }

            if !MiloBuildMode.isDevelopmentPreview {
                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Software Updates")
                        Text("Authenticated by your Pro device key and verified by Sparkle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(updateManager.isChecking ? "Checking…" : "Check Now") {
                        Task {
                            await updateManager.checkForUpdates()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updateManager.canCheckForUpdates)
                }

                if let statusMessage = updateManager.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(updateManager.statusIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshState() {
        launchAtLogin = SettingsManager.shared.isLoginItemEnabled()
        autoScanOnOpen = SettingsManager.shared.autoScanOnOpen
        confirmBeforeKill = SettingsManager.shared.confirmBeforeKill
        showBadgeCount = SettingsManager.shared.showBadgeCount
        showMemoryInHeader = SettingsManager.shared.showMemoryInHeader
        autoScanInterval = SettingsManager.shared.autoScanInterval
        notifyOnDetection = SettingsManager.shared.notifyOnDetection
    }
}
