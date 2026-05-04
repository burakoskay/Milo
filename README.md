# 💀 Milo

**Milo** is a high-performance macOS status bar application for power users, developers, and music producers who want explicit control over background processes and auto-start services.

Milo is intentionally local-first: no analytics, no network calls, no accounts, and no telemetry. It scans your Mac locally, asks before destructive process kills by default, and keeps passwordless privileged mode optional.

## 🚀 Key Features

- **Explicit Process Termination:** Detect and terminate selected resource-heavy helper processes from Adobe, Microsoft, Avid, and more.
- **Apple Intelligence Controls:** Detect Apple Intelligence, Siri, and telemetry-adjacent daemons (`siriknowledged`, `biomed`, `intelligenceplatformd`, etc.) so you can decide what to stop.
- **System Debloat:** Full macOS Tahoe debloat suite with 14 categories — animations, visual effects, Apple Intelligence, Safari/Mail privacy, Finder/Dock tuning, system daemons, Adobe background services, stock-app blocking, and advanced SIP-off tweaks. Every tweak is individually toggleable and revertible.
- **Auto-Start Manager:** Scans `LaunchAgents` and `LaunchDaemons` to detect persistent services. Toggle them `Enabled` or `Disabled` with immediate effect.
- **Preferences (⌘,):** Settings panel with Start at Login, auto-scan intervals, badge toggle, kill confirmation, privilege management, and system info.
- **Scan & Select UI:** See exactly what is running before you kill it. Choose individual processes or nuke them all.
- **SIP Awareness:** Real-time monitoring of System Integrity Protection (SIP) status. SIP-dependent debloat categories are clearly marked.
- **Native & Lightweight:** Written in Swift and SwiftUI. The expensive debloat state loads only when the Debloat sheet is opened.

## 🎯 Targeted Vendors

Milo comes pre-configured to detect common background helpers from:
- **Adobe Creative Cloud:** (CCXProcess, Core Sync, Adobe Desktop Service, etc.)
- **Audio Licensing:** (UAD, Antelope, Waves, PACE/iLok)
- **Utilities:** (CleanMyMac and similar cleanup/menu helpers)
- **Microsoft Office:** (AutoUpdate, Office365Service, Widgets)
- **Apple Telemetry:** (Siri, Biome, Triald, Knowledge-agent, etc.)

Password managers, VPNs, firewalls, and backup tools are deliberately excluded from the default target lists.

## 🔧 System Debloat Categories

The built-in debloat engine provides 14 categories of system-level tweaks. Each tweak can be toggled individually and reverted at any time.

| # | Category | SIP Required | What it does |
|---|----------|:---:|---|
| 1 | **Kill Animations** | No | Disable window, Mission Control, and dialog animations |
| 2 | **Visual Effects** | No | Remove Liquid Glass transparency, increase contrast |
| 3 | **Apple Intelligence & Siri** | No | Disable AI features, Writing Tools, inline predictions, Siri |
| 4 | **Background Services** | No | Kill Game Center, Tips, knowledge daemons, analytics |
| 5 | **Finder — Pro Mode** | No | POSIX paths, hidden files, path bar, no .DS_Store on USB |
| 6 | **Dock — Minimal** | No | Hide recent apps, auto-hide Dock |
| 7 | **Safari & Mail** | No | Safari developer mode, tracking protection, remote-content controls |
| 8 | **Privacy Hardening** | No | Block ad tracking, disable Handoff, remote events |
| 9 | **Keyboard & Input** | No | Disable autocorrect, fast key repeat, full keyboard access |
| 10 | **Performance Tweaks** | No | Disable quarantine dialogs, save to disk by default |
| 11 | **System Daemons** | **Yes** | Disable AI/ML daemons, analytics, media analysis, Screen Time |
| 12 | **Adobe Bloatware** | No | Disable CC agents, sync, update helpers, Finder extensions, installer daemon |
| 13 | **Block Stock Apps** | **Yes** | Quarantine Chess, News, Stocks, TV, Tips, etc. |
| 14 | **Advanced** | **Yes** | Disable Sidecar, Universal Control, Continuity, Journal |

> Categories 11, 13–14 require SIP to be disabled (`csrutil disable` from Recovery). All other categories work with SIP enabled.

## ⚙️ Settings & Preferences

Milo's settings panel is accessible via **⌘,** or the gear icon in the toolbar.

| Setting | Description |
|---------|-------------|
| **Start at Login** | Automatically launch Milo when you log in (uses SMAppService) |
| **Confirm Before Kill** | Show a confirmation dialog before terminating processes |
| **Scan on Open** | Auto-scan for bloat each time the popover opens |
| **Auto-Rescan Interval** | Periodically re-scan while open (30s / 1m / 2m / 5m / off) |
| **Status Bar Badge** | Show bloat count next to the 💀 icon |
| **Memory in Header** | Show memory pressure bar in the main view |
| **Privileges** | Optional passwordless sudo mode for faster privileged actions |

## 🛠 Installation & Usage

### Build from Source
If you have Swift installed, you can build the `.app` bundle using the included script:
```bash
chmod +x build_app.sh
./build_app.sh              # Dev build (ad-hoc signed)
./build_app.sh release      # Optimised release build + DMG
./build_app.sh release sign # Release + Developer ID signing
./build_app.sh release notarize # Full notarization pipeline
```

For signing and notarization, set these environment variables:
```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="XXXXXXXXXX"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

### Running the App
1. Open `Milo.app`.
2. Look for the 💀 icon in your macOS Status Bar.
3. Click to scan for active bloatware.
4. Select the items you want to terminate and hit **Kill Selected**.

> **Note:** Modification of system services and some process operations require Administrator privileges. By default, macOS prompts for approval. Passwordless mode is optional and should be used only if you accept that sudoers rules apply to every process running as your macOS user.

### Self-Test
```bash
swift build -c release
.build/release/Milo --self-test
```

The default self-test is safe: it does not clear real user caches, flush DNS, purge memory, toggle login items, create LaunchAgents, or mutate real debloat settings. Destructive integration checks are available with `--self-test-destructive`.

## ⚠️ Disclaimer
Milo is a powerful cleanup tool. Disabling audio drivers, launch agents, or system services can stop dependent hardware or macOS features until you re-enable them. Review each item before applying changes.

---

## 📋 Project Status

### February 10, 2026 — Distribution Readiness Pass

The following improvements were made to bring Milo from a working prototype to a distribution-ready v1.0:

#### Architecture & Code Quality
- **Extracted shared UI components** — `VisualEffectBlur`, `GlassCard`, and `StatCard` were duplicated across `ContentView.swift`, `StatsView.swift`, and `WhitelistView.swift`. All three are now in a single `SharedUI.swift`.
- **Split ProcessManager** — The monolithic 1,674-line `ProcessManager.swift` was split into `ProcessData.swift` (957 lines of pure data: target lists, vendor patterns, launchd mappings, friendly descriptions) and `ProcessManager.swift` (502 lines of logic only).
- **Added `Package.swift`** — Swift Package Manager manifest targeting macOS 13+ for proper IDE integration and dependency management.

#### Security Hardening
- **Tightened sudoers rule** — Removed the dangerous `NOPASSWD: /bin/sh -c *` entry (effectively unrestricted root) from the privilege manager. The sudoers file now only grants passwordless access to the 6 specific binaries Milo needs: `pkill`, `launchctl`, `kill`, `killall`, `purge`, `dscacheutil`.
- **Per-binary sudo wrapping** — Added `wrapCommandsWithSudo()` in `PrivilegeManager.swift` to prefix each privileged binary call with `sudo -n` individually instead of wrapping whole command strings in a root shell.

#### Error Handling & UX
- **Fallback app icon** — `IconManager.swift` now draws a procedural 💀 icon at runtime when `.icns` assets are missing, instead of silently failing.
- **Privilege setup error feedback** — The setup banner now shows inline error messages when the one-time sudoers configuration fails.
- **Version display** — The popover header now shows the app version from `Info.plist` instead of static text.

#### Distribution & Packaging
- **Upgraded build script** (`build_app.sh`) — Now supports 4 modes: `dev`, `release`, `release sign`, `release notarize`. Release builds use `-O -whole-module-optimization`, hardened runtime, and entitlements. Automatically creates a DMG with an `/Applications` symlink for drag-install. Full `notarytool` + `stapler` notarization pipeline via environment variables.
- **Added entitlements** — `com.apple.security.automation.apple-events` entitlement applied during code signing for AppleScript privilege escalation.
- **Added `NSAppleEventsUsageDescription`** to `Info.plist` (required for notarization compliance).
- **Added `.gitignore`** — Covers build artifacts (`.app`, `.dmg`, `.build_icons`, `.dmg_staging`), SPM cache, Xcode junk, and `.DS_Store`.

#### File Structure After Changes
```
Milo/Sources/
  AppState.swift          — Central ObservableObject state hub
  ContentView.swift       — Main popover UI
  DebloatManager.swift    — Debloat engine: 14 categories, apply/revert logic
  DebloatView.swift       — Debloat settings UI with per-tweak toggles
  IconManager.swift       — App icon management with fallback
  main.swift              — AppDelegate, status bar item, Cmd+, menu
  MemoryManager.swift     — vm_stat memory stats + purge
  PrivilegeManager.swift  — Sudoers rule management (hardened)
  ProcessData.swift       — All target lists & data dictionaries
  ProcessManager.swift    — Process scanning & killing logic (slimmed)
  SettingsManager.swift   — [NEW] Persistent preferences & login item management
  SettingsView.swift      — [NEW] Preferences UI (⌘,)
  SharedUI.swift          — Shared VisualEffectBlur, GlassCard, StatCard
  SIPChecker.swift        — SIP status check
  StatsManager.swift      — Kill history persistence
  StatsView.swift         — Statistics dashboard
  WhitelistManager.swift  — Process exclusion list
  WhitelistView.swift     — Whitelist management UI
```

#### What Remains for Future Work
- **Dedicated test target** — The built-in safe self-test covers scanning, confirmation, kill flows, whitelist persistence, memory parsing, protected-target exclusions, and packaging smoke checks. A formal Swift test target would still be useful for faster CI.
- **Sparkle / auto-update** — No update mechanism. Consider integrating Sparkle for delta updates via an appcast feed.
- **Scheduled scans** — Auto-rescan while the popover is open exists; a detached scheduler could be added later if the app needs background monitoring.
- **Debloat profiles** — Pre-built profiles (e.g., "Music Producer", "Developer", "Privacy Max") that pre-select appropriate tweaks.

### February 10, 2026 — System Debloat Integration

Integrated a Tahoe-focused debloat suite into Milo as a native GUI feature.

#### New Features
- **DebloatManager** (`DebloatManager.swift`) — Data-driven debloat engine with 14 categories and 50+ individually-toggleable tweaks. Each tweak stores both apply and revert commands. User-level `defaults write` commands run directly; system-level commands (`launchctl disable system/*`, `mdutil`, `systemsetup`, `xattr`) run through `PrivilegeManager` or AppleScript elevation.
- **DebloatView** (`DebloatView.swift`) — Full SwiftUI sheet with expandable categories, per-tweak checkboxes, category-level and global Apply/Revert buttons, SIP-awareness (SIP-required categories are visually dimmed and disabled), applied-count badges, and a "Restart UI" button to reload Finder/Dock/SystemUIServer.
- **Debloat persistence** — Applied tweaks are tracked in UserDefaults so the app remembers what was changed across sessions.

#### Changes to Existing Files
- **AppState.swift** — Added `showingDebloat` published property.
- **ContentView.swift** — Added debloat button (wand icon) to the footer bar, opening `DebloatView` as a sheet.
- **PrivilegeManager.swift** — Added `mdutil`, `systemsetup`, and `xattr` to the sudoers allowlist and the `privilegedBinaries` set, enabling passwordless debloat operations after initial setup.

---
*Created for the elite who want their Mac to be a workstation, not a playground for background daemons.*
