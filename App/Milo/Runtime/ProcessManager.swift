import Foundation
import AppKit
import MiloDomain
import Security
import Darwin

struct LaunchItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let label: String
    let isLoaded: Bool
    let description: String?
}

// Represents a launchd-managed process that will respawn
struct LaunchdProcess: Sendable {
    let label: String           // Main launchd label
    let plistPath: String       // Path to the plist file
    let processName: String
    let isSystem: Bool          // System processes require SIP disabled
    let relatedLabels: [String] // Related services that also need disabling
}

final class ProcessManager: Sendable {
    static let shared = ProcessManager()

    private typealias PrivilegedCommand = (executable: String, arguments: [String])

    // MARK: - Direct Execution Safety

    private static func validateLaunchdLabel(_ label: String) -> String? {
        guard !label.isEmpty, label.count <= 256 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            MiloLog.warning("Rejected unsafe launchd label: \(label)", category: .process)
            return nil
        }
        return label
    }

    private static func validatePlistPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard standardized.hasSuffix(".plist") else { return nil }
        guard !standardized.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            MiloLog.warning("Rejected unsafe plist path: \(path)", category: .process)
            return nil
        }
        let userLaunchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL.path
        let allowedRoots = [
            "/System/Library/LaunchDaemons",
            "/System/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            userLaunchAgents
        ]
        guard allowedRoots.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") }) else {
            MiloLog.warning("Rejected plist outside LaunchAgents/LaunchDaemons: \(path)", category: .process)
            return nil
        }
        return standardized
    }

    private static func requiresAdministrator(forPlistPath path: String) -> Bool {
        path.hasPrefix("/System/Library/")
            || path.hasPrefix("/Library/LaunchDaemons/")
            || path.hasPrefix("/Library/LaunchAgents/")
    }

    private func runLaunchctl(_ arguments: [String], privileged: Bool = false) -> Bool {
        let result = privileged
            ? CommandRunner.runPrivileged("/bin/launchctl", arguments: arguments)
            : CommandRunner.run("/bin/launchctl", arguments: arguments)
        return result.succeeded
    }

    private func launchctlCommand(_ arguments: [String]) -> PrivilegedCommand {
        (executable: "/bin/launchctl", arguments: arguments)
    }

    private func runPrivilegedCommands(_ commands: [PrivilegedCommand]) -> Bool {
        guard !commands.isEmpty else { return true }
        return CommandRunner.runPrivilegedBatch(commands).succeeded
    }

    private func appendTermKillCommands(for pids: Set<Int32>, to commands: inout [PrivilegedCommand]) {
        let sortedPIDs = pids.sorted()
        guard !sortedPIDs.isEmpty else { return }

        for pid in sortedPIDs where pid > 0 {
            commands.append((executable: "/bin/kill", arguments: ["-TERM", String(pid)]))
        }
        commands.append((executable: "/bin/sleep", arguments: ["1"]))
        for pid in sortedPIDs where pid > 0 {
            commands.append((executable: "/bin/kill", arguments: ["-KILL", String(pid)]))
        }
    }

    private func runKill(signal: String, pid: Int32, privileged: Bool = false) -> Bool {
        guard pid > 0 else { return false }
        let result = privileged
            ? CommandRunner.runPrivileged("/bin/kill", arguments: [signal, String(pid)])
            : CommandRunner.run("/bin/kill", arguments: [signal, String(pid)])
        return result.succeeded || result.status == 1
    }

    private func resolvedExecutablePath(pid: Int32, fallback: String) -> String {
        guard pid > 0 else { return fallback }

        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else { return 0 }
            return proc_pidpath(pid, baseAddress, UInt32(pointer.count))
        }

        guard result > 0 else { return fallback }
        let byteCount = Int(result)
        let bytes = buffer.prefix(byteCount).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? fallback
    }

    private func executableName(from path: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent
        return lastPathComponent.isEmpty ? path : lastPathComponent
    }

    private func codeSignature(forExecutablePath path: String) -> TelemetryCodeSignature? {
        let url = URL(fileURLWithPath: path)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }

        var rawInformation: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard status == errSecSuccess,
              let information = rawInformation as? [String: Any] else {
            return nil
        }

        return TelemetryCodeSignature(
            teamID: information[kSecCodeInfoTeamIdentifier as String] as? String,
            signingIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
            bundleID: bundleIdentifier(forExecutablePath: path)
        )
    }

    private func bundleIdentifier(forExecutablePath path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL

        while current.path != "/" {
            if current.pathExtension == "app",
               let bundle = Bundle(url: current),
               let identifier = bundle.bundleIdentifier {
                return identifier
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        return nil
    }

    private enum TargetKind {
        case bloat
        case intelligence
    }

    private struct MatchCandidate {
        let target: String
        let location: Int
    }

    private struct TargetDetection {
        let kind: TargetKind
        let name: String
        let telemetryMatch: TelemetryMatch?
    }

    // MARK: - Data Lookups (delegated to ProcessData)

    func friendlyDescription(for processName: String) -> String? {
        let key = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let desc = ProcessData.friendlyDescriptions[key] {
            return desc
        }
        if key.contains("widget") {
            return "Widget extension · Background widget process"
        }
        return nil
    }

    func launchItemDescription(for label: String, path: String) -> String? {
        let lowerLabel = label.lowercased()
        let lowerPath = path.lowercased()

        for (keyword, desc) in ProcessData.launchItemDescriptions {
            if lowerLabel.contains(keyword) || lowerPath.contains(keyword) {
                return desc
            }
        }
        return nil
    }

    func isLaunchdManaged(_ processName: String) -> Bool {
        return ProcessData.launchdManagedProcesses[processName.lowercased()] != nil
    }

    func getLaunchdInfo(_ processName: String) -> LaunchdProcess? {
        return ProcessData.launchdManagedProcesses[processName.lowercased()]
    }

    func vendorFor(processName: String) -> String {
        let lower = processName.lowercased()
        for (vendor, patterns) in ProcessData.vendorPatterns where patterns.contains(where: { lower.contains($0) }) {
            return vendor
        }
        if lower.contains("widget") {
            return "Apple"
        }
        return "Other"
    }

    private func telemetryRequiresSystemPrivilege(_ signature: TelemetrySignature?) -> Bool {
        signature?.launchdDomain == .system || signature?.launchdDomain == .both
    }

    private func bestStaticTargetMatch(executablePath: String, executableName: String, command: String, targets: [String]) -> String? {
        let pathTokens = staticPathTokens(from: executablePath)
        let commandName = commandExecutableName(from: command)

        return targets.compactMap { target -> MatchCandidate? in
            let normalizedTarget = normalizedStaticToken(target)
            guard !normalizedTarget.isEmpty else { return nil }

            if normalizedStaticToken(executableName) == normalizedTarget {
                return MatchCandidate(target: target, location: 0)
            }

            if pathTokens.contains(normalizedTarget) {
                return MatchCandidate(target: target, location: 1)
            }

            if commandName.map(normalizedStaticToken(_:)) == normalizedTarget {
                return MatchCandidate(target: target, location: 2)
            }

            return nil
        }.sorted { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.target.count > rhs.target.count
        }.first?.target
    }

    private func staticPathTokens(from path: String) -> Set<String> {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let components = standardized.pathComponents

        return Set(components.flatMap { component -> [String] in
            let normalizedComponent = normalizedStaticToken(component)
            guard !normalizedComponent.isEmpty else { return [] }

            var tokens = [normalizedComponent]
            if normalizedComponent.hasSuffix(".app") {
                tokens.append(String(normalizedComponent.dropLast(4)))
            }
            if normalizedComponent.hasSuffix(".appex") {
                tokens.append(String(normalizedComponent.dropLast(6)))
            }
            return tokens
        })
    }

    private func commandExecutableName(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let quotedName = quotedCommandExecutableName(from: trimmed) {
            return quotedName
        }

        let firstToken = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map(String.init)
        guard let firstToken, !firstToken.isEmpty else { return nil }
        return executableName(from: firstToken)
    }

    private func quotedCommandExecutableName(from command: String) -> String? {
        guard let first = command.first, first == "\"" || first == "'" else { return nil }
        let delimiter = first
        let remainder = command.dropFirst()
        guard let closingIndex = remainder.firstIndex(of: delimiter) else { return nil }
        let executable = String(remainder[..<closingIndex])
        guard !executable.isEmpty else { return nil }
        return executableName(from: executable)
    }

    private func normalizedStaticToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func heuristicTarget(executableName: String, command: String) -> TargetDetection? {
        let lowerExec = executableName.lowercased()

        if command.contains(".appex/Contents/MacOS/"), lowerExec.contains("widget") {
            return TargetDetection(kind: .bloat, name: executableName, telemetryMatch: nil)
        }

        if ProcessData.extraWidgetExecutableNames.contains(executableName) {
            return TargetDetection(kind: .bloat, name: executableName, telemetryMatch: nil)
        }

        switch lowerExec {
        case "simdiskimaged":
            return TargetDetection(kind: .bloat, name: "simdiskimaged", telemetryMatch: nil)
        case "simlaunchhost.arm64":
            return TargetDetection(kind: .bloat, name: "SimLaunchHost.arm64", telemetryMatch: nil)
        case "biomeagent":
            return TargetDetection(kind: .intelligence, name: "BiomeAgent", telemetryMatch: nil)
        case "contextstored":
            return TargetDetection(kind: .intelligence, name: "contextstored", telemetryMatch: nil)
        case "contextstoreagent":
            return TargetDetection(kind: .intelligence, name: "ContextStoreAgent", telemetryMatch: nil)
        case "intelligenceplatformcomputeservice":
            return TargetDetection(kind: .intelligence, name: "IntelligencePlatformComputeService", telemetryMatch: nil)
        case "saextensionorchestrator":
            return TargetDetection(kind: .intelligence, name: "SAExtensionOrchestrator", telemetryMatch: nil)
        case "biomeselfingestor":
            return TargetDetection(kind: .intelligence, name: "BiomeSELFIngestor", telemetryMatch: nil)
        case "intelligenceflowd":
            return TargetDetection(kind: .intelligence, name: "intelligenceflowd", telemetryMatch: nil)
        case "intelligencetasksd":
            return TargetDetection(kind: .intelligence, name: "intelligencetasksd", telemetryMatch: nil)
        case "knowledgeconstructiond":
            return TargetDetection(kind: .intelligence, name: "knowledgeconstructiond", telemetryMatch: nil)
        case "callintelligenced":
            return TargetDetection(kind: .intelligence, name: "callintelligenced", telemetryMatch: nil)
        default:
            break
        }

        return nil
    }

    private func detectTarget(pid: Int32, executablePath: String, command: String) -> TargetDetection? {
        let executableName = executableName(from: executablePath)
        let bloatTargets = ProcessData.bloatTargets
        let intelligenceTargets = ProcessData.intelligenceTargets

        if let exactBloat = bestStaticTargetMatch(executablePath: executablePath, executableName: executableName, command: command, targets: bloatTargets) {
            return TargetDetection(kind: .bloat, name: exactBloat, telemetryMatch: nil)
        }
        if let exactIntel = bestStaticTargetMatch(executablePath: executablePath, executableName: executableName, command: command, targets: intelligenceTargets) {
            return TargetDetection(kind: .intelligence, name: exactIntel, telemetryMatch: nil)
        }

        if let heuristic = heuristicTarget(executableName: executableName, command: command) {
            return heuristic
        }

        guard CloudSignatureManager.shared.hasCloudLocatorCandidate(
            executablePath: executablePath,
            executableName: executableName,
            command: command
        ) else {
            return nil
        }

        let observation = TelemetryProcessObservation(
            pid: pid,
            executablePath: executablePath,
            executableName: executableName,
            command: command,
            codeSignature: codeSignature(forExecutablePath: executablePath)
        )

        if let cloudMatch = CloudSignatureManager.shared.matchCloudSignature(observation: observation) {
            let kind: TargetKind = cloudMatch.signature.category == .bloat ? .bloat : .intelligence
            return TargetDetection(kind: kind, name: cloudMatch.signature.displayName, telemetryMatch: cloudMatch)
        }

        return nil
    }

    // MARK: - Scanning

    func scanForRunningTargetsWithResources() throws -> (bloat: [ProcessItem], intelligence: [ProcessItem]) {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "pid,%cpu,rss,comm,command"])
        guard result.succeeded else {
            MiloLog.error("Process scan command failed with status \(result.status)", category: .process)
            throw MiloOperationFailure(
                operation: .scan,
                code: .system,
                message: "Milo could not inspect running processes.",
                recovery: "Try scanning again. If the problem continues, restart Milo."
            )
        }

        let lines = result.stdout.components(separatedBy: .newlines)

        var bloatMatches: [String: (cpu: Double, mem: Double, pids: Set<Int32>, telemetryMatch: TelemetryMatch?)] = [:]
        var intelMatches: [String: (cpu: Double, mem: Double, pids: Set<Int32>, telemetryMatch: TelemetryMatch?)] = [:]

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 5 else { continue }

            guard let pid = Int32(String(parts[0])) else { continue }
            let cpu = Double(parts[1]) ?? 0.0
            let memKB = Double(parts[2]) ?? 0.0
            let memMB = memKB / 1024.0
            let executable = resolvedExecutablePath(pid: pid, fallback: String(parts[3]))
            let command = String(parts[4])

            if let detection = detectTarget(pid: pid, executablePath: executable, command: command) {
                switch detection.kind {
                case .bloat:
                    var existing = bloatMatches[detection.name] ?? (0, 0, Set<Int32>(), detection.telemetryMatch)
                    existing.cpu += cpu
                    existing.mem += memMB
                    existing.pids.insert(pid)
                    if existing.telemetryMatch == nil {
                        existing.telemetryMatch = detection.telemetryMatch
                    }
                    bloatMatches[detection.name] = existing
                case .intelligence:
                    var existing = intelMatches[detection.name] ?? (0, 0, Set<Int32>(), detection.telemetryMatch)
                    existing.cpu += cpu
                    existing.mem += memMB
                    existing.pids.insert(pid)
                    if existing.telemetryMatch == nil {
                        existing.telemetryMatch = detection.telemetryMatch
                    }
                    intelMatches[detection.name] = existing
                }
            }
        }

        let bloatItems = bloatMatches.map { name, stats in
            let launchdInfo = getLaunchdInfo(name)
            let telemetrySignature = stats.telemetryMatch?.signature
            return ProcessItem(
                name: name,
                description: telemetrySignature.map { "\($0.vendor) · Signed telemetry rule" } ?? friendlyDescription(for: name),
                vendor: telemetrySignature?.vendor ?? vendorFor(processName: name),
                cpuUsage: stats.cpu,
                memoryMB: stats.mem,
                isLaunchdManaged: launchdInfo != nil || telemetrySignature?.launchdLabel != nil,
                isSystemProcess: launchdInfo?.isSystem ?? telemetryRequiresSystemPrivilege(telemetrySignature),
                matchedPIDs: stats.pids,
                telemetryRuleID: telemetrySignature?.ruleID,
                terminationStrategy: telemetrySignature?.terminationStrategy,
                launchdLabel: telemetrySignature?.launchdLabel,
                launchdDomain: telemetrySignature?.launchdDomain
            )
        }.sorted { $0.name < $1.name }

        let intelItems = intelMatches.map { name, stats in
            let launchdInfo = getLaunchdInfo(name)
            let telemetrySignature = stats.telemetryMatch?.signature
            return ProcessItem(
                name: name,
                description: telemetrySignature.map { "\($0.vendor) · Signed telemetry rule" } ?? friendlyDescription(for: name),
                vendor: telemetrySignature?.vendor ?? vendorFor(processName: name),
                cpuUsage: stats.cpu,
                memoryMB: stats.mem,
                isLaunchdManaged: launchdInfo != nil || telemetrySignature?.launchdLabel != nil,
                isSystemProcess: launchdInfo?.isSystem ?? telemetryRequiresSystemPrivilege(telemetrySignature),
                matchedPIDs: stats.pids,
                telemetryRuleID: telemetrySignature?.ruleID,
                terminationStrategy: telemetrySignature?.terminationStrategy,
                launchdLabel: telemetrySignature?.launchdLabel,
                launchdDomain: telemetrySignature?.launchdDomain
            )
        }.sorted { $0.name < $1.name }

        return (bloatItems, intelItems)
    }

    func scanForRunningTargets() -> (bloat: [String], intelligence: [String]) {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "pid,comm,command"])
        guard result.succeeded else {
            MiloLog.error("Failed to scan processes: \(result.stderr)", category: .process)
            return ([], [])
        }

        let lines = result.stdout.components(separatedBy: .newlines)
        var foundBloat: Set<String> = []
        var foundIntel: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(String(parts[0])) else { continue }

            let executable = resolvedExecutablePath(pid: pid, fallback: String(parts[1]))
            let command = String(parts[2])

            if let detection = detectTarget(pid: pid, executablePath: executable, command: command) {
                switch detection.kind {
                case .bloat:
                    foundBloat.insert(detection.name)
                case .intelligence:
                    foundIntel.insert(detection.name)
                }
            }
        }

        return (Array(foundBloat).sorted(), Array(foundIntel).sorted())
    }

    // MARK: - Killing

    /// Kill processes gracefully (SIGTERM then SIGKILL) on a background thread.
    /// Calls completion on main queue with results.
    func killProcessesGracefully(names: [String], completion: @escaping @Sendable ([KillResult]) -> Void) {
        let items = names.map { name in
            let launchdInfo = getLaunchdInfo(name)
            return ProcessItem(
                name: name,
                description: friendlyDescription(for: name),
                vendor: vendorFor(processName: name),
                cpuUsage: 0,
                memoryMB: 0,
                isLaunchdManaged: launchdInfo != nil,
                isSystemProcess: launchdInfo?.isSystem ?? false
            )
        }
        killProcessesGracefully(items: items, completion: completion)
    }

    /// Kill detected process items using their recorded match metadata. Signed
    /// cloud rules are terminated by exact PID or launchd label; broad
    /// command-line substring termination is intentionally forbidden.
    func killProcessesGracefully(items: [ProcessItem], completion: @escaping @Sendable ([KillResult]) -> Void) {
        let names = items.map(\.name)
        guard !names.isEmpty else {
            completion([])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var results: [KillResult] = []

            var regularProcesses: [ProcessItem] = []
            var launchdProcesses: [(name: String, info: LaunchdProcess)] = []
            var telemetryProcesses: [ProcessItem] = []

            for item in items {
                if item.telemetryRuleID != nil {
                    telemetryProcesses.append(item)
                } else if let info = getLaunchdInfo(item.name) {
                    launchdProcesses.append((item.name, info))
                } else {
                    regularProcesses.append(item)
                }
            }

            let regularPIDResults = regularProcesses.map { item in
                let pids = exactPIDs(forStaticTarget: item)
                let success = terminatePIDs(pids, privileged: false)
                return (item: item, success: success)
            }

            for (name, info) in launchdProcesses {
                let success = disableLaunchdProcess(info)
                results.append(KillResult(name: name, success: success, isLaunchdManaged: true, requiresSIPDisabled: info.isSystem))
            }

            for item in telemetryProcesses {
                let success = terminateTelemetryItem(item)
                results.append(
                    KillResult(
                        name: item.name,
                        success: success,
                        isLaunchdManaged: item.isLaunchdManaged,
                        requiresSIPDisabled: item.isSystemProcess
                    )
                )
            }

            // Wait for processes to die before verifying
            Thread.sleep(forTimeInterval: 1.0)

            let (remainingBloat, remainingIntel) = scanForRunningTargets()
            let remaining = Set((remainingBloat + remainingIntel).map { $0.lowercased() })

            for result in regularPIDResults {
                let stillRunning = remaining.contains(result.item.name.lowercased())
                results.append(
                    KillResult(
                        name: result.item.name,
                        success: result.success && !stillRunning,
                        isLaunchdManaged: false,
                        requiresSIPDisabled: false
                    )
                )
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    private func terminateTelemetryItem(_ item: ProcessItem) -> Bool {
        guard let strategy = item.terminationStrategy else { return false }

        switch strategy {
        case .none:
            return false
        case .signal:
            return terminatePIDs(item.matchedPIDs, privileged: false)
        case .launchctlBootout:
            let launchctlSucceeded = runTelemetryLaunchctl(label: item.launchdLabel, domain: item.launchdDomain, disableFirst: false)
            let signalSucceeded = terminatePIDs(item.matchedPIDs, privileged: item.isSystemProcess)
            return launchctlSucceeded || signalSucceeded
        case .launchctlDisable:
            let launchctlSucceeded = runTelemetryLaunchctl(label: item.launchdLabel, domain: item.launchdDomain, disableFirst: true)
            let signalSucceeded = terminatePIDs(item.matchedPIDs, privileged: item.isSystemProcess)
            return launchctlSucceeded || signalSucceeded
        }
    }

    private func terminatePIDs(_ pids: Set<Int32>, privileged: Bool) -> Bool {
        guard !pids.isEmpty else { return false }

        if privileged {
            var commands: [PrivilegedCommand] = []
            appendTermKillCommands(for: pids, to: &commands)
            return runPrivilegedCommands(commands)
        }

        var accepted = true
        for pid in pids.sorted() where !runKill(signal: "-TERM", pid: pid, privileged: privileged) {
            accepted = false
        }

        Thread.sleep(forTimeInterval: 1.0)

        for pid in pids.sorted() where !runKill(signal: "-KILL", pid: pid, privileged: privileged) {
            accepted = false
        }

        return accepted
    }

    private func exactPIDs(forStaticTarget item: ProcessItem) -> Set<Int32> {
        if !item.matchedPIDs.isEmpty {
            return item.matchedPIDs
        }
        return exactPIDs(matchingStaticTargetName: item.name)
    }

    private func exactPIDs(matchingStaticTargetName targetName: String) -> Set<Int32> {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "pid,comm,command"])
        guard result.succeeded else {
            MiloLog.error("Failed to enumerate exact process identifiers for \(targetName): \(result.stderr)", category: .process)
            return []
        }

        return Set(result.stdout.components(separatedBy: .newlines).compactMap { line -> Int32? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(String(parts[0])) else {
                return nil
            }

            let executable = resolvedExecutablePath(pid: pid, fallback: String(parts[1]))
            let command = String(parts[2])
            let executableName = executableName(from: executable)
            return bestStaticTargetMatch(
                executablePath: executable,
                executableName: executableName,
                command: command,
                targets: [targetName]
            ) == nil ? nil : pid
        })
    }

    private func runTelemetryLaunchctl(label: String?, domain: TelemetryLaunchdDomain?, disableFirst: Bool) -> Bool {
        guard let label,
              let safeLabel = Self.validateLaunchdLabel(label),
              let domain else {
            return false
        }

        let uid = getuid()
        var accepted = true
        let domains: [(String, Bool)]
        switch domain {
        case .gui:
            domains = [("gui/\(uid)", false)]
        case .system:
            domains = [("system", true)]
        case .both:
            domains = [("gui/\(uid)", false), ("system", true)]
        }

        for (launchdDomain, privileged) in domains {
            var privilegedCommands: [PrivilegedCommand] = []
            let disableArguments = ["disable", "\(launchdDomain)/\(safeLabel)"]
            let bootoutArguments = ["bootout", "\(launchdDomain)/\(safeLabel)"]

            if privileged {
                if disableFirst {
                    privilegedCommands.append(launchctlCommand(disableArguments))
                }
                privilegedCommands.append(launchctlCommand(bootoutArguments))
                if !runPrivilegedCommands(privilegedCommands) {
                    accepted = false
                }
            } else {
                if disableFirst, !runLaunchctl(disableArguments) {
                    accepted = false
                }
                if !runLaunchctl(bootoutArguments) {
                    accepted = false
                }
            }
        }

        return accepted
    }

    // MARK: - Launchd Control

    private func disableLaunchdProcess(_ info: LaunchdProcess) -> Bool {
        guard let safeLabel = Self.validateLaunchdLabel(info.label) else { return false }
        let uid = getuid()
        let plistPath = Self.validatePlistPath(info.plistPath)
        let isDaemon = plistPath?.contains("/LaunchDaemons/") ?? info.plistPath.contains("LaunchDaemons")
        let admin = plistPath.map(Self.requiresAdministrator(forPlistPath:)) ?? isDaemon
        var accepted = true
        var privilegedCommands: [PrivilegedCommand] = []

        if isDaemon || info.isSystem {
            let arguments = ["disable", "system/\(safeLabel)"]
            if admin {
                privilegedCommands.append(launchctlCommand(arguments))
            } else if !runLaunchctl(arguments) && !info.isSystem {
                accepted = false
            }
        }

        if isDaemon {
            let arguments = ["bootout", "system/\(safeLabel)"]
            if admin {
                privilegedCommands.append(launchctlCommand(arguments))
            } else {
                _ = runLaunchctl(arguments)
            }
        }

        _ = runLaunchctl(["disable", "gui/\(uid)/\(safeLabel)"])
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(safeLabel)"])

        if let plistPath, FileManager.default.fileExists(atPath: plistPath) {
            let arguments = ["unload", "-w", plistPath]
            if admin {
                privilegedCommands.append(launchctlCommand(arguments))
            } else {
                _ = runLaunchctl(arguments)
            }
        }

        for relatedLabel in info.relatedLabels {
            guard let safeRelated = Self.validateLaunchdLabel(relatedLabel) else { continue }
            if admin {
                privilegedCommands.append(launchctlCommand(["disable", "system/\(safeRelated)"]))
            } else {
                _ = runLaunchctl(["disable", "system/\(safeRelated)"])
            }
            _ = runLaunchctl(["disable", "gui/\(uid)/\(safeRelated)"])
            if admin {
                privilegedCommands.append(launchctlCommand(["bootout", "system/\(safeRelated)"]))
            } else {
                _ = runLaunchctl(["bootout", "system/\(safeRelated)"])
            }
            _ = runLaunchctl(["bootout", "gui/\(uid)/\(safeRelated)"])
        }

        let pids = exactPIDs(matchingStaticTargetName: info.processName)
        if admin {
            appendTermKillCommands(for: pids, to: &privilegedCommands)
        } else {
            _ = terminatePIDs(pids, privileged: false)
        }

        if !runPrivilegedCommands(privilegedCommands) {
            accepted = false
        }

        return accepted && (!info.isSystem || !SIPChecker.isSIPEnabled())
    }

    func enableLaunchdProcess(_ info: LaunchdProcess) -> Bool {
        let uid = getuid()
        guard let safeLabel = Self.validateLaunchdLabel(info.label) else { return false }
        let plistPath = Self.validatePlistPath(info.plistPath)
        let admin = plistPath.map(Self.requiresAdministrator(forPlistPath:)) ?? info.plistPath.contains("LaunchDaemons")
        var accepted = true
        var privilegedCommands: [PrivilegedCommand] = []

        if plistPath?.contains("/LaunchDaemons/") ?? info.isSystem {
            let arguments = ["enable", "system/\(safeLabel)"]
            if admin {
                privilegedCommands.append(launchctlCommand(arguments))
            } else if !runLaunchctl(arguments) && !info.isSystem {
                accepted = false
            }
        }
        _ = runLaunchctl(["enable", "gui/\(uid)/\(safeLabel)"])

        if let plistPath, FileManager.default.fileExists(atPath: plistPath) {
            let domain = plistPath.contains("/LaunchDaemons/") ? "system" : "gui/\(uid)"
            if admin {
                privilegedCommands.append(launchctlCommand(["bootstrap", domain, plistPath]))
                privilegedCommands.append(launchctlCommand(["load", "-w", plistPath]))
            } else {
                _ = runLaunchctl(["bootstrap", domain, plistPath])
                _ = runLaunchctl(["load", "-w", plistPath])
            }
        }

        for relatedLabel in info.relatedLabels {
            guard let safeRelated = Self.validateLaunchdLabel(relatedLabel) else { continue }
            _ = runLaunchctl(["enable", "gui/\(uid)/\(safeRelated)"])
        }

        if !runPrivilegedCommands(privilegedCommands) {
            accepted = false
        }

        return accepted
    }

    // MARK: - Launch Items (Auto-Start Manager)

    func scanForLaunchItems() -> [LaunchItem] {
        let paths = [
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents"
        ]

        var results: [LaunchItem] = []

        for path in paths {
            do {
                let items = try FileManager.default.contentsOfDirectory(atPath: path)
                for item in items {
                    guard item.hasSuffix(".plist") else { continue }

                    let fullPath = path + "/" + item
                    let lowerItem = item.lowercased()

                    if ProcessData.launchItemKeywords.contains(where: { lowerItem.contains($0) }) {
                        var label = getPlistLabel(at: fullPath)

                        if label == nil || label?.isEmpty == true {
                            label = String(item.dropLast(6))
                        }

                        guard let finalLabel = label, !finalLabel.isEmpty else { continue }

                        let isLoaded = isLaunchItemLoaded(label: finalLabel, path: fullPath)
                        let desc = launchItemDescription(for: finalLabel, path: fullPath)
                        results.append(LaunchItem(path: fullPath, label: finalLabel, isLoaded: isLoaded, description: desc))
                    }
                }
            } catch {
                continue
            }
        }
        return results.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func toggleLaunchItem(path: String, enable: Bool) {
        var label = getPlistLabel(at: path)

        if label == nil || label?.isEmpty == true {
            let filename = (path as NSString).lastPathComponent
            if filename.hasSuffix(".plist") {
                label = String(filename.dropLast(6))
            }
        }

        guard let finalLabel = label, !finalLabel.isEmpty else {
            MiloLog.warning("Failed to determine label for plist at: \(path)", category: .process)
            return
        }

        let uid = getuid()

        let isDaemon = path.contains("/LaunchDaemons/")
        let domain = isDaemon ? "system" : "gui/\(uid)"

        guard let safeLabel = Self.validateLaunchdLabel(finalLabel) else {
            MiloLog.warning("Rejected toggle for unsafe label: \(finalLabel)", category: .process)
            return
        }
        guard let safePath = Self.validatePlistPath(path) else {
            MiloLog.warning("Rejected toggle for unsafe path: \(path)", category: .process)
            return
        }
        let requiresAdmin = Self.requiresAdministrator(forPlistPath: safePath)
        var privilegedCommands: [PrivilegedCommand] = []

        if enable {
            let commands = [
                ["enable", "\(domain)/\(safeLabel)"],
                ["bootstrap", domain, safePath],
                ["load", "-w", safePath]
            ]
            if requiresAdmin {
                privilegedCommands.append(contentsOf: commands.map(launchctlCommand(_:)))
            } else {
                for command in commands {
                    _ = runLaunchctl(command)
                }
            }
        } else {
            let commands = [
                ["bootout", "\(domain)/\(safeLabel)"],
                ["disable", "\(domain)/\(safeLabel)"],
                ["unload", "-w", safePath]
            ]
            if requiresAdmin {
                privilegedCommands.append(contentsOf: commands.map(launchctlCommand(_:)))
                appendTermKillCommands(for: exactPIDs(matchingStaticTargetName: safeLabel), to: &privilegedCommands)
            } else {
                for command in commands {
                    _ = runLaunchctl(command)
                }
                _ = terminatePIDs(exactPIDs(matchingStaticTargetName: safeLabel), privileged: false)
            }
        }

        _ = runPrivilegedCommands(privilegedCommands)
    }

    // MARK: - Helpers

    private func getPlistLabel(at path: String) -> String? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                return plist["Label"] as? String
            }
        } catch {
            MiloLog.error("Error reading or parsing plist at \(path): \(error.localizedDescription)", category: .process)
        }
        return nil
    }

    private func isLaunchItemLoaded(label: String, path: String) -> Bool {
        let uid = getuid()
        let domain = path.contains("/LaunchDaemons/") ? "system" : "gui/\(uid)"
        return CommandRunner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(label)"]).succeeded
    }
}
