import Foundation
import ServiceManagement
import os

/// Manages persistent user preferences for Milo
class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private init() {
        migrateLegacySettings()
    }

    // MARK: - Keys

    private enum Key {
        static let launchAtLogin       = "Milo.launchAtLogin"
        static let autoScanOnOpen      = "Milo.autoScanOnOpen"
        static let autoScanInterval    = "Milo.autoScanInterval"      // seconds, 0 = disabled
        static let confirmBeforeKill   = "Milo.confirmBeforeKill"
        static let showBadgeCount      = "Milo.showBadgeCount"
        static let showMemoryInHeader  = "Milo.showMemoryInHeader"
        static let notifyOnDetection   = "Milo.notifyOnDetection"
    }

    // MARK: - Properties

    /// Launch Milo automatically at login
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            configureLaunchAtLogin(newValue)
        }
    }

    /// Automatically scan for bloat when the popover opens
    var autoScanOnOpen: Bool {
        get { defaults.object(forKey: Key.autoScanOnOpen) == nil ? true : defaults.bool(forKey: Key.autoScanOnOpen) }
        set { defaults.set(newValue, forKey: Key.autoScanOnOpen) }
    }

    /// Periodic auto-scan interval in seconds (0 = disabled)
    var autoScanInterval: Int {
        get { defaults.integer(forKey: Key.autoScanInterval) }
        set { defaults.set(newValue, forKey: Key.autoScanInterval) }
    }

    /// Show kill confirmation dialog before terminating
    var confirmBeforeKill: Bool {
        get { defaults.object(forKey: Key.confirmBeforeKill) == nil ? true : defaults.bool(forKey: Key.confirmBeforeKill) }
        set { defaults.set(newValue, forKey: Key.confirmBeforeKill) }
    }

    /// Show bloat count badge on the status bar icon
    var showBadgeCount: Bool {
        get { defaults.object(forKey: Key.showBadgeCount) == nil ? true : defaults.bool(forKey: Key.showBadgeCount) }
        set {
            defaults.set(newValue, forKey: Key.showBadgeCount)
            // Post notification so AppDelegate picks it up
            NotificationCenter.default.post(name: .init("MiloBadgeSettingChanged"), object: newValue)
        }
    }

    /// Show memory pressure in the header bar
    var showMemoryInHeader: Bool {
        get { defaults.object(forKey: Key.showMemoryInHeader) == nil ? true : defaults.bool(forKey: Key.showMemoryInHeader) }
        set { defaults.set(newValue, forKey: Key.showMemoryInHeader) }
    }

    /// Legacy setting kept only so older persisted values can be neutralized.
    /// Milo no longer kills processes automatically; the user must select them.
    var autoKillOnDetect: Bool {
        get { false }
        set(ignoredValue) {
            _ = ignoredValue
            defaults.removeObject(forKey: "Milo.autoKillOnDetect")
        }
    }

    /// Send macOS notification when new bloat is detected
    var notifyOnDetection: Bool {
        get { defaults.bool(forKey: Key.notifyOnDetection) }
        set { defaults.set(newValue, forKey: Key.notifyOnDetection) }
    }

    // MARK: - Login Item

    /// Sync the current launchAtLogin setting with the OS at startup
    func syncLoginItemState() {
        let enabled = defaults.bool(forKey: Key.launchAtLogin)
        configureLaunchAtLogin(enabled)
    }

    private func configureLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            // Modern SMAppService API (macOS 13+)
            let service = SMAppService.mainApp
            do {
                if enable {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                Logger.settings.error("Failed to \(enable ? "register" : "unregister") login item: \(error, privacy: .public)")
            }
        } else {
            // Fallback: shared file list (deprecated but functional on 12)
            let success = SMLoginItemSetEnabled("com.monomacaw.milo" as CFString, enable)
            if !success {
                Logger.settings.error("SMLoginItemSetEnabled failed for \(enable)")
            }
        }
    }

    /// Read back the actual OS login item state
    func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            // Can't easily query on older OS; trust our stored value
            return defaults.bool(forKey: Key.launchAtLogin)
        }
    }

    private func migrateLegacySettings() {
        // Remove stale persisted auto-kill values from older builds and test runs.
        defaults.removeObject(forKey: "Milo.autoKillOnDetect")
    }
}
