import Cocoa
import SwiftUI
import Security

// MARK: - Binary Hardening (Zero Technical Debt)

private func performRuntimeSignatureCheck() {
    #if !DEBUG && !AD_HOC
    let expectedTeamIdentifier = Secrets.appleTeamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard expectedTeamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
        exit(173)
    }

    var staticCode: SecStaticCode?
    let bundleURL = Bundle.main.bundleURL as CFURL

    guard SecStaticCodeCreateWithPath(bundleURL, [], &staticCode) == errSecSuccess,
          let code = staticCode else {
        exit(173)
    }

    let bundleIdentifier = "com.monomacaw.milo"
    let requirementSource = """
    anchor apple generic and identifier "\(bundleIdentifier)" and certificate leaf[subject.OU] = "\(expectedTeamIdentifier)"
    """ as CFString
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementSource, [], &requirement) == errSecSuccess,
          let requirement else {
        exit(173)
    }

    let requirementStatus = SecStaticCodeCheckValidity(
        code,
        SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
        requirement
    )
    if requirementStatus != errSecSuccess {
        exit(173)
    }
    #endif
}

// MARK: - Floating Panel (borderless — no arrow, no titlebar gap)

final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = false
        isFloatingPanel = true
        level = .statusBar
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow

        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 12
        contentView?.layer?.masksToBounds = true
    }
}

// MARK: - Window Delegate (intercept close button)

class MiloWindowDelegate: NSObject, NSWindowDelegate {
    weak var appDelegate: AppDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appDelegate = appDelegate else { return true }
        appDelegate.showQuitConfirmation(from: sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // No-op — windowShouldClose handles everything
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let panel: StatusBarPanel
    var dedicatedWindow: NSWindow?
    let appState: AppState
    private let windowDelegate = MiloWindowDelegate()

    private var appearanceObserver: Any?
    private var bloatCountObserver: Any?
    private var globalEventMonitor: Any?
    private var defaultsObserver: Any?

    private let panelWidth: CGFloat = 360
    private let panelHeight: CGFloat = 520

    private var currentViewMode: String {
        UserDefaults.standard.string(forKey: "Milo.viewMode") ?? "menuBar"
    }

    override init() {
        let appState = AppState()
        self.appState = appState
        self.panel = StatusBarPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520))
        super.init()
        panel.contentViewController = NSHostingController(rootView: ContentView(appState: appState))
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        windowDelegate.appDelegate = self
        buildMainMenu()

        applyAppearance()

        // Status item
        let createdStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = createdStatusItem
        if let button = createdStatusItem.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            }
            button.title = ""
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
        }

        // App icon sync
        IconManager.applyAppIcon(for: NSApplication.shared.effectiveAppearance)
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            IconManager.applyAppIcon(for: NSApplication.shared.effectiveAppearance)
        }

        // Badge observer
        bloatCountObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("MiloBloatCountChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let count = notification.object as? Int {
                if SettingsManager.shared.showBadgeCount {
                    self?.updateBadge(count: count)
                } else {
                    self?.statusItem?.button?.attributedTitle = NSAttributedString(string: "")
                    self?.statusItem?.button?.title = ""
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name("MiloBadgeSettingChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let enabled = notification.object as? Bool else { return }
            if enabled {
                NotificationCenter.default.post(name: .init("MiloRequestCurrentBloatCount"), object: nil)
            } else {
                self?.statusItem?.button?.attributedTitle = NSAttributedString(string: "")
                self?.statusItem?.button?.title = ""
            }
        }

        // Defaults observer — appearance + view mode
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
            self?.syncViewMode()
        }

        // Initial view mode
        if currentViewMode == "dedicatedWindow" {
            openDedicatedWindow()
        } else if appState.showingFirstLaunchPrivilegePrompt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanel()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "milo" {
            CheckoutManager.shared.handleAuthCallback(url: url)
        }
    }

    // MARK: - Quit Confirmation

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitBehavior = UserDefaults.standard.string(forKey: "Milo.quitBehavior") ?? "ask"

        if quitBehavior == "quit" {
            return .terminateNow
        }

        if quitBehavior == "background" {
            hideToBackground()
            return .terminateCancel
        }

        // Show confirmation dialog
        showQuitConfirmation(from: nil)
        return .terminateCancel
    }

    func showQuitConfirmation(from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Quit Milo?"

        let bloatCount = appState.totalBloatCount
        let ramUsed = String(format: "%.0f MB", appState.totalMemoryMB)
        let cpuUsed = String(format: "%.1f%%", appState.totalCPUUsage)

        if bloatCount > 0 {
            alert.informativeText = "Milo is monitoring \(bloatCount) background processes consuming \(ramUsed) RAM and \(cpuUsed) CPU.\n\nKeep Milo running in the menu bar to continue protecting your system."
        } else {
            alert.informativeText = "Milo will stop monitoring your system for bloatware and telemetry.\n\nYou can keep it running silently in the menu bar."
        }

        alert.addButton(withTitle: "Run in Background")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"

        let response: NSApplication.ModalResponse
        if let window = window {
            alert.beginSheetModal(for: window) { [weak self] modalResponse in
                self?.handleQuitResponse(modalResponse, suppressionState: alert.suppressionButton?.state ?? .off)
            }
            return
        } else {
            response = alert.runModal()
        }

        handleQuitResponse(response, suppressionState: alert.suppressionButton?.state ?? .off)
    }

    private func handleQuitResponse(_ response: NSApplication.ModalResponse, suppressionState: NSControl.StateValue) {
        switch response {
        case .alertFirstButtonReturn:
            // Run in Background
            if suppressionState == .on {
                UserDefaults.standard.set("background", forKey: "Milo.quitBehavior")
            }
            hideToBackground()
        case .alertSecondButtonReturn:
            // Quit
            if suppressionState == .on {
                UserDefaults.standard.set("quit", forKey: "Milo.quitBehavior")
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        default:
            break
        }
    }

    private func hideToBackground() {
        closePanel()
        closeDedicatedWindow()
    }

    // MARK: - Appearance

    private func applyAppearance() {
        let mode = UserDefaults.standard.string(forKey: "Milo.appAppearance") ?? "Auto"
        let appearance: NSAppearance?
        switch mode {
        case "Light":
            appearance = NSAppearance(named: .aqua)
        case "Dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil
        }
        panel.appearance = appearance
        dedicatedWindow?.appearance = appearance
    }

    // MARK: - Badge

    private func updateBadge(count: Int) {
        guard let button = self.statusItem?.button else { return }
        if count > 0 {
            let attributed = NSMutableAttributedString(string: "")
            let badge = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.systemRed
                ]
            )
            attributed.append(badge)
            button.attributedTitle = attributed
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Status Item Click

    @objc func handleStatusItemClick(_ sender: AnyObject?) {
        if currentViewMode == "dedicatedWindow" {
            // Toggle dedicated window visibility
            if let window = dedicatedWindow, window.isVisible {
                window.orderOut(nil)
            } else {
                openDedicatedWindow()
            }
        } else {
            // Toggle menu bar panel
            if panel.isVisible {
                closePanel()
            } else {
                showPanel()
            }
        }
    }

    // MARK: - View Mode Switching

    private func syncViewMode() {
        let mode = currentViewMode
        if mode == "dedicatedWindow" {
            if dedicatedWindow == nil {
                closePanel()
                openDedicatedWindow()
            }
        } else {
            // Switching from Window → Menu Bar: close window and immediately show panel
            if dedicatedWindow != nil {
                closeDedicatedWindow()
                showPanel()
            }
        }
    }

    // MARK: - Menu Bar Panel

    private func showPanel() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let xOrigin = screenRect.midX - panelWidth / 2
        let yOrigin = screenRect.minY - panelHeight - 4

        var finalX = xOrigin
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            finalX = max(visibleFrame.minX + 8, min(finalX, visibleFrame.maxX - panelWidth - 8))
        }

        panel.setFrame(NSRect(x: finalX, y: yOrigin, width: panelWidth, height: panelHeight), display: true)
        panel.makeKeyAndOrderFront(nil)

        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        statusItem?.button?.isHighlighted = true
        NotificationCenter.default.post(name: Notification.Name("MiloPopoverWillOpen"), object: nil)

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem?.button?.isHighlighted = false
        NotificationCenter.default.post(name: Notification.Name("MiloPopoverDidClose"), object: nil)

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    // MARK: - Dedicated Window

    private func openDedicatedWindow() {
        guard dedicatedWindow == nil else {
            dedicatedWindow?.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) {
                NSApplication.shared.activate()
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            return
        }

        let windowView = DedicatedWindowView(appState: appState)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Milo"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = NSHostingController(rootView: windowView)
        window.center()
        window.setFrameAutosaveName("MiloDedicatedWindow")
        window.delegate = windowDelegate

        // Apply appearance
        let mode = UserDefaults.standard.string(forKey: "Milo.appAppearance") ?? "Auto"
        switch mode {
        case "Light":
            window.appearance = NSAppearance(named: .aqua)
        case "Dark":
            window.appearance = NSAppearance(named: .darkAqua)
        default:
            window.appearance = nil
        }

        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        self.dedicatedWindow = window
        NotificationCenter.default.post(name: Notification.Name("MiloPopoverWillOpen"), object: nil)
    }

    private func closeDedicatedWindow() {
        dedicatedWindow?.orderOut(nil)
        dedicatedWindow = nil
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Milo")
        appMenu.addItem(withTitle: "About Milo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Milo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func openSettings() {
        NotificationCenter.default.post(name: Notification.Name("MiloOpenSettings"), object: nil)
        if currentViewMode == "dedicatedWindow" {
            if let window = dedicatedWindow {
                window.makeKeyAndOrderFront(nil)
            } else {
                openDedicatedWindow()
            }
        } else if !panel.isVisible {
            showPanel()
        }
    }
}

// Entry point
if CommandLine.arguments.contains("--self-test") {
    exit(SelfTestRunner.run(includeDestructive: CommandLine.arguments.contains("--self-test-destructive")))
}

performRuntimeSignatureCheck()

// Eagerly initialize managers to prevent dispatch_once deadlocks
// if NSTask spins the runloop during singleton initialization while SwiftUI is laying out views.
_ = LicenseManager.shared
_ = DebloatManager.shared

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
