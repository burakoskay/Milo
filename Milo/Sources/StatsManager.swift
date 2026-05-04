import Foundation

struct KillStats: Codable {
    let timestamp: Date
    let processName: String
    let cpuUsage: Double
    let memoryMB: Double
    let vendor: String
}

struct AggregatedStats: Codable {
    var totalProcessesKilled: Int = 0
    var totalCPUSaved: Double = 0.0  // Total CPU percentage saved
    var totalRAMSavedMB: Double = 0.0
    var firstKillDate: Date?
    var lastKillDate: Date?
    var killHistory: [KillStats] = []

    // Privacy & energy estimates. These are local-only, heuristic impact numbers.
    var estimatedBatteryHoursSaved: Double {
        // Rough estimate: 1% CPU continuous = ~0.1 hours battery drain on average MacBook
        return totalCPUSaved * 0.1
    }

    var estimatedTrackingEventsInterrupted: Int {
        // Rough estimate: telemetry-heavy helpers may collect ~100 events per hour.
        guard let first = firstKillDate else { return 0 }
        let hoursSinceFirstKill = Date().timeIntervalSince(first) / 3600
        return Int(Double(totalProcessesKilled) * hoursSinceFirstKill * 100)
    }

    var killedProcessesByVendor: [String: Int] {
        Dictionary(grouping: killHistory, by: { $0.vendor })
            .mapValues { $0.count }
    }

    var topMemoryHogs: [KillStats] {
        Array(killHistory.sorted { $0.memoryMB > $1.memoryMB }.prefix(10))
    }

    mutating func recordKill(_ process: ProcessItem) {
        let stat = KillStats(
            timestamp: Date(),
            processName: process.name,
            cpuUsage: process.cpuUsage,
            memoryMB: process.memoryMB,
            vendor: process.vendor
        )

        killHistory.append(stat)
        totalProcessesKilled += 1
        totalCPUSaved += process.cpuUsage
        totalRAMSavedMB += process.memoryMB

        if firstKillDate == nil {
            firstKillDate = Date()
        }
        lastKillDate = Date()

        // Keep only last 1000 kills to avoid huge file
        if killHistory.count > 1000 {
            killHistory.removeFirst(killHistory.count - 1000)
        }
    }
}

class StatsManager {
    static let shared = StatsManager()

    private let statsFileURL: URL? = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let miloDir = appSupport.appendingPathComponent("Milo")
        do {
            try FileManager.default.createDirectory(at: miloDir, withIntermediateDirectories: true)
        } catch {
            MiloLog.error("StatsManager failed to create directory: \(error.localizedDescription)", category: .persistence)
            return nil
        }
        return miloDir.appendingPathComponent("stats.json")
    }()

    private var stats: AggregatedStats

    init() {
        self.stats = AggregatedStats()
        // Load existing stats or create new
        guard let url = statsFileURL else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AggregatedStats.self, from: data)
            self.stats = decoded
        } catch {
            MiloLog.warning("StatsManager failed to load or decode stats; starting fresh: \(error.localizedDescription)", category: .persistence)
        }
    }

    func getStats() -> AggregatedStats {
        return stats
    }

    func recordKills(_ processes: [ProcessItem]) {
        for process in processes {
            stats.recordKill(process)
        }
        save()
    }

    func reset() {
        stats = AggregatedStats()
        save()
    }

    private func save() {
        guard let url = statsFileURL else { return }
        do {
            let encoded = try JSONEncoder().encode(stats)
            try encoded.write(to: url)
        } catch {
            MiloLog.error("StatsManager failed to save stats: \(error.localizedDescription)", category: .persistence)
        }
    }
}
