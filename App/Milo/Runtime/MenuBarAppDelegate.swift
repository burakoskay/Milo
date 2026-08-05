import Cocoa
import MiloHardening
import SwiftUI

// MARK: - Runtime code-signature check

/// Records which build is running. **This is detection, not enforcement**, and deliberately so —
/// see `docs/decisions/0005-defer-tamper-enforcement-to-1.0.md`.
///
/// A failure means the running code does not carry gonggong's signing identity: the binary was
/// modified, or re-signed by somebody else. Milo logs that and carries on. It does not refuse to
/// run, degrade, or disable anything, because there is nothing to pirate — licensing is deferred
/// to 1.0 by decision 0002, and an enforcement response designed before the thing it protects
/// exists is a guess.
///
/// What the check *does* earn is real: the packaged smoke suite asserts the same requirement, and
/// that assertion is what proved the gonggong rename had not broken the requirement string in
/// `Integrity.c`. A mistake there produces a false compromise verdict at launch rather than a
/// build failure, so the positive path is worth checking on every start.
///
/// Until 2026-08-05 this also set a `Milo.integrity.compromised` user default that **nothing ever
/// read**. A flag no code consults is worse than no flag: it reads as a control when it is only a
/// note to nobody. Removed. If enforcement is ever wanted, add the response and its UI together,
/// deliberately — not by discovering this key and wiring something to it.
@discardableResult
private func performRuntimeSignatureCheck() -> Bool {
    MiloHardeningPrimitives.retain()
    let passed = MiloIntegrity.check(.launch)
    if passed == false {
        MiloLog.warning(.runtimeIntegrityFailed, category: .security, detail: "integrity-launch")
        return false
    }
    return true
}

// MARK: - Typed Notification Names

extension Notification.Name {
    /// Posted when the active presentation surface becomes visible to the user.
    static let miloSurfaceDidOpen = Notification.Name("MiloSurfaceDidOpen")
    /// Posted when the active presentation surface is hidden or torn down.
    static let miloSurfaceDidClose = Notification.Name("MiloSurfaceDidClose")
    /// Posted when the active surface regains focus and cheap state should be refreshed.
    static let miloSurfaceDidActivate = Notification.Name("MiloSurfaceDidActivate")
    /// Posted when the user asks for Settings from the menu bar or a keyboard shortcut.
    static let miloOpenSettings = Notification.Name("MiloOpenSettings")
    /// Posted when the menu bar badge needs the current detected-process count.
    static let miloRequestCurrentBloatCount = Notification.Name("MiloRequestCurrentBloatCount")
    /// Posted with the current detected-process count as the notification object.
    static let miloBloatCountChanged = Notification.Name("MiloBloatCountChanged")
    /// Posted with the new badge preference as the notification object.
    static let miloBadgeSettingChanged = Notification.Name("MiloBadgeSettingChanged")
    /// Posted when locally cached signature rules changed and a rescan is warranted.
    static let miloCloudSignaturesChanged = Notification.Name("MiloCloudSignaturesChanged")
}

// MARK: - Defaults Keys

enum MiloDefaultsKey {
    static let viewMode = "Milo.viewMode"
    static let appearance = "Milo.appAppearance"
    static let quitBehavior = "Milo.quitBehavior"
    static let windowCloseBehavior = "Milo.windowCloseBehavior"
}

/// What the dedicated window's close button does. Milo is an `LSUIElement` agent, so hiding to
/// the menu bar is the default, but closing a window to quit is an equally valid expectation.
enum MiloWindowCloseBehavior: String, CaseIterable {
    case hide
    case quit

    static var current: MiloWindowCloseBehavior {
        MiloWindowCloseBehavior(
            rawValue: UserDefaults.standard.string(forKey: MiloDefaultsKey.windowCloseBehavior) ?? ""
        ) ?? .hide
    }
}

// MARK: - Presentation Surface

/// Milo presents its UI through exactly one surface at a time.
///
/// This is an invariant, not a preference. Both `ContentView` and `DedicatedWindowView`
/// bind alert presentation to the same `AppState` flags, so two live SwiftUI hosts would
/// each try to present the same confirmation — forcing the inactive host's window on
/// screen at an unpositioned frame. Only the active surface may own a hosting controller.
private enum MiloSurface: String {
    case menuBar
    case dedicatedWindow

    init(defaultsValue: String?) {
        self = MiloSurface(rawValue: defaultsValue ?? "") ?? .menuBar
    }
}

// MARK: - Floating Panel (borderless — no arrow, no titlebar gap)

final class StatusBarPanel: NSPanel {
    /// Matches the corner radius macOS uses for menu bar popovers.
    private static let cornerRadius: CGFloat = 16

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
        isReleasedWhenClosed = false
        level = .statusBar
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .utilityWindow
        applyCornerMask()
    }

    /// Rounds the current content view.
    ///
    /// Assigning `contentViewController` replaces `contentView` outright, so a radius applied
    /// in `init` is discarded and the panel renders with square corners. This must be re-applied
    /// every time the hosted content changes.
    override var contentViewController: NSViewController? {
        didSet {
            applyCornerMask()
        }
    }

    private func applyCornerMask() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = Self.cornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }
}

// MARK: - Window Delegate

/// Closing the dedicated window hides Milo back to the menu bar rather than quitting.
/// Milo is an `LSUIElement` agent; the status item remains the way back in.
final class MiloWindowDelegate: NSObject, NSWindowDelegate {
    weak var appDelegate: MenuBarAppDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appDelegate = appDelegate else { return true }
        switch MiloWindowCloseBehavior.current {
        case .hide:
            appDelegate.hideDedicatedWindow()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        NotificationCenter.default.post(name: .miloSurfaceDidActivate, object: nil)
    }
}

// MARK: - App Delegate

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private enum QuitDecision {
        case quit
        case runInBackground
        case cancel
    }

    private var statusItem: NSStatusItem?
    private var panel: StatusBarPanel?
    private(set) var dedicatedWindow: NSWindow?
    let appState: AppState
    let updateManager: MiloUpdateManager
    private let windowDelegate = MiloWindowDelegate()

    private var appearanceObserver: Any?
    private var bloatCountObserver: Any?
    private var badgeSettingObserver: Any?
    private var globalEventMonitor: Any?
    private var defaultsObserver: Any?

    /// The surface that is currently constructed. Guarantees the single-surface invariant.
    private var activeSurface: MiloSurface?
    /// Last appearance actually applied, so unrelated defaults writes do not churn windows.
    private var appliedAppearance: String?

    private let panelWidth = MiloPanelMetrics.width
    private let panelHeight = MiloPanelMetrics.height

    private var preferredSurface: MiloSurface {
        MiloSurface(defaultsValue: UserDefaults.standard.string(forKey: MiloDefaultsKey.viewMode))
    }

    private var preferredAppearance: String {
        UserDefaults.standard.string(forKey: MiloDefaultsKey.appearance) ?? "Auto"
    }

    override init() {
        self.appState = AppState()
        self.updateManager = MiloUpdateManager(licenseManager: LicenseManager.shared)
        super.init()
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        _ = performRuntimeSignatureCheck()

        windowDelegate.appDelegate = self
        buildMainMenu()

        appliedAppearance = preferredAppearance

        installStatusItem()
        installObservers()

        // Build the surface the user last selected. The menu bar panel stays hidden until
        // the user asks for it, unless onboarding needs to present the first-launch prompt.
        let surface = preferredSurface
        switch surface {
        case .dedicatedWindow:
            showSurface(surface)
        case .menuBar:
            if appState.showingFirstLaunchPrivilegePrompt {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.showSurface(.menuBar)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalEventMonitor()
    }

    // MARK: - Status Item

    private func installStatusItem() {
        let createdStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = createdStatusItem
        guard let button = createdStatusItem.button else { return }
        if let image = NSImage(named: "MenuBarIcon") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
        }
        button.title = ""
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
    }

    // MARK: - Observers

    private func installObservers() {
        IconManager.applyAppIcon(for: NSApplication.shared.effectiveAppearance)
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                IconManager.applyAppIcon(for: NSApplication.shared.effectiveAppearance)
            }
        }

        bloatCountObserver = NotificationCenter.default.addObserver(
            forName: .miloBloatCountChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let count = notification.object as? Int else { return }
            Task { @MainActor [weak self] in
                if SettingsManager.shared.showBadgeCount {
                    self?.updateBadge(count: count)
                } else {
                    self?.clearBadge()
                }
            }
        }

        badgeSettingObserver = NotificationCenter.default.addObserver(
            forName: .miloBadgeSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let enabled = notification.object as? Bool else { return }
            Task { @MainActor [weak self] in
                if enabled {
                    NotificationCenter.default.post(name: .miloRequestCurrentBloatCount, object: nil)
                } else {
                    self?.clearBadge()
                }
            }
        }

        // `UserDefaults.didChangeNotification` fires for every write in the app domain —
        // window frame autosaves, status item positions, and unrelated preferences included.
        // Only act when a value we actually own has changed.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppearanceIfChanged()
                self?.applySurfaceIfChanged()
            }
        }
    }

    // MARK: - Quit Confirmation

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch UserDefaults.standard.string(forKey: MiloDefaultsKey.quitBehavior) {
        case "quit":
            return .terminateNow
        case "background":
            hideActiveSurface()
            return .terminateCancel
        default:
            switch runQuitConfirmation() {
            case .quit:
                return .terminateNow
            case .runInBackground:
                hideActiveSurface()
                return .terminateCancel
            case .cancel:
                return .terminateCancel
            }
        }
    }

    /// Runs the quit confirmation synchronously so the decision can be returned directly to
    /// `applicationShouldTerminate`. An asynchronous sheet cannot be used here: once
    /// `.terminateCancel` is returned, `reply(toApplicationShouldTerminate:)` is a no-op and
    /// the user's "Quit" choice would be silently discarded.
    private func runQuitConfirmation() -> QuitDecision {
        let alert = NSAlert()
        alert.messageText = "Quit Milo?"

        let bloatCount = appState.totalBloatCount
        let ramUsed = String(format: "%.0f MB", appState.totalMemoryMB)
        let cpuUsed = String(format: "%.1f%%", appState.totalCPUUsage)

        if bloatCount > 0 {
            alert.informativeText = """
                Milo is monitoring \(bloatCount) background processes consuming \(ramUsed) RAM and \(cpuUsed) CPU.

                Keep Milo running in the menu bar to continue monitoring your system.
                """
        } else {
            alert.informativeText = """
                Milo will stop monitoring your system for background processes and telemetry.

                You can keep it running silently in the menu bar.
                """
        }

        alert.addButton(withTitle: "Run in Background")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"

        // The status bar panel floats above normal modal levels; raise the alert above it so
        // the dialog can never be hidden behind the surface that triggered it.
        if let panel = panel, panel.isVisible {
            alert.window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        }

        let response = alert.runModal()
        let remember = alert.suppressionButton?.state == .on

        switch response {
        case .alertFirstButtonReturn:
            if remember {
                UserDefaults.standard.set("background", forKey: MiloDefaultsKey.quitBehavior)
            }
            return .runInBackground
        case .alertSecondButtonReturn:
            if remember {
                UserDefaults.standard.set("quit", forKey: MiloDefaultsKey.quitBehavior)
            }
            return .quit
        default:
            return .cancel
        }
    }

    // MARK: - Appearance

    private func applyAppearanceIfChanged() {
        let mode = preferredAppearance
        guard mode != appliedAppearance else { return }
        appliedAppearance = mode
        let appearance = resolvedAppearance(for: mode)
        panel?.appearance = appearance
        dedicatedWindow?.appearance = appearance
    }

    private func resolvedAppearance(for mode: String) -> NSAppearance? {
        switch mode {
        case "Light":
            return NSAppearance(named: .aqua)
        case "Dark":
            return NSAppearance(named: .darkAqua)
        default:
            return nil
        }
    }

    // MARK: - Badge

    private func updateBadge(count: Int) {
        guard let button = self.statusItem?.button else { return }
        guard count > 0 else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let badge = NSAttributedString(
            string: " \(count)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ]
        )
        button.attributedTitle = badge
    }

    private func clearBadge() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        button.title = ""
    }

    // MARK: - Status Item Click

    @objc func handleStatusItemClick(_ sender: AnyObject?) {
        let surface = preferredSurface
        if isSurfaceVisible(surface) {
            hideActiveSurface()
        } else {
            showSurface(surface)
        }
    }

    // MARK: - Surface State Machine

    private func isSurfaceVisible(_ surface: MiloSurface) -> Bool {
        guard activeSurface == surface else { return false }
        switch surface {
        case .menuBar:
            return panel?.isVisible == true
        case .dedicatedWindow:
            return dedicatedWindow?.isVisible == true
        }
    }

    /// Reacts to an actual view-mode change only. Called from the defaults observer, which
    /// fires far more often than the preference itself changes.
    private func applySurfaceIfChanged() {
        let desired = preferredSurface
        guard let current = activeSurface, current != desired else { return }
        let wasVisible = isSurfaceVisible(current)
        tearDownSurface(current)
        guard wasVisible else { return }
        showSurface(desired)
        // The view mode can only be changed from Settings, so land the user back there
        // instead of dropping them on the home screen of the new surface.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .miloOpenSettings, object: nil)
        }
    }

    private func showSurface(_ surface: MiloSurface) {
        if let current = activeSurface, current != surface {
            tearDownSurface(current)
        }
        // Each show path claims `activeSurface` only once it has a window on screen, so a
        // surface that cannot be presented never leaves the state machine claiming it is.
        switch surface {
        case .menuBar:
            showPanel()
        case .dedicatedWindow:
            showDedicatedWindow()
        }
    }

    private func hideActiveSurface() {
        guard let surface = activeSurface else { return }
        switch surface {
        case .menuBar:
            hidePanel()
        case .dedicatedWindow:
            hideDedicatedWindow()
        }
    }

    /// Releases a surface's SwiftUI hosting controller. Releasing the host is what enforces the
    /// single-surface invariant: a window with no host cannot present an alert bound to shared
    /// `AppState`, so it can never be forced on screen behind the user's back.
    ///
    /// The `NSWindow` itself is retained and reused. Closing and re-creating it would discard
    /// the autosaved frame and invite the classic `isReleasedWhenClosed` over-release hazard
    /// for a window still referenced from a Swift property.
    private func tearDownSurface(_ surface: MiloSurface) {
        switch surface {
        case .menuBar:
            hidePanel()
            panel?.contentViewController = nil
        case .dedicatedWindow:
            hideDedicatedWindow()
            dedicatedWindow?.contentViewController = nil
        }
        if activeSurface == surface {
            activeSurface = nil
        }
    }

    // MARK: - Menu Bar Panel

    private func makePanel() -> StatusBarPanel {
        let created = StatusBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        )
        created.appearance = resolvedAppearance(for: preferredAppearance)
        return created
    }

    private func showPanel() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentViewController == nil {
            panel.contentViewController = NSHostingController(
                rootView: ContentView(appState: appState, updateManager: updateManager)
            )
        }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        var origin = CGPoint(
            x: screenRect.midX - panelWidth / 2,
            y: screenRect.minY - panelHeight - 4
        )
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            origin.x = max(visibleFrame.minX + 8, min(origin.x, visibleFrame.maxX - panelWidth - 8))
            origin.y = max(visibleFrame.minY + 8, origin.y)
        }

        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight),
            display: true
        )
        panel.makeKeyAndOrderFront(nil)
        activateApp()

        statusItem?.button?.isHighlighted = true
        activeSurface = .menuBar
        postSurfaceDidOpen()
        installGlobalEventMonitor()
    }

    private func hidePanel() {
        removeGlobalEventMonitor()
        statusItem?.button?.isHighlighted = false
        guard let panel = panel, panel.isVisible else { return }
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .miloSurfaceDidClose, object: nil)
    }

    private func installGlobalEventMonitor() {
        removeGlobalEventMonitor()
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPanelForOutsideClick()
            }
        }
    }

    private func removeGlobalEventMonitor() {
        guard let monitor = globalEventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        globalEventMonitor = nil
    }

    /// A click outside Milo dismisses the panel, except while the panel owns a modal
    /// presentation. Dismissing then would orphan a confirmation the user must still answer.
    private func dismissPanelForOutsideClick() {
        guard let panel = panel, panel.isVisible else { return }
        guard panel.attachedSheet == nil, NSApplication.shared.modalWindow == nil else { return }
        hidePanel()
    }

    // MARK: - Dedicated Window

    private func makeDedicatedWindow() -> NSWindow {
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
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MiloDedicatedWindow")
        window.delegate = windowDelegate
        window.appearance = resolvedAppearance(for: preferredAppearance)
        return window
    }

    private func showDedicatedWindow() {
        let window = dedicatedWindow ?? makeDedicatedWindow()
        dedicatedWindow = window
        if window.contentViewController == nil {
            window.contentViewController = NSHostingController(
                rootView: DedicatedWindowView(appState: appState, updateManager: updateManager)
            )
        }
        window.makeKeyAndOrderFront(nil)
        activateApp()
        activeSurface = .dedicatedWindow
        postSurfaceDidOpen()
    }

    /// Hides the dedicated window without destroying it, preserving its frame and tab state.
    func hideDedicatedWindow() {
        guard let window = dedicatedWindow, window.isVisible else { return }
        window.orderOut(nil)
        NotificationCenter.default.post(name: .miloSurfaceDidClose, object: nil)
    }

    private func postSurfaceDidOpen() {
        // Posted on the next runloop pass so a freshly created SwiftUI host has installed its
        // `onReceive` subscriptions before the notification is delivered.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .miloSurfaceDidOpen, object: nil)
        }
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Milo")
        appMenu.addItem(
            withTitle: "About Milo",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        if !MiloBuildMode.isDevelopmentPreview {
            appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Milo", action: #selector(showMilo), keyEquivalent: "0")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Milo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Actions live in a real menu rather than hidden zero-opacity buttons. NSMenu owns the
        // key equivalents, so they fire reliably in both presentation modes, and the menu is
        // the only place a user can discover that these shortcuts exist at all.
        let actionsMenuItem = NSMenuItem()
        let actionsMenu = NSMenu(title: "Actions")
        addActionItem(to: actionsMenu, title: "Rescan Now", action: #selector(rescanNow), key: "r", modifiers: [.command])
        actionsMenu.addItem(.separator())
        addActionItem(
            to: actionsMenu,
            title: "Select All Detected",
            action: #selector(selectAllDetected),
            key: "a",
            // Deliberately not plain ⌘A: that belongs to the field editor for text selection.
            modifiers: [.command, .shift]
        )
        addActionItem(to: actionsMenu, title: "Deselect All", action: #selector(deselectAll), key: "d", modifiers: [.command, .shift])
        actionsMenu.addItem(.separator())
        addActionItem(to: actionsMenu, title: "Kill Selected", action: #selector(killSelected), key: "k", modifiers: [.command])
        addActionItem(to: actionsMenu, title: "Kill All Detected", action: #selector(killAllDetected), key: "k", modifiers: [.command, .shift])
        actionsMenuItem.submenu = actionsMenu
        mainMenu.addItem(actionsMenuItem)

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

    private func addActionItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }

    @objc private func rescanNow() {
        appState.scanProcesses()
        appState.refreshMemoryStats()
    }

    @objc private func selectAllDetected() {
        appState.selectAll(true)
    }

    @objc private func deselectAll() {
        appState.selectAll(false)
    }

    @objc private func killSelected() {
        appState.requestKill()
    }

    @objc private func killAllDetected() {
        appState.killAllDetected()
    }

    @objc func showMilo() {
        showSurface(preferredSurface)
    }

    @objc func openSettings() {
        showSurface(preferredSurface)
        // Posted after the surface is on screen so a newly created host receives it.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .miloOpenSettings, object: nil)
        }
    }

    @objc private func checkForUpdates() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await updateManager.checkForUpdates()
            if case let .failed(message) = updateManager.state {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Unable to Check for Updates"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}
