import Foundation

@MainActor
final class WhitelistManager {
    static let shared = WhitelistManager()

    private let whitelistFileURL: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let miloDir = appSupport.appendingPathComponent("Milo")
        do {
            try FileManager.default.createDirectory(at: miloDir, withIntermediateDirectories: true)
        } catch {
            MiloLog.error(.persistenceDirectoryCreateFailed, category: .persistence, detail: error.localizedDescription)
            return nil
        }
        return miloDir.appendingPathComponent("whitelist.json")
    }()

    private var whitelistedProcesses: Set<String>

    init() {
        self.whitelistedProcesses = Set<String>()
        // Load existing whitelist
        guard let url = whitelistFileURL else { return }

        do {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])

            guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                MiloLog.warning(.persistenceLoadRejected, category: .persistence, detail: "Whitelist file is not a regular file")
                return
            }

            guard let fileSize = resourceValues.fileSize, fileSize < 2 * 1024 * 1024 else {
                MiloLog.warning(.persistenceLoadRejected, category: .persistence, detail: "Whitelist file is too large")
                return
            }

            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Set<String>.self, from: data)
            self.whitelistedProcesses = decoded
        } catch {
            MiloLog.warning(.persistenceLoadFailed, category: .persistence, detail: error.localizedDescription)
        }
    }

    func isWhitelisted(_ processName: String) -> Bool {
        return whitelistedProcesses.contains(processName)
    }

    func addToWhitelist(_ processName: String) {
        whitelistedProcesses.insert(processName)
        save()
    }

    func removeFromWhitelist(_ processName: String) {
        whitelistedProcesses.remove(processName)
        save()
    }

    func getWhitelistedProcesses() -> [String] {
        return Array(whitelistedProcesses).sorted()
    }

    func clearWhitelist() {
        whitelistedProcesses.removeAll()
        save()
    }

    private func save() {
        guard let url = whitelistFileURL else { return }
        do {
            let encoded = try JSONEncoder().encode(whitelistedProcesses)
            try encoded.write(to: url, options: [.atomic])
        } catch {
            MiloLog.error(.persistenceSaveFailed, category: .persistence, detail: error.localizedDescription)
        }
    }
}
