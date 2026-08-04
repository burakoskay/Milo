import Foundation
import AppKit
import MiloDomain
import ServiceManagement

/// One step of an uninstall, and what actually happened to it.
struct UninstallStepResult: Identifiable, Sendable {
    enum Outcome: Sendable, Equatable {
        case removed
        case notPresent
        case refused(String)
        case failed(String)

        var succeeded: Bool {
            switch self {
            case .removed, .notPresent:
                return true
            case .refused, .failed:
                return false
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let outcome: Outcome
}

/// A helper registration that Milo can see but cannot remove.
struct OrphanedHelperRegistration: Identifiable, Sendable {
    var id: String { serviceIdentifier }
    let serviceIdentifier: String
    /// The `launchctl` command a user with administrator rights can run to clear it.
    var recoveryCommand: String {
        "sudo launchctl bootout system/\(serviceIdentifier)"
    }
}

/// Removes Milo from the Mac.
///
/// This exists because deleting `Milo.app` does not remove Milo. `SMAppService` records live
/// in macOS's Background Task Management database, not in the bundle, so dragging the app to
/// the Trash leaves a root daemon registered and running with its executable already
/// unlinked. That was observed on 2026-08-04 with the pre-rename build and is the reason an
/// in-app uninstall is the top item in the handoff's next-actions list.
///
/// Ordering matters and is not cosmetic: the helper is unregistered *before* any file is
/// removed, so a failure part-way through never leaves a running root daemon whose owning
/// app has already been dismantled.
@MainActor
final class UninstallManager: ObservableObject {
    static let shared = UninstallManager()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var results: [UninstallStepResult] = []
    @Published private(set) var orphanedHelpers: [OrphanedHelperRegistration] = []

    private let fileManager = FileManager.default

    private init() {}

    private var homeDirectory: String {
        fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    /// Everything the uninstall would remove, for display before the user commits.
    var plannedItems: [MiloUninstallItem] {
        MiloUninstallPlan.items(homeDirectory: homeDirectory).filter {
            fileManager.fileExists(atPath: $0.path)
        }
    }

    var plannedItemCount: Int {
        plannedItems.count
    }

    // MARK: - Orphaned registrations

    /// Detects helper registrations left by builds published under the retired identifiers.
    ///
    /// Milo cannot unregister these: `SMAppService` only ever acts on the calling app's own
    /// records. They are reported with recovery steps instead. `launchctl print` is
    /// read-only and works without privilege, so the check costs nothing and never prompts.
    func refreshOrphanedHelpers() {
        orphanedHelpers = MiloUninstallPlan.legacyHelperServiceIdentifiers.compactMap { identifier in
            let result = CommandRunner.run("/bin/launchctl", arguments: ["print", "system/\(identifier)"])
            guard result.succeeded else {
                return nil
            }
            MiloLog.warning(.uninstallLegacyHelperDetected, category: .privileges, detail: identifier)
            return OrphanedHelperRegistration(serviceIdentifier: identifier)
        }
    }

    // MARK: - Uninstall

    /// Runs the uninstall. `removesApplicationBundle` moves `Milo.app` to the Trash and quits.
    func uninstall(removesApplicationBundle: Bool, completion: @escaping @MainActor @Sendable () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        results = []

        unregisterHelper { [weak self] helperResult in
            guard let self else { return }
            var collected = [helperResult]
            collected.append(self.disableLoginItem())
            collected.append(contentsOf: self.removePlannedItems())

            self.results = collected
            self.isRunning = false

            guard removesApplicationBundle else {
                completion()
                return
            }
            self.moveBundleToTrashAndQuit(after: collected)
            completion()
        }
    }

    /// Step 1. The registration must go before the files do.
    private func unregisterHelper(completion: @escaping @MainActor @Sendable (UninstallStepResult) -> Void) {
        let identifier = MiloUninstallPlan.helperServiceIdentifier

        guard PrivilegeManager.shared.status != .notRegistered else {
            completion(
                UninstallStepResult(
                    id: "helper",
                    title: "Background helper",
                    detail: identifier,
                    outcome: .notPresent
                )
            )
            return
        }

        PrivilegeManager.shared.removePrivileges { success in
            if !success {
                MiloLog.error(.uninstallHelperRemovalFailed, category: .privileges, detail: identifier)
            }
            completion(
                UninstallStepResult(
                    id: "helper",
                    title: "Background helper",
                    detail: identifier,
                    outcome: success
                        ? .removed
                        : .failed("macOS did not unregister the helper. Remove Milo under System Settings › General › Login Items & Extensions before deleting the app.")
                )
            )
        }
    }

    /// Step 2. Launch-at-login is a separate `SMAppService` record from the helper.
    private func disableLoginItem() -> UninstallStepResult {
        guard SMAppService.mainApp.status == .enabled else {
            return UninstallStepResult(
                id: "login-item",
                title: "Launch at login",
                detail: "Not registered",
                outcome: .notPresent
            )
        }

        do {
            try SMAppService.mainApp.unregister()
            return UninstallStepResult(
                id: "login-item",
                title: "Launch at login",
                detail: "Unregistered",
                outcome: .removed
            )
        } catch {
            MiloLog.error(.uninstallHelperRemovalFailed, category: .settings, detail: error.localizedDescription)
            return UninstallStepResult(
                id: "login-item",
                title: "Launch at login",
                detail: "Unregister failed",
                outcome: .failed("Milo could not remove its login item. Remove it under System Settings › General › Login Items & Extensions.")
            )
        }
    }

    /// Step 3. Files, each re-checked against the pure plan immediately before removal.
    private func removePlannedItems() -> [UninstallStepResult] {
        let home = homeDirectory
        return MiloUninstallPlan.items(homeDirectory: home).map { item in
            // The plan produced this path a moment ago, so this can only fail if the plan and
            // the gate disagree. That is exactly the bug worth catching before a delete.
            guard MiloUninstallPlan.isRemovable(item.path, homeDirectory: home) else {
                MiloLog.error(.uninstallItemRejected, category: .persistence, detail: item.path)
                return UninstallStepResult(
                    id: item.id,
                    title: item.title,
                    detail: item.detail,
                    outcome: .refused("Milo refused to remove a path outside its own data.")
                )
            }

            // Clear the defaults domain first. Removing the plist while cfprefsd still holds
            // the domain in memory lets it write the file straight back.
            if let domain = item.preferencesDomain {
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }

            guard fileManager.fileExists(atPath: item.path) else {
                return UninstallStepResult(
                    id: item.id,
                    title: item.title,
                    detail: item.detail,
                    outcome: .notPresent
                )
            }

            do {
                try fileManager.removeItem(atPath: item.path)
                return UninstallStepResult(
                    id: item.id,
                    title: item.title,
                    detail: item.detail,
                    outcome: .removed
                )
            } catch {
                MiloLog.error(
                    .uninstallItemRemoveFailed,
                    category: .persistence,
                    detail: "path=\(item.path) error=\(error.localizedDescription)"
                )
                return UninstallStepResult(
                    id: item.id,
                    title: item.title,
                    detail: item.detail,
                    outcome: .failed(error.localizedDescription)
                )
            }
        }
    }

    /// Step 4. The bundle goes to the Trash, never to `removeItem`, so the user can undo.
    private func moveBundleToTrashAndQuit(after steps: [UninstallStepResult]) {
        // A failed helper unregistration is the one case where deleting the bundle creates
        // the orphaned root daemon this whole flow exists to prevent.
        guard steps.first(where: { $0.id == "helper" })?.outcome.succeeded ?? false else {
            return
        }

        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundleURL]) { _, error in
            Task { @MainActor in
                if let error {
                    MiloLog.error(
                        .uninstallBundleMoveFailed,
                        category: .persistence,
                        detail: error.localizedDescription
                    )
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
