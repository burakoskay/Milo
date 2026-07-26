import Foundation
import ServiceManagement

enum MiloHelperStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable(String)

    var isEnabled: Bool {
        self == .enabled
    }
}

enum MiloHelperSetupResult: Equatable, Sendable {
    case enabled
    case requiresApproval
    case failed(String)
}

/// Owns the single, explicit Service Management authorization flow.
/// Registration is user-initiated and never retried automatically, preventing
/// permission loops. Once approved, XPC actions do not prompt per operation.
@MainActor
final class PrivilegeManager {
    static let shared = PrivilegeManager()

    private let service = SMAppService.daemon(plistName: MiloPrivilegedHelperIdentity.plistName)

    private init() {}

    var status: MiloHelperStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable("The embedded Milo helper could not be found. Reinstall the Development Preview in Applications.")
        @unknown default:
            return .unavailable("macOS returned an unknown background-helper state.")
        }
    }

    var isConfigured: Bool {
        status.isEnabled
    }

    func configurePrivileges(completion: @escaping @MainActor @Sendable (MiloHelperSetupResult) -> Void) {
        if service.status == .enabled {
            completion(.enabled)
            return
        }

        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                completion(.requiresApproval)
                return
            }
            let nsError = error as NSError
            completion(.failed("Milo could not register its helper (\(nsError.domain) \(nsError.code))."))
            return
        }

        switch service.status {
        case .enabled:
            completion(.enabled)
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            completion(.requiresApproval)
        case .notRegistered, .notFound:
            completion(.failed("macOS did not enable the Milo helper."))
        @unknown default:
            completion(.failed("macOS returned an unknown helper state."))
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func removePrivileges(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        do {
            try service.unregister()
            completion(true)
        } catch {
            MiloLog.error(
                .privilegeConfigurationFailed,
                category: .privileges,
                detail: error.localizedDescription
            )
            completion(false)
        }
    }

    nonisolated func resetVerification() {
        // Compatibility no-op. SMAppService is the source of truth and Milo no
        // longer caches sudo authorization or installs sudoers rules.
    }
}
