import Foundation
import Darwin
import MiloDomain

/// One row of the process table, parsed once and shared by both scanning lanes.
struct ProcessTableRow: Sendable {
    let pid: Int32
    let memoryMB: Double
    let executablePath: String
    let command: String
}

/// A background process found by open discovery rather than by a shipped rule.
struct DiscoveredProcess: Identifiable, Hashable, Sendable {
    var id: Int32 { pid }

    let pid: Int32
    let name: String
    let executablePath: String
    let cpuUsage: Double
    let memoryMB: Double
    let effectiveUserID: UInt32
    let ownerName: String?
    let launchdLabel: String?
    let safety: MiloProcessSafetyClass
    let identity: ProcessIdentity
    var isSelected: Bool = false

    var isActionable: Bool {
        safety.isActionable
    }

    var requiresPrivilegedHelper: Bool {
        safety.requiresPrivilegedHelper
    }

    var protectionReason: MiloProcessProtectionReason? {
        safety.protectionReason
    }

    /// Whether launchd will start this process again after it is signalled.
    var isLaunchdManaged: Bool {
        launchdLabel != nil
    }
}

/// Open discovery: everything running, classified by evidence.
///
/// Milo's shipped catalogue answers "which processes do we have a reviewed opinion about".
/// It cannot answer "what else is running", which is why a job the user started themselves
/// was invisible. This scanner answers the second question for every process, and defers
/// every actionability decision to `MiloProcessSafetyPolicy`.
final class BackgroundProcessScanner: Sendable {
    static let shared = BackgroundProcessScanner()

    private let inspector: ProcessSafetyInspector

    init(inspector: ProcessSafetyInspector = .shared) {
        self.inspector = inspector
    }

    /// Inputs the caller has already measured, so discovery adds no extra `ps` invocation
    /// and no second CPU sampling window.
    struct Context: Sendable {
        let rows: [ProcessTableRow]
        /// Pids already reported through the catalogued lanes; they are not repeated here.
        let cataloguedPIDs: Set<Int32>
        let launchdLabels: [Int32: String]
        let foregroundApplicationPIDs: Set<Int32>
        let protectedProcessNames: Set<String>
        let cpuByPID: [Int32: Double]
    }

    func discover(_ context: Context) -> [DiscoveredProcess] {
        let currentUserID = getuid()
        let ancestors = inspector.miloAncestorPIDs()
        let selfPID = getpid()

        var discovered: [DiscoveredProcess] = []
        discovered.reserveCapacity(context.rows.count)

        for row in context.rows {
            guard !context.cataloguedPIDs.contains(row.pid) else { continue }
            // An application with a Dock icon is something the user opened, not hidden
            // background work. Excluding it also means the discovery list can never be the
            // route by which someone quits their own editor by accident.
            guard !context.foregroundApplicationPIDs.contains(row.pid) else { continue }
            guard row.executablePath.hasPrefix("/") else { continue }
            guard let identity = processIdentity(pid: row.pid, executablePath: row.executablePath),
                  let information = bsdInformation(pid: row.pid) else { continue }

            let name = URL(fileURLWithPath: row.executablePath).lastPathComponent
            let label = context.launchdLabels[row.pid]
            let evidence = MiloProcessEvidence(
                pid: row.pid,
                executablePath: row.executablePath,
                effectiveUserID: information.pbi_uid,
                isAppleSigned: inspector.isAppleSigned(pid: row.pid, executablePath: row.executablePath),
                launchdLabel: label,
                matchesReviewedRule: false,
                isMiloItself: row.pid == selfPID || inspector.isMiloExecutable(path: row.executablePath),
                isMiloAncestor: ancestors.contains(row.pid),
                isUserProtected: context.protectedProcessNames.contains(name)
            )

            discovered.append(
                DiscoveredProcess(
                    pid: row.pid,
                    name: name,
                    executablePath: row.executablePath,
                    cpuUsage: context.cpuByPID[row.pid] ?? 0,
                    memoryMB: row.memoryMB,
                    effectiveUserID: information.pbi_uid,
                    ownerName: userName(forUserID: information.pbi_uid),
                    launchdLabel: label,
                    safety: MiloProcessSafetyPolicy.classify(evidence, currentUserID: currentUserID),
                    identity: identity
                )
            )
        }

        return discovered.sorted { lhs, rhs in
            if lhs.memoryMB != rhs.memoryMB { return lhs.memoryMB > rhs.memoryMB }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Kernel lookups

    private func bsdInformation(pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var information = proc_bsdinfo()
        let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, informationSize) == informationSize else {
            return nil
        }
        return information
    }

    private func processIdentity(pid: Int32, executablePath: String) -> ProcessIdentity? {
        guard pid > 1, let information = bsdInformation(pid: pid) else { return nil }
        return ProcessIdentity(
            pid: pid,
            executablePath: executablePath,
            startSeconds: information.pbi_start_tvsec,
            startMicroseconds: information.pbi_start_tvusec
        )
    }

    private func userName(forUserID userID: UInt32) -> String? {
        guard let entry = getpwuid(userID), let name = entry.pointee.pw_name else {
            return nil
        }
        return String(cString: name)
    }
}
