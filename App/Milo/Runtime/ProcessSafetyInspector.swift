import Foundation
import AppKit
import Darwin
import MiloDomain
import Security

/// Gathers the measured evidence `MiloProcessSafetyPolicy` classifies.
///
/// The policy is a pure function; everything that has to ask the kernel, the Security
/// framework, or AppKit lives here. Keeping the split sharp is what makes the safety rules
/// testable without a running system.
///
/// SAFETY: the only mutable state is `appleSignatureCache`, and every read and write of it
/// happens while `lock` is held (`cachedVerdict(for:)` and `storeVerdict(_:for:)` are the
/// sole accessors). `appleRequirement` is immutable after `init` and `SecRequirement` is a
/// thread-safe immutable CoreFoundation object. No other stored property exists.
final class ProcessSafetyInspector: @unchecked Sendable {
    static let shared = ProcessSafetyInspector()

    /// Identity of an executable file, used to key the signature cache.
    ///
    /// A signature verdict is a property of the file, so two processes running the same
    /// unchanged binary share an answer. Including the inode, size and modification time
    /// means a replaced binary produces a different key and is re-verified rather than
    /// inheriting the previous verdict.
    private struct ExecutableFingerprint: Hashable {
        let path: String
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
    }

    private let lock = NSLock()
    private var appleSignatureCache: [ExecutableFingerprint: Bool] = [:]
    private let appleRequirement: SecRequirement?

    /// Bounded so a machine that churns through many short-lived binaries cannot grow the
    /// cache without limit.
    private static let maximumCacheEntries = 4_096

    private init() {
        var requirement: SecRequirement?
        // `anchor apple` matches software signed by Apple's own root — the operating system.
        // This is deliberately *not* `anchor apple generic`, which every Developer ID and Mac
        // App Store binary also satisfies and would misclassify third-party software as the OS.
        let status = SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        if status == errSecSuccess {
            self.appleRequirement = requirement
        } else {
            self.appleRequirement = nil
            MiloLog.error(
                .appleCodeRequirementUnavailable,
                category: .security,
                detail: "status=\(status)"
            )
        }
    }

    // MARK: - Code signature

    /// Whether the running process satisfies the `anchor apple` code requirement.
    ///
    /// Returns `false` when the answer cannot be established — a process that exited
    /// mid-scan, or one whose code object cannot be read. The policy treats a sealed-volume
    /// path as system software regardless, so a failed query cannot promote an operating
    /// system daemon into an actionable row.
    func isAppleSigned(pid: Int32, executablePath: String) -> Bool {
        guard let appleRequirement else {
            return false
        }

        let fingerprint = fingerprint(forExecutableAt: executablePath)
        if let fingerprint, let cached = cachedVerdict(for: fingerprint) {
            return cached
        }

        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return false
        }

        let verdict = SecCodeCheckValidity(code, [], appleRequirement) == errSecSuccess
        if let fingerprint {
            storeVerdict(verdict, for: fingerprint)
        }
        return verdict
    }

    private func cachedVerdict(for fingerprint: ExecutableFingerprint) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return appleSignatureCache[fingerprint]
    }

    private func storeVerdict(_ verdict: Bool, for fingerprint: ExecutableFingerprint) {
        lock.lock()
        defer { lock.unlock() }
        if appleSignatureCache.count >= Self.maximumCacheEntries {
            appleSignatureCache.removeAll(keepingCapacity: true)
        }
        appleSignatureCache[fingerprint] = verdict
    }

    private func fingerprint(forExecutableAt path: String) -> ExecutableFingerprint? {
        guard !path.isEmpty else {
            return nil
        }
        var status = stat()
        guard stat(path, &status) == 0 else {
            return nil
        }
        return ExecutableFingerprint(
            path: path,
            inode: status.st_ino,
            size: status.st_size,
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec)
        )
    }

    // MARK: - Milo's own process tree

    /// Every pid between Milo and the root of the process tree.
    ///
    /// Signalling any of them would take Milo down with it, so the whole chain is read-only.
    /// Recomputed per scan because a re-parented process changes the answer.
    func miloAncestorPIDs() -> Set<Int32> {
        var ancestors: Set<Int32> = []
        var current = getppid()
        // Bounded: a corrupted or cyclic parent chain must not spin.
        var remainingHops = 64
        while current > 1, remainingHops > 0, !ancestors.contains(current) {
            ancestors.insert(current)
            var information = proc_bsdinfo()
            let informationSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &information, informationSize) == informationSize else {
                break
            }
            current = Int32(bitPattern: information.pbi_ppid)
            remainingHops -= 1
        }
        return ancestors
    }

    /// Whether an executable path belongs to Milo or the helper Milo owns.
    func isMiloExecutable(path: String) -> Bool {
        if path == Bundle.main.executableURL?.standardizedFileURL.path {
            return true
        }
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        if !bundlePath.isEmpty, path.hasPrefix(bundlePath + "/") {
            return true
        }
        return URL(fileURLWithPath: path).lastPathComponent == "MiloPrivilegedHelper"
    }

    // MARK: - Foreground applications

    /// Pids of applications that own a Dock icon.
    ///
    /// These are the windows the user is looking at, not background work. They are filtered
    /// out of the discovery list by default so the list stays about what the user cannot
    /// otherwise see.
    @MainActor
    func foregroundApplicationPIDs() -> Set<Int32> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map(\.processIdentifier)
        )
    }
}
