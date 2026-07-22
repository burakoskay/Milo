import Foundation
import SwiftUI

struct MemoryStats {
    let totalGB: Double
    let wiredGB: Double
    let activeGB: Double
    let inactiveGB: Double
    let compressedGB: Double
    let freeGB: Double
    let appMemoryGB: Double
    let cachedFilesGB: Double
    let memoryPressure: MemoryPressure

    enum MemoryPressure {
        case normal, warning, critical

        var color: Color {
            switch self {
            case .normal: return .green
            case .warning: return .yellow
            case .critical: return .red
            }
        }

        var description: String {
            switch self {
            case .normal: return "Normal"
            case .warning: return "Warning"
            case .critical: return "Critical"
            }
        }
    }

    var usedPercentage: Double {
        ((wiredGB + activeGB + compressedGB) / totalGB) * 100
    }
}

final class MemoryManager: @unchecked Sendable {
    static let shared = MemoryManager()

    @discardableResult
    func clearCaches(at cachesPath: String) -> (success: Bool, message: String) {
        let fileManager = FileManager.default

        var clearedSize: UInt64 = 0
        var clearedCount = 0
        var skippedCount = 0

        do {
            let cachesURL = URL(fileURLWithPath: cachesPath, isDirectory: true).standardizedFileURL
            let contents = try fileManager.contentsOfDirectory(
                at: cachesURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )

            for itemURL in contents {
                let name = itemURL.lastPathComponent
                if name.localizedCaseInsensitiveContains("Milo") || name.localizedCaseInsensitiveContains("com.monomacaw.milo") {
                    continue
                }

                do {
                    let values = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        continue
                    }
                } catch {
                    continue
                }

                let size = allocatedSize(of: itemURL)

                do {
                    try fileManager.removeItem(at: itemURL)
                    clearedSize += size
                    clearedCount += 1
                } catch {
                    skippedCount += 1
                    continue
                }
            }

            let sizeInMB = Double(clearedSize) / 1_048_576.0
            if skippedCount > 0 {
                return (true, String(format: "Cleared %d, skipped %d (TCC denied) (%.1f MB)", clearedCount, skippedCount, sizeInMB))
            } else {
                return (true, String(format: "Cleared %d cache items (%.1f MB)", clearedCount, sizeInMB))
            }
        } catch {
            return (false, "Failed to clear caches: \(error.localizedDescription)")
        }
    }

    private func allocatedSize(of url: URL) -> UInt64 {
        let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        var total: UInt64 = 0

        do {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink != true {
                total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        } catch {
            return total
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return total
        }

        for case let child as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: resourceKeys)
            } catch {
                continue
            }

            guard values.isSymbolicLink != true else {
                continue
            }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        return total
    }

    /// Get current memory statistics
    func getMemoryStats() -> MemoryStats? {
        let result = CommandRunner.run("/usr/bin/vm_stat")
        guard result.succeeded else {
            MiloLog.error("Failed to read memory statistics: \(result.stderr)", category: .memory)
            return nil
        }

        // Parse vm_stat output
        var stats: [String: Double] = [:]
        let lines = result.stdout.components(separatedBy: .newlines)

        var pageSize: Double = 4096 // Default page size

        for line in lines {
            if line.contains("page size of") {
                // Extract page size
                let components = line.components(separatedBy: " ")
                if let size = components.last?.trimmingCharacters(in: CharacterSet(charactersIn: " bytes.")),
                   let pageSizeInt = Double(size) {
                    pageSize = pageSizeInt
                }
            } else if line.contains(":") {
                let components = line.components(separatedBy: ":")
                guard components.count == 2 else { continue }

                let key = components[0].trimmingCharacters(in: .whitespaces)
                let value = components[1]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")

                if let pages = Double(value) {
                    stats[key] = pages
                }
            }
        }

        // Calculate memory in GB
        let bytesToGB = pageSize / 1_073_741_824.0 // 1GB = 1024^3 bytes

        let free = (stats["Pages free"] ?? 0) * bytesToGB
        let active = (stats["Pages active"] ?? 0) * bytesToGB
        let inactive = (stats["Pages inactive"] ?? 0) * bytesToGB
        let wired = (stats["Pages wired down"] ?? 0) * bytesToGB
        let compressed = (stats["Pages occupied by compressor"] ?? 0) * bytesToGB
        let cached = (stats["File-backed pages"] ?? 0) * bytesToGB

        // Get total memory
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        let sysctlStatus = sysctlbyname("hw.memsize", &size, &length, nil, 0)
        guard sysctlStatus == 0, size > 0 else {
            MiloLog.error("Failed to read total physical memory via sysctl", category: .memory)
            return nil
        }
        let totalGB = Double(size) / 1_073_741_824.0

        let appMemory = active + wired

        // Determine memory pressure
        let usedPercentage = ((wired + active + compressed) / totalGB) * 100
        let pressure: MemoryStats.MemoryPressure
        if usedPercentage > 85 {
            pressure = .critical
        } else if usedPercentage > 70 {
            pressure = .warning
        } else {
            pressure = .normal
        }

        return MemoryStats(
            totalGB: totalGB,
            wiredGB: wired,
            activeGB: active,
            inactiveGB: inactive,
            compressedGB: compressed,
            freeGB: free,
            appMemoryGB: appMemory,
            cachedFilesGB: cached,
            memoryPressure: pressure
        )
    }

    /// Purge inactive memory (requires sudo)
    func purgeMemory(completion: @escaping @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CommandRunner.runPrivileged("/usr/sbin/purge")
            DispatchQueue.main.async {
                completion(result.succeeded, result.succeeded ? "Memory purged successfully" : "Failed to purge memory — admin access denied")
            }
        }
    }

    /// Clear user caches
    func clearUserCaches(completion: @escaping @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let cachesPath = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
                DispatchQueue.main.async {
                    completion(false, "Failed to locate user cache directory")
                }
                return
            }
            let result = self.clearCaches(at: cachesPath)
            DispatchQueue.main.async {
                completion(result.success, result.message)
            }
        }
    }

    /// Clear DNS cache
    func clearDNSCache(completion: @escaping @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let cacheResult = CommandRunner.run("/usr/bin/dscacheutil", arguments: ["-flushcache"])
            let responderResult = CommandRunner.runPrivileged("/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
            let success = cacheResult.succeeded && responderResult.succeeded
            DispatchQueue.main.async {
                completion(success, success ? "DNS cache cleared" : "Failed to clear DNS cache")
            }
        }
    }
}
