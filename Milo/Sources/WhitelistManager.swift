import Foundation

class WhitelistManager {
    static let shared = WhitelistManager()

    private let whitelistFileURL: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let miloDir = appSupport.appendingPathComponent("Milo")
        do {
            try FileManager.default.createDirectory(at: miloDir, withIntermediateDirectories: true)
        } catch {
            print("Milo WhitelistManager: Failed to create directory. \\(error.localizedDescription)")
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
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Set<String>.self, from: data)
            self.whitelistedProcesses = decoded
        } catch {
            print("Milo WhitelistManager: Failed to load or decode whitelist. Starting fresh. \(error.localizedDescription)")
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
            try encoded.write(to: url)
        } catch {
            print("Milo WhitelistManager: Failed to save whitelist. \(error.localizedDescription)")
        }
    }
}
