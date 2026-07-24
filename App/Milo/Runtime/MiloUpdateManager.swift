import Foundation
import MiloSparkle
import MiloUpdates

enum MiloUpdateState: Equatable {
    case idle
    case preparing
    case checking
    case updateAvailable(version: String)
    case upToDate
    case updateDownloaded(version: String)
    case failed(message: String)
}

@MainActor
final class MiloUpdateManager: ObservableObject {
    @Published private(set) var state: MiloUpdateState = .idle

    var isChecking: Bool {
        state == .preparing || state == .checking
    }

    var canCheckForUpdates: Bool {
        !isChecking && (controller?.canCheckForUpdates ?? true)
    }

    var statusMessage: String? {
        switch state {
        case .idle:
            return nil
        case .preparing:
            return "Authenticating and verifying the update feed…"
        case .checking:
            return "Checking for updates…"
        case let .updateAvailable(version):
            return "Milo \(version) is available in the update window."
        case .upToDate:
            return "Milo is up to date."
        case let .updateDownloaded(version):
            return "Milo \(version) is verified and ready to install."
        case let .failed(message):
            return message
        }
    }

    var statusIsError: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private let licenseManager: LicenseManager
    private var controller: MiloSparkleController?
    private var configurationError: String?

    init(licenseManager: LicenseManager) {
        self.licenseManager = licenseManager
        controller = nil
        configurationError = nil

        do {
            let serviceURL = try BackendConfiguration.serviceBaseURL()
            guard let serviceHost = serviceURL.host?.lowercased() else {
                throw MiloUpdateError.invalidPolicy
            }
            let policy = try MiloAppcastPolicy(allowedHosts: [serviceHost])
            controller = MiloSparkleController(
                expectedBundleIdentifier: "com.monomacaw.milo",
                appcastPolicy: policy
            ) { [weak self] event in
                self?.handle(event: event)
            }
        } catch {
            configurationError = Self.userMessage(for: error)
        }
    }

    func checkForUpdates() async {
        guard !isChecking else {
            state = .failed(message: "An update check is already in progress.")
            return
        }
        guard licenseManager.isSubscribed else {
            state = .failed(message: "A current Milo Pro license is required to check for direct updates.")
            return
        }
        guard let controller else {
            state = .failed(message: configurationError ?? "Milo's updater is unavailable.")
            return
        }
        guard controller.canCheckForUpdates else {
            state = .failed(message: "Sparkle is already handling an update session.")
            return
        }

        state = .preparing
        do {
            let updateFeed = try await licenseManager.updateFeedDescriptor()
            try await controller.checkForUpdates(
                descriptor: updateFeed.descriptor,
                channel: updateFeed.channel
            )
        } catch {
            state = .failed(message: Self.userMessage(for: error))
        }
    }

    private func handle(event: MiloSparkleEvent) {
        switch event {
        case .preparing:
            state = .preparing
        case .checking:
            state = .checking
        case let .updateAvailable(version):
            state = .updateAvailable(version: version)
        case .upToDate:
            state = .upToDate
        case let .updateDownloaded(version):
            state = .updateDownloaded(version: version)
        case let .failed(message):
            state = .failed(message: message)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Milo could not complete the update check."
    }
}
