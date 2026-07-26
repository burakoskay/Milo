import Foundation
import AppKit

// MARK: - Data Model

enum TweakRisk: String, Sendable {
    case safe = "Safe"          // Pure defaults write, easily reversible
    case moderate = "Moderate"  // Disables services, may affect features
    case aggressive = "Risky"   // SIP-off only, may break things
}

/// A single debloat tweak with on/off state detection
struct DebloatTweak: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: String
    let requiresSIP: Bool
    let risk: TweakRisk
    let needsRestart: Bool  // Needs Finder/Dock/SystemUI restart

    /// Commands to apply the tweak (enable the optimisation)
    let applyCommands: [String]
    let applyPrivileged: [String]

    /// Commands to revert the tweak (restore macOS default)
    let revertCommands: [String]
    let revertPrivileged: [String]

    /// Closure that returns `true` when the tweak is currently active
    let detect: @Sendable () -> Bool
}

struct DebloatCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let requiresSIP: Bool
    let tweaks: [DebloatTweak]
}

// MARK: - Manager

@MainActor
final class DebloatManager: ObservableObject {
    static let shared = DebloatManager()

    /// All categories (static structure)
    let categories: [DebloatCategory]

    /// Live state per tweak id — published so toggles update
    @Published var tweakStates: [String: Bool] = [:]
    @Published var busyTweaks: Set<String> = []
    @Published var toastMessage: String = ""
    @Published var showingToast: Bool = false

    init() {
        let cats = Self.buildCategories()
        self.categories = cats

        // Detect current state for every tweak
        var states: [String: Bool] = [:]
        for cat in cats {
            for tweak in cat.tweaks {
                states[tweak.id] = tweak.detect()
            }
        }
        self.tweakStates = states
    }

    // MARK: - Toggle

    func toggle(_ tweak: DebloatTweak) {
        let currentlyOn = tweakStates[tweak.id] ?? false
        let applyNow = !currentlyOn // we want to flip

        busyTweaks.insert(tweak.id)

        DispatchQueue.global(qos: .userInitiated).async {
            let success: Bool
            if applyNow {
                success = Self.execute(tweak.applyCommands, privileged: tweak.applyPrivileged)
            } else {
                success = Self.execute(tweak.revertCommands, privileged: tweak.revertPrivileged)
            }

            let newState = tweak.detect()

            Task { @MainActor in
                self.tweakStates[tweak.id] = newState
                self.busyTweaks.remove(tweak.id)

                if success && newState == applyNow {
                    self.toast("\(tweak.name) \(applyNow ? "applied" : "reverted")")
                } else if !success {
                    self.toast("Failed to \(applyNow ? "apply" : "revert") \(tweak.name)")
                } else {
                    // Command ran but state didn't change as expected
                    self.toast("\(tweak.name) — verify manually")
                }
            }
        }
    }

    /// Apply all tweaks in a category that aren't already applied
    func applyAll(in category: DebloatCategory) {
        let unapplied = category.tweaks.filter { !(tweakStates[$0.id] ?? false) }
        guard !unapplied.isEmpty else {
            toast("All \(category.name) tweaks already applied")
            return
        }

        for tweak in unapplied {
            busyTweaks.insert(tweak.id)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var applied = 0
            var detectedStates: [String: Bool] = [:]
            for tweak in unapplied {
                let ok = Self.execute(tweak.applyCommands, privileged: tweak.applyPrivileged)
                let newState = tweak.detect()
                detectedStates[tweak.id] = newState
                if ok && newState { applied += 1 }
            }
            let appliedCount = applied
            Task { @MainActor in
                for (id, state) in detectedStates {
                    self.tweakStates[id] = state
                    self.busyTweaks.remove(id)
                }
                self.toast("Applied \(appliedCount)/\(unapplied.count) \(category.name) tweaks")
            }
        }
    }

    /// Revert all tweaks in a category that are currently applied
    func revertAll(in category: DebloatCategory) {
        let applied = category.tweaks.filter { tweakStates[$0.id] ?? false }
        guard !applied.isEmpty else {
            toast("No \(category.name) tweaks to revert")
            return
        }

        for tweak in applied {
            busyTweaks.insert(tweak.id)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var reverted = 0
            var detectedStates: [String: Bool] = [:]
            for tweak in applied {
                let ok = Self.execute(tweak.revertCommands, privileged: tweak.revertPrivileged)
                let newState = tweak.detect()
                detectedStates[tweak.id] = newState
                if ok && !newState { reverted += 1 }
            }
            let revertedCount = reverted
            Task { @MainActor in
                for (id, state) in detectedStates {
                    self.tweakStates[id] = state
                    self.busyTweaks.remove(id)
                }
                self.toast("Reverted \(revertedCount)/\(applied.count) \(category.name) tweaks")
            }
        }
    }

    /// Revert all applied tweaks across all categories
    func revertAllTweaks() {
        // We use .lazy to avoid multiple intermediate collection allocations during the
        // traversal. We convert to Array once at the end to pass a stable, thread-safe
        // snapshot to the background execution block.
        let appliedArray = Array(categories
            .lazy
            .flatMap { $0.tweaks }
            .filter { self.tweakStates[$0.id] == true })

        guard !appliedArray.isEmpty else {
            toast("No tweaks to revert")
            return
        }

        for tweak in appliedArray {
            busyTweaks.insert(tweak.id)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var reverted = 0
            var detectedStates: [String: Bool] = [:]
            for tweak in appliedArray {
                let ok = Self.execute(tweak.revertCommands, privileged: tweak.revertPrivileged)
                let newState = tweak.detect()
                detectedStates[tweak.id] = newState
                if ok && !newState { reverted += 1 }
            }
            let revertedCount = reverted
            Task { @MainActor in
                for (id, state) in detectedStates {
                    self.tweakStates[id] = state
                    self.busyTweaks.remove(id)
                }
                self.toast("Reverted \(revertedCount)/\(appliedArray.count) total tweaks")
            }
        }
    }

    /// Refresh detected states for all tweaks
    func refreshAll() {
        let categorySnapshot = categories
        DispatchQueue.global(qos: .utility).async {
            var states: [String: Bool] = [:]
            for cat in categorySnapshot {
                for tweak in cat.tweaks {
                    states[tweak.id] = tweak.detect()
                }
            }
            Task { @MainActor in
                self.tweakStates = states
                self.toast("Refreshed all tweak states")
            }
        }
    }

    /// Restart Finder, Dock, SystemUIServer
    func restartUI() {
        for processName in ["Finder", "Dock", "SystemUIServer", "cfprefsd"] {
            _ = runValidatedCommand("killall \(processName) 2>/dev/null || true", privileged: false)
        }
        toast("Restarted Finder, Dock & SystemUIServer")
    }

    var appliedCount: Int {
        tweakStates.values.filter { $0 }.count
    }

    var totalCount: Int {
        tweakStates.count
    }

    // MARK: - Private

    func toast(_ msg: String) {
        DispatchQueue.main.async {
            self.toastMessage = msg
            self.showingToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.showingToast = false
            }
        }
    }

    nonisolated private static func execute(_ userCmds: [String], privileged: [String]) -> Bool {
        var ok = true
        var hasDefaultsCmd = false

        for cmd in userCmds {
            if cmd.contains("defaults ") { hasDefaultsCmd = true }
            if !runValidatedCommand(cmd, privileged: false) { ok = false }
        }

        for cmd in privileged {
            if cmd.contains("defaults ") { hasDefaultsCmd = true }
            if !runValidatedCommand(cmd, privileged: true) { ok = false }
        }

        // Kill cfprefsd to force preference cache flush after defaults changes
        if hasDefaultsCmd {
            _ = runValidatedCommand("killall cfprefsd 2>/dev/null || true", privileged: false)
        }

        // Wait for cfprefsd to respawn and launchctl to sync
        Thread.sleep(forTimeInterval: 0.5)

        return ok
    }

    @discardableResult
    nonisolated private func runValidatedCommand(_ command: String, privileged: Bool) -> Bool {
        Self.runValidatedCommand(command, privileged: privileged)
    }

    @discardableResult
    nonisolated static func runValidatedCommand(_ command: String, privileged: Bool) -> Bool {
        guard let debloatCommand = DebloatCommand.parse(command) else {
            MiloLog.error("Rejected unsupported debloat command: \(command)", category: .security)
            return false
        }
        return debloatCommand.run(privileged: privileged)
    }

    nonisolated static func canParseValidatedCommand(_ command: String) -> Bool {
        DebloatCommand.parse(command) != nil
    }

    // MARK: - Detection Helpers

    /// Read a defaults key. Returns the trimmed stdout or nil.
    nonisolated private static func readDefault(_ domain: String, _ key: String) -> String? {
        let result = CommandRunner.run("/usr/bin/defaults", arguments: ["read", domain, key])
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Read a defaults key using -currentHost (for ByHost plists)
    nonisolated private static func readDefaultCurrentHost(_ domain: String, _ key: String) -> String? {
        let result = CommandRunner.run("/usr/bin/defaults", arguments: ["-currentHost", "read", domain, key])
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if a defaults bool key is set to the expected value
    nonisolated static func defaultsIs(_ domain: String, _ key: String, expected: Bool) -> Bool {
        guard let val = readDefault(domain, key) else { return false }
        if expected {
            return val == "1" || val.lowercased() == "true"
        } else {
            return val == "0" || val.lowercased() == "false"
        }
    }

    /// Check if a ByHost defaults bool key is set to the expected value
    nonisolated static func defaultsCurrentHostIs(_ domain: String, _ key: String, expected: Bool) -> Bool {
        guard let val = readDefaultCurrentHost(domain, key) else { return false }
        if expected {
            return val == "1" || val.lowercased() == "true"
        } else {
            return val == "0" || val.lowercased() == "false"
        }
    }

    /// Check if a defaults key equals a specific string
    nonisolated static func defaultsEquals(_ domain: String, _ key: String, value: String) -> Bool {
        guard let val = readDefault(domain, key) else { return false }
        return val == value
    }

    /// Check if a defaults int key equals a specific value
    nonisolated static func defaultsIntEquals(_ domain: String, _ key: String, value: Int) -> Bool {
        guard let val = readDefault(domain, key) else { return false }
        return val == "\(value)"
    }

    /// Check if a defaults float key approximately equals a value
    nonisolated static func defaultsFloatClose(_ domain: String, _ key: String, value: Double, tolerance: Double = 0.01) -> Bool {
        guard let val = readDefault(domain, key), let d = Double(val) else { return false }
        return abs(d - value) < tolerance
    }

    nonisolated static let widgetMarkerPath: String = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("milo-widgets-disabled.marker").path
        }
        let dir = appSupport.appendingPathComponent("Milo", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return FileManager.default.temporaryDirectory.appendingPathComponent("milo-widgets-disabled.marker").path
        }
        return dir.appendingPathComponent("widgets-disabled.marker").path
    }()

    nonisolated static func widgetMarkerExists() -> Bool {
        FileManager.default.fileExists(atPath: widgetMarkerPath)
    }

    nonisolated private static func pluginElectionStates() -> [String: Character] {
        let result = CommandRunner.run("/usr/bin/pluginkit", arguments: ["-mAvv"])
        guard result.succeeded else {
            return [:]
        }

        let widgetIDs = Set(ProcessData.widgetBundleIDs)
        var states: [String: Character] = [:]

        for line in result.stdout.components(separatedBy: .newlines) {
            guard let first = line.first, first == "+" || first == "-" || first == " " else { continue }
            let payload = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard let openParen = payload.firstIndex(of: "(") else { continue }
            let identifier = String(payload[..<openParen])
            guard widgetIDs.contains(identifier) else { continue }
            states[identifier] = first
        }

        return states
    }

    nonisolated static func ignoredWidgetBundleIDs() -> [String] {
        let elections = pluginElectionStates()
        return ProcessData.widgetBundleIDs.filter { elections[$0] == "-" }
    }

    nonisolated static func presentWidgetBundleIDs() -> [String] {
        let elections = pluginElectionStates()
        return ProcessData.widgetBundleIDs.filter { elections[$0] != nil }
    }

    nonisolated static func areWidgetExtensionsIgnored() -> Bool {
        let present = presentWidgetBundleIDs()
        guard !present.isEmpty else { return false }
        let ignored = Set(ignoredWidgetBundleIDs())
        return present.allSatisfy { ignored.contains($0) }
    }

    nonisolated static func anyWidgetProcessesRunning() -> Bool {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "command"])
        guard result.succeeded else {
            return false
        }
        return result.stdout
            .components(separatedBy: .newlines)
            .contains { line in
                let lower = line.lowercased()
                return lower.contains(".appex/contents/macos/") && lower.contains("widget")
            }
    }

    /// Check if a launchctl service is disabled for the current user (gui/ domain)
    nonisolated static func isLaunchctlDisabled(label: String) -> Bool {
        let uid = getuid()
        let result = CommandRunner.run("/bin/launchctl", arguments: ["print-disabled", "gui/\(uid)"])
        guard result.succeeded else { return false }
        let pattern = "\"\(label)\""
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(pattern) && trimmed.contains("=> disabled") {
                return true
            }
        }
        return false
    }

    /// Check if a system-level launchctl service is disabled (requires sudo -n)
    nonisolated static func isSystemLaunchctlDisabled(label: String) -> Bool {
        let result = CommandRunner.run("/usr/bin/sudo", arguments: ["-n", "/bin/launchctl", "print-disabled", "system"])
        guard result.succeeded else { return false }
        let pattern = "\"\(label)\""
        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(pattern) && trimmed.contains("=> disabled") {
                return true
            }
        }
        return false
    }

    nonisolated private static let appStoreBetaLoopLaunchdLabels = [
        "com.apple.appstoreagent",
        "com.apple.appstorecomponentsd",
        "com.apple.appstorecomponentsd.xpc",
        "com.apple.private.appintents.delegate.com.apple.appstorecomponentsd"
    ]

    nonisolated private static func appStoreBetaLoopDisabled() -> Bool {
        let autoUpdateDisabled = defaultsIs("com.apple.commerce", "AutoUpdate", expected: false)
            && defaultsIs("com.apple.commerce", "AutoUpdateCheckEnabled", expected: false)
        let labelsDisabled = appStoreBetaLoopLaunchdLabels.allSatisfy { label in
            isLaunchctlDisabled(label: label)
        }
        return autoUpdateDisabled && labelsDisabled
    }

    // MARK: - Category Definitions

    nonisolated static func buildCategories() -> [DebloatCategory] {
        let uid = getuid()

        return [
            // ─────────────────────────────────────────────────────────
            // 1. ANIMATIONS
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "animations",
                name: "Kill Animations",
                description: "Disable window, Dock, and Mission Control animations",
                icon: "bolt.slash.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "anim.window",
                        name: "Disable Window Animations",
                        description: "No open/close animation for windows",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "anim.expose",
                        name: "Fast Mission Control",
                        description: "Speed up Exposé / Spaces animation",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.dock expose-animation-duration -float 0.1"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.dock expose-animation-duration 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsFloatClose("com.apple.dock", "expose-animation-duration", value: 0.1) }
                    ),
                    DebloatTweak(
                        id: "anim.banner",
                        name: "Shorter Notification Banners",
                        description: "Reduce banner display time to 3 seconds",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.notificationcenterui bannerTime -int 3"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.notificationcenterui bannerTime 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIntEquals("com.apple.notificationcenterui", "bannerTime", value: 3) }
                    ),
                    DebloatTweak(
                        id: "anim.reducemotion",
                        name: "Reduce Motion",
                        description: "System-wide reduced motion (kills parallax, slide-overs)",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.universalaccess reduceMotion -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.universalaccess reduceMotion 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.universalaccess", "reduceMotion", expected: true) }
                    ),
                    DebloatTweak(
                        id: "anim.sheet",
                        name: "Instant Dialogs",
                        description: "Speed up sheet/dialog animations",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSWindowResizeTime -float 0.001"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSWindowResizeTime 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsFloatClose("NSGlobalDomain", "NSWindowResizeTime", value: 0.001) }
                    ),
                    DebloatTweak(
                        id: "anim.hotcorner",
                        name: "Disable Quick Note Hot Corner",
                        description: "Prevent accidental Quick Note trigger from bottom-right",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.dock wvous-br-corner -int 0"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.dock wvous-br-corner 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIntEquals("com.apple.dock", "wvous-br-corner", value: 0) }
                    ),
                    DebloatTweak(
                        id: "anim.launchpad",
                        name: "Fast Launchpad Animation",
                        description: "Speed up Launchpad show/hide animation",
                        category: "animations", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: [
                            "defaults write com.apple.dock springboard-show-duration -float 0.1",
                            "defaults write com.apple.dock springboard-hide-duration -float 0.1"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.dock springboard-show-duration 2>/dev/null || true",
                            "defaults delete com.apple.dock springboard-hide-duration 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsFloatClose("com.apple.dock", "springboard-show-duration", value: 0.1) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 2. VISUAL EFFECTS
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "visual",
                name: "Visual Effects",
                description: "Remove transparency, restore solid UI",
                icon: "eye.slash.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "vis.transparency",
                        name: "Reduce Transparency",
                        description: "Solid menu bar, dock, and sidebars",
                        category: "visual", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.universalaccess reduceTransparency -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.universalaccess reduceTransparency 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.universalaccess", "reduceTransparency", expected: true) }
                    ),
                    DebloatTweak(
                        id: "vis.contrast",
                        name: "Increase Contrast",
                        description: "Crisp, defined UI borders (classic Mac feel)",
                        category: "visual", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.universalaccess increaseContrast -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.universalaccess increaseContrast 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.universalaccess", "increaseContrast", expected: true) }
                    ),
                    DebloatTweak(
                        id: "vis.menubar",
                        name: "Persistent Menu Bar",
                        description: "Always show menu bar background in fullscreen",
                        category: "visual", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain AppleMenuBarVisibleInFullscreen 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "AppleMenuBarVisibleInFullscreen", expected: true) }
                    ),
                    DebloatTweak(
                        id: "vis.tinting",
                        name: "Disable Desktop Tinting",
                        description: "Stop wallpaper tinting in windows",
                        category: "visual", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain AppleReduceDesktopTinting -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain AppleReduceDesktopTinting 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "AppleReduceDesktopTinting", expected: true) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 3. APPLE INTELLIGENCE & SIRI
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "ai",
                name: "Apple Intelligence & Siri",
                description: "Disable AI features, Writing Tools, Siri, suggestions",
                icon: "brain",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "ai.intelligence",
                        name: "Disable Apple Intelligence",
                        description: "Turns off Writing Tools, Genmoji, Image Playground",
                        category: "ai", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.AppleIntelligence Enabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.AppleIntelligence Enabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.AppleIntelligence", "Enabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "ai.writingtools",
                        name: "Disable Writing Tools",
                        description: "No AI writing suggestions in text fields",
                        category: "ai", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSWritingToolsAllowed -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSWritingToolsAllowed 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSWritingToolsAllowed", expected: false) }
                    ),
                    DebloatTweak(
                        id: "ai.predictions",
                        name: "Disable Inline Predictions",
                        description: "No predictive text / inline predictions",
                        category: "ai", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSAutomaticInlinePredictionEnabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSAutomaticInlinePredictionEnabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAutomaticInlinePredictionEnabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "ai.siri",
                        name: "Disable Siri",
                        description: "Turn off Siri completely and hide from menu bar",
                        category: "ai", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.assistant.support \"Assistant Enabled\" -bool false",
                            "defaults write com.apple.Siri StatusMenuVisible -bool false",
                            "defaults write com.apple.Siri UserHasDeclinedEnable -bool true",
                            "launchctl disable gui/\(uid)/com.apple.Siri.agent 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.siriknowledged 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults write com.apple.assistant.support \"Assistant Enabled\" -bool true",
                            "defaults delete com.apple.Siri StatusMenuVisible 2>/dev/null || true",
                            "defaults delete com.apple.Siri UserHasDeclinedEnable 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.Siri.agent 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.siriknowledged 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.assistant.support", "Assistant Enabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "ai.suggestions",
                        name: "Disable Siri Suggestions",
                        description: "No Siri suggestions in Spotlight or Look Up",
                        category: "ai", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.suggestions SuggestionsAllowedInSpotlight -bool false",
                            "defaults write com.apple.suggestions SuggestionsAllowedInLookUp -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.suggestions SuggestionsAllowedInSpotlight 2>/dev/null || true",
                            "defaults delete com.apple.suggestions SuggestionsAllowedInLookUp 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.suggestions", "SuggestionsAllowedInSpotlight", expected: false) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 4. BACKGROUND SERVICES
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "services",
                name: "Background Services",
                description: "Game Center, Tips, knowledge daemons, Spotlight, analytics",
                icon: "gearshape.2.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "svc.gamecenter",
                        name: "Disable Game Center",
                        description: "Kill Game Center overlay and daemon",
                        category: "services", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.gamed enabled -bool false",
                            "launchctl disable gui/\(uid)/com.apple.gamed 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.gamed enabled 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.gamed 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.gamed", "enabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "svc.tips",
                        name: "Disable Tips",
                        description: "Stop Tips notifications daemon",
                        category: "services", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["launchctl disable gui/\(uid)/com.apple.tipsd 2>/dev/null || true"],
                        applyPrivileged: [],
                        revertCommands: ["launchctl enable gui/\(uid)/com.apple.tipsd 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.tipsd") }
                    ),
                    DebloatTweak(
                        id: "svc.appstore.beta-loop",
                        name: "Contain App Store Beta Loop",
                        description: "Stops App Store and Arcade background agents that can spike CPU on macOS beta builds",
                        category: "services", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.commerce AutoUpdate -bool false",
                            "defaults write com.apple.commerce AutoUpdateRestartRequired -bool false",
                            "defaults write com.apple.commerce AutoUpdatePreRelease -bool false",
                            "defaults write com.apple.commerce AutoUpdateCheckEnabled -bool false"
                        ] + appStoreBetaLoopLaunchdLabels.flatMap { label in
                            [
                                "launchctl disable gui/\(uid)/\(label) 2>/dev/null || true",
                                "launchctl bootout gui/\(uid)/\(label) 2>/dev/null || true"
                            ]
                        },
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.commerce AutoUpdate 2>/dev/null || true",
                            "defaults delete com.apple.commerce AutoUpdateRestartRequired 2>/dev/null || true",
                            "defaults delete com.apple.commerce AutoUpdatePreRelease 2>/dev/null || true",
                            "defaults delete com.apple.commerce AutoUpdateCheckEnabled 2>/dev/null || true"
                        ] + appStoreBetaLoopLaunchdLabels.map { label in
                            "launchctl enable gui/\(uid)/\(label) 2>/dev/null || true"
                        },
                        revertPrivileged: [],
                        detect: { appStoreBetaLoopDisabled() }
                    ),
                    DebloatTweak(
                        id: "svc.widgets",
                        name: "Disable Widgets",
                        description: "Ignore widget extensions and kill widget background processes",
                        category: "services", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: ProcessData.widgetBundleIDs.map { "pluginkit -e ignore -i '\($0)' 2>/dev/null || true" } + [
                            "touch '\(widgetMarkerPath)'",
                            "ps -Axo pid=,command= | /usr/bin/awk '/\\.appex\\/Contents\\/MacOS\\// && tolower($0) ~ /widget/ {print $1}' | /usr/bin/xargs -n1 /bin/kill -9 2>/dev/null || true",
                            "killall NotificationCenter 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: ProcessData.widgetBundleIDs.map { "pluginkit -e use -i '\($0)' 2>/dev/null || true" } + [
                            "rm -f '\(widgetMarkerPath)'",
                            "killall NotificationCenter 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { areWidgetExtensionsIgnored() || (widgetMarkerExists() && !anyWidgetProcessesRunning()) }
                    ),
                    DebloatTweak(
                        id: "svc.knowledge",
                        name: "Disable Knowledge Daemons",
                        description: "Stop knowledge-agent, suggestd, proactived",
                        category: "services", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.knowledge-agent 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.suggestd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.proactived 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.knowledge-agent 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.suggestd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.proactived 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.knowledge-agent") }
                    ),
                    DebloatTweak(
                        id: "svc.spotlight",
                        name: "Disable Spotlight Indexing",
                        description: "Stop indexing on all volumes (use Raycast/Alfred)",
                        category: "services", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: ["mdutil -a -i off 2>/dev/null || true"],
                        revertCommands: [],
                        revertPrivileged: ["mdutil -a -i on 2>/dev/null || true"],
                        detect: {
                            let result = CommandRunner.run("/usr/bin/mdutil", arguments: ["-s", "/"])
                            guard result.succeeded else { return false }
                            return result.stdout.lowercased().contains("indexing disabled")
                        }
                    ),
                    DebloatTweak(
                        id: "svc.analytics",
                        name: "Disable Analytics & Crash Reports",
                        description: "Stop sharing feedback and crash data with Apple",
                        category: "services", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.appleseed.FeedbackAssistant Autogather -bool false",
                            "defaults write com.apple.CrashReporter DialogType none"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.appleseed.FeedbackAssistant Autogather 2>/dev/null || true",
                            "defaults delete com.apple.CrashReporter DialogType 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.appleseed.FeedbackAssistant", "Autogather", expected: false) }
                    ),
                    DebloatTweak(
                        id: "svc.airplay",
                        name: "Disable AirPlay Receiver",
                        description: "Prevent Mac from being an AirPlay target",
                        category: "services", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.controlcenter \"NSStatusItem Visible AirplayReceiver\" -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.controlcenter \"NSStatusItem Visible AirplayReceiver\" 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.controlcenter", "NSStatusItem Visible AirplayReceiver", expected: false) }
                    ),
                    DebloatTweak(
                        id: "svc.sharedsug",
                        name: "Disable Shared Suggestions",
                        description: "Stop sharing suggestions between devices via iCloud",
                        category: "services", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.suggestions SuggestionsAllowedInShare -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.suggestions SuggestionsAllowedInShare 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.suggestions", "SuggestionsAllowedInShare", expected: false) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 5. FINDER
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "finder",
                name: "Finder — Pro Mode",
                description: "Hidden files, POSIX paths, path bar, no .DS_Store",
                icon: "folder.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "finder.posix",
                        name: "POSIX Path in Title Bar",
                        description: "Show full path in Finder title bar",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.finder _FXShowPosixPathInTitle -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder _FXShowPosixPathInTitle 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "_FXShowPosixPathInTitle", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.extensions",
                        name: "Show All Extensions",
                        description: "Show all file extensions",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write NSGlobalDomain AppleShowAllExtensions -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain AppleShowAllExtensions 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "AppleShowAllExtensions", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.hidden",
                        name: "Show Hidden Files",
                        description: "Reveal dot-files in Finder",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.finder AppleShowAllFiles -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder AppleShowAllFiles 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "AppleShowAllFiles", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.pathbar",
                        name: "Show Path Bar & Status Bar",
                        description: "Path bar at bottom, status bar with file info",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: [
                            "defaults write com.apple.finder ShowPathbar -bool true",
                            "defaults write com.apple.finder ShowStatusBar -bool true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.finder ShowPathbar 2>/dev/null || true",
                            "defaults delete com.apple.finder ShowStatusBar 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "ShowPathbar", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.tags",
                        name: "Hide Recent Tags",
                        description: "Don't show recent tags in Finder sidebar",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.finder ShowRecentTags -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder ShowRecentTags 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "ShowRecentTags", expected: false) }
                    ),
                    DebloatTweak(
                        id: "finder.trash",
                        name: "No Trash Warning",
                        description: "Skip confirmation when emptying Trash",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.finder WarnOnEmptyTrash -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder WarnOnEmptyTrash 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "WarnOnEmptyTrash", expected: false) }
                    ),
                    DebloatTweak(
                        id: "finder.dsstore",
                        name: "No .DS_Store on Network/USB",
                        description: "Avoid .DS_Store on external and network drives",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true",
                            "defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null || true",
                            "defaults delete com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.desktopservices", "DSDontWriteNetworkStores", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.search",
                        name: "Search Current Folder First",
                        description: "Default Finder search to current folder",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.finder FXDefaultSearchScope -string \"SCcf\""],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder FXDefaultSearchScope 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsEquals("com.apple.finder", "FXDefaultSearchScope", value: "SCcf") }
                    ),
                    DebloatTweak(
                        id: "finder.foldersFirst",
                        name: "Folders on Top",
                        description: "Keep folders above files when sorting by name",
                        category: "finder", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.finder _FXSortFoldersFirst -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.finder _FXSortFoldersFirst 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "_FXSortFoldersFirst", expected: true) }
                    ),
                    DebloatTweak(
                        id: "finder.icloud",
                        name: "Disable iCloud Desktop & Documents",
                        description: "Stop iCloud syncing Desktop & Documents",
                        category: "finder", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.finder FXICloudDriveDesktop -bool false",
                            "defaults write com.apple.finder FXICloudDriveDocuments -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.finder FXICloudDriveDesktop 2>/dev/null || true",
                            "defaults delete com.apple.finder FXICloudDriveDocuments 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.finder", "FXICloudDriveDesktop", expected: false) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 6. DOCK
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "dock",
                name: "Dock — Minimal",
                description: "Hide recent apps, auto-hide Dock, tweak behavior",
                icon: "dock.rectangle",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "dock.recents",
                        name: "Hide Recent Apps",
                        description: "Don't show recent apps in the Dock",
                        category: "dock", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.dock show-recents -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.dock show-recents 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.dock", "show-recents", expected: false) }
                    ),
                    DebloatTweak(
                        id: "dock.autohide",
                        name: "Auto-Hide Dock",
                        description: "Automatically hide the Dock when not in use",
                        category: "dock", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.dock autohide -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.dock autohide 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.dock", "autohide", expected: true) }
                    ),
                    DebloatTweak(
                        id: "dock.autohidedelay",
                        name: "Instant Dock Auto-Hide",
                        description: "Remove auto-hide delay for faster Dock appearance",
                        category: "dock", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: [
                            "defaults write com.apple.dock autohide-delay -float 0",
                            "defaults write com.apple.dock autohide-time-modifier -float 0.3"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.dock autohide-delay 2>/dev/null || true",
                            "defaults delete com.apple.dock autohide-time-modifier 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsFloatClose("com.apple.dock", "autohide-delay", value: 0.0) }
                    ),
                    DebloatTweak(
                        id: "dock.singleapp",
                        name: "Single App Mode",
                        description: "Clicking a Dock icon hides all other apps",
                        category: "dock", requiresSIP: false,
                        risk: .safe, needsRestart: true,
                        applyCommands: ["defaults write com.apple.dock single-app -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.dock single-app 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.dock", "single-app", expected: true) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 7. SAFARI & MAIL
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "safari",
                name: "Safari & Mail",
                description: "Developer mode, privacy, tracking protection",
                icon: "safari.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "safari.devmenu",
                        name: "Enable Develop Menu",
                        description: "Show Developer menu and Web Inspector in Safari",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.Safari IncludeDevelopMenu -bool true",
                            "defaults write com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true",
                            "defaults write com.apple.Safari \"com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled\" -bool true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.Safari IncludeDevelopMenu 2>/dev/null || true",
                            "defaults delete com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey 2>/dev/null || true",
                            "defaults delete com.apple.Safari \"com.apple.Safari.ContentPageGroupIdentifier.WebKit2DeveloperExtrasEnabled\" 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.Safari", "IncludeDevelopMenu", expected: true) }
                    ),
                    DebloatTweak(
                        id: "safari.fullurl",
                        name: "Show Full URL",
                        description: "Display the full URL in Safari's address bar",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.Safari ShowFullURLInSmartSearchField -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.Safari ShowFullURLInSmartSearchField 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.Safari", "ShowFullURLInSmartSearchField", expected: true) }
                    ),
                    DebloatTweak(
                        id: "safari.dnt",
                        name: "Send Do Not Track",
                        description: "Send Do Not Track header to websites",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.Safari SendDoNotTrackHTTPHeader -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.Safari SendDoNotTrackHTTPHeader 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.Safari", "SendDoNotTrackHTTPHeader", expected: true) }
                    ),
                    DebloatTweak(
                        id: "safari.autofill",
                        name: "Disable AutoFill",
                        description: "Stop Safari from auto-filling forms",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.Safari AutoFillFromAddressBook -bool false",
                            "defaults write com.apple.Safari AutoFillCreditCardData -bool false",
                            "defaults write com.apple.Safari AutoFillMiscellaneousForms -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.Safari AutoFillFromAddressBook 2>/dev/null || true",
                            "defaults delete com.apple.Safari AutoFillCreditCardData 2>/dev/null || true",
                            "defaults delete com.apple.Safari AutoFillMiscellaneousForms 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.Safari", "AutoFillFromAddressBook", expected: false) }
                    ),
                    DebloatTweak(
                        id: "mail.attachinline",
                        name: "Mail: Inline Attachments",
                        description: "Show attachments as icons instead of inline",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.mail DisableInlineAttachmentViewing -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.mail DisableInlineAttachmentViewing 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.mail", "DisableInlineAttachmentViewing", expected: true) }
                    ),
                    DebloatTweak(
                        id: "mail.remoteimages",
                        name: "Mail: Block Remote Images",
                        description: "Block remote content to prevent tracking pixels",
                        category: "safari", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write com.apple.mail-shared DisableURLLoading -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.mail-shared DisableURLLoading 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.mail-shared", "DisableURLLoading", expected: true) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 8. PRIVACY
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "privacy",
                name: "Privacy Hardening",
                description: "Block ad tracking, disable Handoff, remote events",
                icon: "lock.shield.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "priv.adtracking",
                        name: "Disable Ad Tracking",
                        description: "Block personalised ads and ad identifiers",
                        category: "privacy", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.AdLib allowApplePersonalizedAdvertising -bool false",
                            "defaults write com.apple.AdLib allowIdentifierForAdvertising -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.AdLib allowApplePersonalizedAdvertising 2>/dev/null || true",
                            "defaults delete com.apple.AdLib allowIdentifierForAdvertising 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.AdLib", "allowApplePersonalizedAdvertising", expected: false) }
                    ),
                    DebloatTweak(
                        id: "priv.handoff",
                        name: "Disable Handoff",
                        description: "Stop background relay between Apple devices",
                        category: "privacy", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false",
                            "defaults -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults -currentHost delete com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null || true",
                            "defaults -currentHost delete com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: {
                            defaultsCurrentHostIs("com.apple.coreservices.useractivityd", "ActivityAdvertisingAllowed", expected: false)
                        }
                    ),
                    DebloatTweak(
                        id: "priv.remoteevents",
                        name: "Disable Remote Apple Events",
                        description: "Prevent remote AppleScript execution",
                        category: "privacy", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: ["launchctl unload -w /System/Library/LaunchDaemons/com.apple.eppc.plist"],
                        revertCommands: [],
                        revertPrivileged: ["launchctl load -w /System/Library/LaunchDaemons/com.apple.eppc.plist"],
                        detect: {
                            // launchctl print-disabled system works without sudo and is accurate.
                            // "com.apple.AEServer" => disabled means the tweak is applied.
                            let output = CommandRunner.run("/bin/launchctl", arguments: ["print-disabled", "system"]).stdout
                            return output.contains("\"com.apple.AEServer\" => disabled")
                        }
                    ),
                    DebloatTweak(
                        id: "priv.diagdata",
                        name: "Disable Diagnostic Data Sharing",
                        description: "Stop sending diagnostics & usage data to Apple",
                        category: "privacy", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.SubmitDiagInfo AutoSubmit -bool false",
                            "defaults write com.apple.SubmitDiagInfo ThirdPartyDataSubmit -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.SubmitDiagInfo AutoSubmit 2>/dev/null || true",
                            "defaults delete com.apple.SubmitDiagInfo ThirdPartyDataSubmit 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.SubmitDiagInfo", "AutoSubmit", expected: false) }
                    ),
                    DebloatTweak(
                        id: "priv.locationservices",
                        name: "Disable Location Services Daemon",
                        description: "Stop locationd from running in background",
                        category: "privacy", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.locationd 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.locationd 2>/dev/null || true"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.apple.locationd") }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 9. KEYBOARD
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "keyboard",
                name: "Keyboard & Input",
                description: "Disable autocorrect, fast key repeat, full keyboard access",
                icon: "keyboard.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "kb.autocorrect",
                        name: "Disable Autocorrect",
                        description: "Stop automatic spelling correction",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSAutomaticSpellingCorrectionEnabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAutomaticSpellingCorrectionEnabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "kb.fullaccess",
                        name: "Full Keyboard Access",
                        description: "Tab through all UI controls, not just text fields",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain AppleKeyboardUIMode -int 3"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain AppleKeyboardUIMode 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIntEquals("NSGlobalDomain", "AppleKeyboardUIMode", value: 3) }
                    ),
                    DebloatTweak(
                        id: "kb.fastrepeat",
                        name: "Fast Key Repeat",
                        description: "Fast key repeat rate and short initial delay",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write NSGlobalDomain KeyRepeat -int 2",
                            "defaults write NSGlobalDomain InitialKeyRepeat -int 15"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete NSGlobalDomain KeyRepeat 2>/dev/null || true",
                            "defaults delete NSGlobalDomain InitialKeyRepeat 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIntEquals("NSGlobalDomain", "KeyRepeat", value: 2) }
                    ),
                    DebloatTweak(
                        id: "kb.autocapitalize",
                        name: "Disable Auto-Capitalize",
                        description: "Stop automatic capitalization of first letter",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSAutomaticCapitalizationEnabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAutomaticCapitalizationEnabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "kb.smartdashes",
                        name: "Disable Smart Dashes & Quotes",
                        description: "Keep plain dashes and straight quotes for coding",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false",
                            "defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete NSGlobalDomain NSAutomaticDashSubstitutionEnabled 2>/dev/null || true",
                            "defaults delete NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAutomaticDashSubstitutionEnabled", expected: false) }
                    ),
                    DebloatTweak(
                        id: "kb.presshold",
                        name: "Key Repeat Instead of Accent Menu",
                        description: "Press-and-hold repeats key instead of showing accent picker",
                        category: "keyboard", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain ApplePressAndHoldEnabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "ApplePressAndHoldEnabled", expected: false) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 10. PERFORMANCE
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "performance",
                name: "Performance Tweaks",
                description: "Disable quarantine dialogs, expand panels, save to disk",
                icon: "gauge.with.dots.needle.33percent",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "perf.quarantine",
                        name: "Disable App Open Warning",
                        description: "Skip \"Are you sure you want to open this?\" dialog",
                        category: "performance", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: ["defaults write com.apple.LaunchServices LSQuarantine -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.LaunchServices LSQuarantine 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.LaunchServices", "LSQuarantine", expected: false) }
                    ),
                    DebloatTweak(
                        id: "perf.savepanel",
                        name: "Expand Save & Print Panels",
                        description: "Always expand save and print dialogs",
                        category: "performance", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true",
                            "defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true",
                            "defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true",
                            "defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete NSGlobalDomain NSNavPanelExpandedStateForSaveMode 2>/dev/null || true",
                            "defaults delete NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 2>/dev/null || true",
                            "defaults delete NSGlobalDomain PMPrintingExpandedStateForPrint 2>/dev/null || true",
                            "defaults delete NSGlobalDomain PMPrintingExpandedStateForPrint2 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSNavPanelExpandedStateForSaveMode", expected: true) }
                    ),
                    DebloatTweak(
                        id: "perf.savetodisk",
                        name: "Save to Disk by Default",
                        description: "New documents save to local disk, not iCloud",
                        category: "performance", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSDocumentSaveNewDocumentsToCloud 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSDocumentSaveNewDocumentsToCloud", expected: false) }
                    ),
                    DebloatTweak(
                        id: "perf.resume",
                        name: "Disable Resume",
                        description: "Don't reopen windows when logging back in",
                        category: "performance", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "defaults write com.apple.systempreferences NSQuitAlwaysKeepsWindows -bool false",
                            "defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "defaults delete com.apple.systempreferences NSQuitAlwaysKeepsWindows 2>/dev/null || true",
                            "defaults delete NSGlobalDomain NSQuitAlwaysKeepsWindows 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSQuitAlwaysKeepsWindows", expected: false) }
                    ),
                    DebloatTweak(
                        id: "perf.autoupdate",
                        name: "Disable Auto-Update Download",
                        description: "Check for software updates manually",
                        category: "performance", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: ["defaults write com.apple.SoftwareUpdate AutomaticDownload -bool false"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("com.apple.SoftwareUpdate", "AutomaticDownload", expected: false) }
                    ),
                    DebloatTweak(
                        id: "perf.appnap",
                        name: "Disable App Nap",
                        description: "Prevent macOS from throttling background apps",
                        category: "performance", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: ["defaults write NSGlobalDomain NSAppSleepDisabled -bool true"],
                        applyPrivileged: [],
                        revertCommands: ["defaults delete NSGlobalDomain NSAppSleepDisabled 2>/dev/null || true"],
                        revertPrivileged: [],
                        detect: { defaultsIs("NSGlobalDomain", "NSAppSleepDisabled", expected: true) }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 11. SYSTEM DAEMONS (SIP OFF)
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "daemons",
                name: "System Daemons (SIP Off)",
                description: "Disable AI, analytics, media, iCloud, and Apple app daemons",
                icon: "exclamationmark.shield.fill",
                requiresSIP: true,
                tweaks: [
                    DebloatTweak(
                        id: "daemon.ai",
                        name: "AI / ML Daemons",
                        description: "mediaanalysisd, intelligenceplatformd, Writing Tools, Image Playground",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.mediaanalysisd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.intelligenceplatformd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.WritingTools 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.imageplaygroundd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.generativedaemon 2>/dev/null || true"
                        ],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.mediaanalysisd 2>/dev/null || true",
                            "launchctl disable system/com.apple.intelligenceplatformd 2>/dev/null || true",
                            "launchctl disable system/com.apple.siri.morphunassetsupdaterd 2>/dev/null || true"
                        ],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.mediaanalysisd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.intelligenceplatformd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.WritingTools 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.imageplaygroundd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.generativedaemon 2>/dev/null || true"
                        ],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.mediaanalysisd 2>/dev/null || true",
                            "launchctl enable system/com.apple.intelligenceplatformd 2>/dev/null || true",
                            "launchctl enable system/com.apple.siri.morphunassetsupdaterd 2>/dev/null || true"
                        ],
                        detect: { isLaunchctlDisabled(label: "com.apple.mediaanalysisd") }
                    ),
                    DebloatTweak(
                        id: "daemon.siri",
                        name: "Siri Infrastructure",
                        description: "System-level Siri context service and TTS training",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.siri.context.service 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.SiriTTSTrainingAgent 2>/dev/null || true"
                        ],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.siri.context.service 2>/dev/null || true",
                            "launchctl disable system/com.apple.sirittsd 2>/dev/null || true"
                        ],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.siri.context.service 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.SiriTTSTrainingAgent 2>/dev/null || true"
                        ],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.siri.context.service 2>/dev/null || true",
                            "launchctl enable system/com.apple.sirittsd 2>/dev/null || true"
                        ],
                        detect: { isLaunchctlDisabled(label: "com.apple.siri.context.service") }
                    ),
                    DebloatTweak(
                        id: "daemon.icloud",
                        name: "iCloud Background Daemons",
                        description: "cloudpaird, cloudphotod, iCloudNotificationAgent",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.cloudpaird 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.cloudphotod 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.iCloudNotificationAgent 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.cloudpaird 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.cloudphotod 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.iCloudNotificationAgent 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.cloudpaird") }
                    ),
                    DebloatTweak(
                        id: "daemon.spotlight",
                        name: "Spotlight System Daemons",
                        description: "mds, mds.index, mds.spindump — breaks Spotlight entirely",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.metadata.mds 2>/dev/null || true",
                            "launchctl disable system/com.apple.metadata.mds.index 2>/dev/null || true",
                            "launchctl disable system/com.apple.metadata.mds.spindump 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.metadata.mds 2>/dev/null || true",
                            "launchctl enable system/com.apple.metadata.mds.index 2>/dev/null || true",
                            "launchctl enable system/com.apple.metadata.mds.spindump 2>/dev/null || true"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.apple.metadata.mds") }
                    ),
                    DebloatTweak(
                        id: "daemon.analytics",
                        name: "Analytics & Diagnostics",
                        description: "analyticsd, diagnosticd, ReportCrash, UsageTrackingAgent",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.ReportCrash 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.appleseed.seedusaged 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.UsageTrackingAgent 2>/dev/null || true"
                        ],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.analyticsd 2>/dev/null || true",
                            "launchctl disable system/com.apple.diagnosticd 2>/dev/null || true",
                            "launchctl disable system/com.apple.osanalytics.osanalyticshelper 2>/dev/null || true",
                            "launchctl disable system/com.apple.ReportCrash 2>/dev/null || true",
                            "launchctl disable system/com.apple.ReportCrash.Root 2>/dev/null || true"
                        ],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.ReportCrash 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.appleseed.seedusaged 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.UsageTrackingAgent 2>/dev/null || true"
                        ],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.analyticsd 2>/dev/null || true",
                            "launchctl enable system/com.apple.diagnosticd 2>/dev/null || true",
                            "launchctl enable system/com.apple.osanalytics.osanalyticshelper 2>/dev/null || true",
                            "launchctl enable system/com.apple.ReportCrash 2>/dev/null || true",
                            "launchctl enable system/com.apple.ReportCrash.Root 2>/dev/null || true"
                        ],
                        detect: { isLaunchctlDisabled(label: "com.apple.ReportCrash") }
                    ),
                    DebloatTweak(
                        id: "daemon.photos",
                        name: "Photo & Media Analysis",
                        description: "photoanalysisd, photolibraryd (face/scene recognition)",
                        category: "daemons", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.photoanalysisd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.photolibraryd 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.photoanalysisd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.photolibraryd 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.photoanalysisd") }
                    ),
                    DebloatTweak(
                        id: "daemon.bloatapps",
                        name: "Maps, News, Stocks, Home, TV, Wallet",
                        description: "Background daemons for unused Apple apps",
                        category: "daemons", requiresSIP: true,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.Maps.mapspushd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.Maps.pushdaemon 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.newsd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.stocks.stocksd 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.homed 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.TVCacheExtension 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.passd 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.Maps.mapspushd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.Maps.pushdaemon 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.newsd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.stocks.stocksd 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.homed 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.TVCacheExtension 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.passd 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.Maps.mapspushd") }
                    ),
                    DebloatTweak(
                        id: "daemon.screentime",
                        name: "Screen Time",
                        description: "Screen Time agent and system daemon",
                        category: "daemons", requiresSIP: true,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.ScreenTimeAgent 2>/dev/null || true"
                        ],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.screentime.screentime 2>/dev/null || true"
                        ],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.ScreenTimeAgent 2>/dev/null || true"
                        ],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.screentime.screentime 2>/dev/null || true"
                        ],
                        detect: { isLaunchctlDisabled(label: "com.apple.ScreenTimeAgent") }
                    ),
                    DebloatTweak(
                        id: "daemon.misc",
                        name: "Fax, Screen Sharing, Remote Desktop, Game Controller",
                        description: "Rarely-used system services",
                        category: "daemons", requiresSIP: true,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.fax.rastertofax 2>/dev/null || true",
                            "launchctl disable system/com.apple.screensharing 2>/dev/null || true",
                            "launchctl disable system/com.apple.RemoteDesktop.agent 2>/dev/null || true",
                            "launchctl disable system/com.apple.GameController.gamecontrollerd 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.fax.rastertofax 2>/dev/null || true",
                            "launchctl enable system/com.apple.screensharing 2>/dev/null || true",
                            "launchctl enable system/com.apple.RemoteDesktop.agent 2>/dev/null || true",
                            "launchctl enable system/com.apple.GameController.gamecontrollerd 2>/dev/null || true"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.apple.GameController.gamecontrollerd") }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 12. ADOBE BLOATWARE
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "adobe",
                name: "Adobe Bloatware",
                description: "Disable Creative Cloud background services, Finder extensions, and daemons",
                icon: "paintbrush.fill",
                requiresSIP: false,
                tweaks: [
                    DebloatTweak(
                        id: "adobe.creativecloud",
                        name: "Creative Cloud Agent",
                        description: "Main CC background app, updater, and desktop service",
                        category: "adobe", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.adobe.AdobeCreativeCloud 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.adobe.AdobeDesktopService 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.adobe.ccxprocess 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.adobe.CCXProcess.autostart 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.adobe.AdobeCreativeCloud 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.adobe.AdobeDesktopService 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.adobe.ccxprocess 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.adobe.CCXProcess.autostart 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.adobe.AdobeCreativeCloud") }
                    ),
                    DebloatTweak(
                        id: "adobe.sync",
                        name: "CoreSync & CCLibrary",
                        description: "File sync overlays and Creative Cloud libraries helper",
                        category: "adobe", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.adobe.CoreSync.helper 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.adobe.CCLibrary 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.adobe.CoreSync.helper 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.adobe.CCLibrary 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.adobe.CoreSync.helper") }
                    ),
                    DebloatTweak(
                        id: "adobe.updater",
                        name: "Adobe Update Helper",
                        description: "ARMDCHelper auto-update service (dynamic label)",
                        category: "adobe", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl print-disabled gui/\(uid) 2>/dev/null | grep -o '\"com.adobe.ARMDCHelper[^\"]*\"' | tr -d '\"' | while read label; do launchctl disable gui/\(uid)/$label 2>/dev/null; done || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl print-disabled gui/\(uid) 2>/dev/null | grep -o '\"com.adobe.ARMDCHelper[^\"]*\"' | tr -d '\"' | while read label; do launchctl enable gui/\(uid)/$label 2>/dev/null; done || true"
                        ],
                        revertPrivileged: [],
                        detect: {
                            // Check any ARMDCHelper label in gui/ domain
                            let uid = getuid()
                            let result = CommandRunner.run("/bin/launchctl", arguments: ["print-disabled", "gui/\(uid)"])
                            guard result.succeeded else { return false }
                            for line in result.stdout.components(separatedBy: .newlines) {
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if trimmed.contains("ARMDCHelper") && trimmed.contains("=> disabled") {
                                    return true
                                }
                            }
                            return false
                        }
                    ),
                    DebloatTweak(
                        id: "adobe.installer",
                        name: "Adobe Installer Daemon",
                        description: "Root-level privileged installer service (com.adobe.acc.installer.v2)",
                        category: "adobe", requiresSIP: false,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.adobe.acc.installer.v2",
                            "launchctl bootout system/com.adobe.acc.installer.v2 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.adobe.acc.installer.v2"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.adobe.acc.installer.v2") }
                    ),
                    DebloatTweak(
                        id: "adobe.finder",
                        name: "Finder Extensions",
                        description: "Disable Adobe Finder sync badges and context menu injection",
                        category: "adobe", requiresSIP: false,
                        risk: .safe, needsRestart: false,
                        applyCommands: [
                            "pluginkit -e ignore -i com.adobe.accmac.ACCFinderSync 2>/dev/null || true",
                            "pluginkit -e ignore -i com.adobe.acc.anc.AdobeCreativeCloud.AdobeContextMenuExtension 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "pluginkit -e use -i com.adobe.accmac.ACCFinderSync 2>/dev/null || true",
                            "pluginkit -e use -i com.adobe.acc.anc.AdobeCreativeCloud.AdobeContextMenuExtension 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: {
                            let result = CommandRunner.run("/usr/bin/pluginkit", arguments: ["-mA"])
                            guard result.succeeded else { return false }
                            for line in result.stdout.components(separatedBy: .newlines) {
                                if line.contains("ACCFinderSync") && line.hasPrefix("+") {
                                    return false
                                }
                            }
                            return true
                        }
                    )
                ]
            ),

            // ─────────────────────────────────────────────────────────
            // 13. STOCK APPS (SIP OFF)
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "stockapps",
                name: "Block Stock Apps (SIP Off)",
                description: "Quarantine unwanted system apps to prevent launching",
                icon: "xmark.app.fill",
                requiresSIP: true,
                tweaks: Self.stockAppTweaks()
            ),

            // ─────────────────────────────────────────────────────────
            // 14. ADVANCED (SIP OFF)
            // ─────────────────────────────────────────────────────────
            DebloatCategory(
                id: "advanced",
                name: "Advanced (SIP Off)",
                description: "Sidecar, Universal Control, Continuity, Journal, DND",
                icon: "wrench.and.screwdriver.fill",
                requiresSIP: true,
                tweaks: [
                    DebloatTweak(
                        id: "adv.sidecar",
                        name: "Disable Sidecar & Universal Control",
                        description: "Turn off iPad integration features",
                        category: "advanced", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.sidecar-relay 2>/dev/null || true",
                            "launchctl disable gui/\(uid)/com.apple.universalcontrol 2>/dev/null || true"
                        ],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.sidecar-relay 2>/dev/null || true"
                        ],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.sidecar-relay 2>/dev/null || true",
                            "launchctl enable gui/\(uid)/com.apple.universalcontrol 2>/dev/null || true"
                        ],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.sidecar-relay 2>/dev/null || true"
                        ],
                        detect: { isLaunchctlDisabled(label: "com.apple.sidecar-relay") }
                    ),
                    DebloatTweak(
                        id: "adv.continuity",
                        name: "Disable Continuity / Handoff (System)",
                        description: "Kill rapportd at system level",
                        category: "advanced", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.rapportd 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.rapportd 2>/dev/null || true"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.apple.rapportd") }
                    ),
                    DebloatTweak(
                        id: "adv.journal",
                        name: "Disable Journal Suggestions",
                        description: "Stop JournalingSuggestionsd daemon",
                        category: "advanced", requiresSIP: true,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.JournalingSuggestionsd 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.JournalingSuggestionsd 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.JournalingSuggestionsd") }
                    ),
                    DebloatTweak(
                        id: "adv.dnd",
                        name: "Disable Do Not Disturb Daemon",
                        description: "Kill donotdisturbd (manage focus manually)",
                        category: "advanced", requiresSIP: true,
                        risk: .moderate, needsRestart: false,
                        applyCommands: [
                            "launchctl disable gui/\(uid)/com.apple.donotdisturbd 2>/dev/null || true"
                        ],
                        applyPrivileged: [],
                        revertCommands: [
                            "launchctl enable gui/\(uid)/com.apple.donotdisturbd 2>/dev/null || true"
                        ],
                        revertPrivileged: [],
                        detect: { isLaunchctlDisabled(label: "com.apple.donotdisturbd") }
                    ),
                    DebloatTweak(
                        id: "adv.bluetooth",
                        name: "Disable Bluetooth Daemon",
                        description: "Kill bluetoothd when not using Bluetooth devices",
                        category: "advanced", requiresSIP: true,
                        risk: .aggressive, needsRestart: false,
                        applyCommands: [],
                        applyPrivileged: [
                            "launchctl disable system/com.apple.bluetoothd 2>/dev/null || true"
                        ],
                        revertCommands: [],
                        revertPrivileged: [
                            "launchctl enable system/com.apple.bluetoothd 2>/dev/null || true"
                        ],
                        detect: { isSystemLaunchctlDisabled(label: "com.apple.bluetoothd") }
                    )
                ]
            )
        ]
    }

    // MARK: - Stock App Tweaks

    nonisolated private static func stockAppTweaks() -> [DebloatTweak] {
        let apps: [(id: String, name: String)] = [
            ("chess", "Chess"),
            ("facetime", "FaceTime"),
            ("freeform", "Freeform"),
            ("home", "Home"),
            ("maps", "Maps"),
            ("news", "News"),
            ("stocks", "Stocks"),
            ("tv", "TV"),
            ("tips", "Tips"),
            ("imageplayground", "Image Playground")
        ]

        return apps.map { app in
            let sysPath = "/System/Applications/\(app.name).app"
            let userPath = "/Applications/\(app.name).app"

            return DebloatTweak(
                id: "stock.\(app.id)",
                name: "Block \(app.name)",
                description: "Quarantine \(app.name).app to prevent launching",
                category: "stockapps",
                requiresSIP: true,
                risk: .aggressive, needsRestart: false,
                applyCommands: [],
                applyPrivileged: [
                    "xattr -w com.apple.quarantine '0181;00000000;blocked;' '\(sysPath)' 2>/dev/null || true",
                    "xattr -w com.apple.quarantine '0181;00000000;blocked;' '\(userPath)' 2>/dev/null || true"
                ],
                revertCommands: [],
                revertPrivileged: [
                    "xattr -d com.apple.quarantine '\(sysPath)' 2>/dev/null || true",
                    "xattr -d com.apple.quarantine '\(userPath)' 2>/dev/null || true"
                ],
                detect: {
                    let result = CommandRunner.run("/usr/bin/xattr", arguments: ["-p", "com.apple.quarantine", sysPath])
                    guard result.succeeded else { return false }
                    return result.stdout.contains("blocked")
                }
            )
        }
    }
}
