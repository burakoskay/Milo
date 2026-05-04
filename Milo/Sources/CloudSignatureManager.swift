import Foundation

enum TelemetryCategory: String, Codable, Hashable {
    case bloat
    case intelligence
}

enum TelemetryTerminationStrategy: String, Codable, Hashable {
    case signal
    case launchctlBootout = "launchctl_bootout"
    case launchctlDisable = "launchctl_disable"
    case none
}

enum TelemetryLaunchdDomain: String, Codable, Hashable {
    case gui
    case system
    case both
}

struct TelemetryCodeSignature: Hashable {
    let teamID: String?
    let signingIdentifier: String?
    let bundleID: String?
}

struct TelemetryProcessObservation {
    let pid: Int32
    let executablePath: String
    let executableName: String
    let command: String
    let codeSignature: TelemetryCodeSignature?
}

struct TelemetrySignature: Codable, Hashable, Identifiable {
    var id: String { ruleID }

    let ruleID: String
    let schemaVersion: Int
    let signatureSetVersion: String
    let vendor: String
    let category: TelemetryCategory
    let displayName: String
    let processName: String
    let launchdLabel: String?
    let launchdDomain: TelemetryLaunchdDomain
    let bundleID: String?
    let executablePathPattern: String?
    let teamID: String?
    let signingIdentifier: String?
    let minMacOS: String?
    let maxMacOS: String?
    let terminationStrategy: TelemetryTerminationStrategy
    let severity: Int
}

struct TelemetryMatch: Hashable {
    let signature: TelemetrySignature
    let matchedPID: Int32
}

/// Zero-Debt Cloud Signature Manager
/// Holds signed telemetry rules and enforces multi-factor match semantics before
/// the process manager is allowed to display or terminate a cloud target.
final class CloudSignatureManager {
    static let shared = CloudSignatureManager()

    private var cloudRules: [TelemetrySignature]
    private let lock = NSLock()

    private init() {
        cloudRules = Self.validatedRules(Self.bundledFallbackRules)
    }

    /// Thread-safe update of the in-memory signatures.
    func updateCloudSignatures(_ signatures: [TelemetrySignature], signatureSetVersion: String) {
        let normalizedRules = Self.validatedRules(signatures)
        let activeRules = Self.mergedRules(primary: normalizedRules, fallback: Self.bundledFallbackRules)

        lock.lock()
        cloudRules = activeRules
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("MiloCloudSignaturesChanged"), object: signatureSetVersion)
            NotificationCenter.default.post(name: NSNotification.Name("MiloRequestCurrentBloatCount"), object: nil)
        }
    }

    func clearCloudSignatures() {
        let fallbackRules = Self.validatedRules(Self.bundledFallbackRules)

        lock.lock()
        cloudRules = fallbackRules
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("MiloCloudSignaturesChanged"), object: nil)
        }
    }

    /// Compatibility accessor for static UI counts. Actual cloud matching is
    /// performed by `matchCloudSignature(observation:)`.
    func getCombinedBloatTargets() -> [String] {
        let cloudTargets = currentRules()
            .filter { $0.category == .bloat }
            .map(\.displayName)
        return Array(Set(ProcessData.bloatTargets + cloudTargets)).sorted()
    }

    func getCombinedIntelligenceTargets() -> [String] {
        let cloudTargets = currentRules()
            .filter { $0.category == .intelligence }
            .map(\.displayName)
        return Array(Set(ProcessData.intelligenceTargets + cloudTargets)).sorted()
    }

    func matchCloudSignature(observation: TelemetryProcessObservation) -> TelemetryMatch? {
        currentRules()
            .filter { Self.isCompatibleWithCurrentMacOS($0) }
            .filter { Self.hasLocatorMatch(rule: $0, observation: observation) }
            .filter { Self.hasStrongIdentityMatch(rule: $0, codeSignature: observation.codeSignature) }
            .filter { !Self.isProtectedTarget(rule: $0, observation: observation) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.displayName.count > rhs.displayName.count
            }
            .first
            .map { TelemetryMatch(signature: $0, matchedPID: observation.pid) }
    }

    func hasCloudLocatorCandidate(executablePath: String, executableName: String, command: String) -> Bool {
        let observation = TelemetryProcessObservation(
            pid: 0,
            executablePath: executablePath,
            executableName: executableName,
            command: command,
            codeSignature: nil
        )

        return currentRules()
            .filter { Self.isCompatibleWithCurrentMacOS($0) }
            .contains { Self.hasLocatorMatch(rule: $0, observation: observation) }
    }

    private func currentRules() -> [TelemetrySignature] {
        lock.lock()
        let rules = cloudRules
        lock.unlock()
        return rules
    }

    private static func mergedRules(primary: [TelemetrySignature], fallback: [TelemetrySignature]) -> [TelemetrySignature] {
        var byID: [String: TelemetrySignature] = [:]
        for rule in fallback {
            byID[rule.ruleID] = rule
        }
        for rule in primary {
            byID[rule.ruleID] = rule
        }
        return byID.values.sorted { $0.ruleID < $1.ruleID }
    }

    private static func validatedRules(_ rules: [TelemetrySignature]) -> [TelemetrySignature] {
        rules.compactMap { rule in
            guard rule.schemaVersion == 2 else { return nil }
            guard isSafeIdentifier(rule.ruleID, maxLength: 128, allowSpaces: false) else { return nil }
            guard isSafeIdentifier(rule.vendor, maxLength: 80, allowSpaces: true) else { return nil }
            guard isSafeDisplayText(rule.displayName, maxLength: 160) else { return nil }
            guard isSafeDisplayText(rule.processName, maxLength: 160) else { return nil }
            guard hasAnyStrongIdentity(rule) else { return nil }
            guard !isRuleIntrinsicallyProtected(rule) else { return nil }
            guard rule.severity >= 0 && rule.severity <= 3 else { return nil }
            guard rule.executablePathPattern.map(isSafePathPattern(_:)) ?? true else { return nil }
            guard rule.launchdLabel.map(isSafeLaunchdLabel(_:)) ?? true else { return nil }
            return rule
        }.sorted { $0.ruleID < $1.ruleID }
    }

    private static func hasAnyStrongIdentity(_ rule: TelemetrySignature) -> Bool {
        normalized(rule.teamID) != nil
            || normalized(rule.signingIdentifier) != nil
            || normalized(rule.bundleID) != nil
    }

    private static func hasLocatorMatch(rule: TelemetrySignature, observation: TelemetryProcessObservation) -> Bool {
        let processName = rule.processName.lowercased()
        let executableName = observation.executableName.lowercased()
        let command = observation.command.lowercased()

        if executableName == processName || command.contains(processName) {
            return true
        }

        if let pathPattern = rule.executablePathPattern,
           wildcardMatch(pattern: pathPattern.lowercased(), value: observation.executablePath.lowercased()) {
            return true
        }

        return false
    }

    private static func hasStrongIdentityMatch(rule: TelemetrySignature, codeSignature: TelemetryCodeSignature?) -> Bool {
        guard let codeSignature else { return false }

        if let teamID = normalized(rule.teamID),
           normalized(codeSignature.teamID) != teamID {
            return false
        }

        if let signingIdentifier = normalized(rule.signingIdentifier),
           normalized(codeSignature.signingIdentifier) != signingIdentifier {
            return false
        }

        if let bundleID = normalized(rule.bundleID),
           normalized(codeSignature.bundleID) != bundleID {
            return false
        }

        return hasAnyStrongIdentity(rule)
    }

    private static func isCompatibleWithCurrentMacOS(_ rule: TelemetrySignature) -> Bool {
        let current = ProcessInfo.processInfo.operatingSystemVersion

        if let minimum = rule.minMacOS, compare(current, toVersionString: minimum) == .orderedAscending {
            return false
        }

        if let maximum = rule.maxMacOS, compare(current, toVersionString: maximum) == .orderedDescending {
            return false
        }

        return true
    }

    private static func compare(_ version: OperatingSystemVersion, toVersionString string: String) -> ComparisonResult {
        let currentComponents = [version.majorVersion, version.minorVersion, version.patchVersion]
        let targetComponents = parsedVersionComponents(string)

        for index in 0..<3 {
            let currentValue = currentComponents[index]
            let targetValue = targetComponents[index]
            if currentValue < targetValue { return .orderedAscending }
            if currentValue > targetValue { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func parsedVersionComponents(_ string: String) -> [Int] {
        let parts = string.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }

    private static func wildcardMatch(pattern: String, value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        let regexPattern = "^\(escaped)$"

        do {
            let regex = try NSRegularExpression(pattern: regexPattern)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.firstMatch(in: value, range: range) != nil
        } catch {
            return false
        }
    }

    private static func isProtectedTarget(rule: TelemetrySignature, observation: TelemetryProcessObservation) -> Bool {
        protectedProcessNames.contains(observation.executableName.lowercased())
            || protectedProcessNames.contains(rule.processName.lowercased())
            || rule.launchdLabel.map { protectedLaunchdLabels.contains($0.lowercased()) } ?? false
            || isRuleIntrinsicallyProtected(rule)
    }

    private static func isRuleIntrinsicallyProtected(_ rule: TelemetrySignature) -> Bool {
        let lowerName = rule.processName.lowercased()
        if protectedProcessNames.contains(lowerName) {
            return true
        }

        if let launchdLabel = rule.launchdLabel?.lowercased(), protectedLaunchdLabels.contains(launchdLabel) {
            return true
        }

        if let pathPattern = rule.executablePathPattern?.lowercased() {
            return protectedPathFragments.contains { pathPattern.contains($0) }
        }

        return false
    }

    private static func isSafeIdentifier(_ value: String, maxLength: Int, allowSpaces: Bool) -> Bool {
        let allowedCharacters = allowSpaces
            ? CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
            : CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func isSafeDisplayText(_ value: String, maxLength: Int) -> Bool {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-/+()"))
        guard !value.isEmpty, value.count <= maxLength else { return false }
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func isSafePathPattern(_ value: String) -> Bool {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-/+*()[]{}"))
        guard !value.isEmpty, value.count <= 512 else { return false }
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func isSafeLaunchdLabel(_ value: String) -> Bool {
        isSafeIdentifier(value, maxLength: 256, allowSpaces: false)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static let protectedProcessNames: Set<String> = [
        "kernel_task",
        "launchd",
        "windowserver",
        "loginwindow",
        "securityd",
        "syspolicyd",
        "taskgated",
        "tccd",
        "trustd",
        "amfid",
        "opendirectoryd",
        "distnoted",
        "notifyd",
        "powerd"
    ]

    private static let protectedLaunchdLabels: Set<String> = [
        "com.apple.windowserver",
        "com.apple.loginwindow",
        "com.apple.securityd",
        "com.apple.syspolicyd",
        "com.apple.taskgated",
        "com.apple.tccd",
        "com.apple.trustd",
        "com.apple.amfid",
        "com.apple.opendirectoryd"
    ]

    private static let protectedPathFragments: [String] = [
        "/system/library/coreservices/windowserver.app/",
        "/system/library/coreservices/loginwindow.app/",
        "/usr/libexec/securityd",
        "/usr/libexec/syspolicyd",
        "/usr/libexec/amfid"
    ]

    private static let bundledFallbackRules: [TelemetrySignature] = [
        TelemetrySignature(
            ruleID: "apple-intelligence-intelligenceplatformd-v2",
            schemaVersion: 2,
            signatureSetVersion: "bundled-v2",
            vendor: "Apple",
            category: .intelligence,
            displayName: "intelligenceplatformd",
            processName: "intelligenceplatformd",
            launchdLabel: "com.apple.intelligenceplatformd",
            launchdDomain: .both,
            bundleID: nil,
            executablePathPattern: "/System/Library/*/intelligenceplatformd",
            teamID: nil,
            signingIdentifier: "com.apple.intelligenceplatformd",
            minMacOS: nil,
            maxMacOS: nil,
            terminationStrategy: .launchctlDisable,
            severity: 2
        ),
        TelemetrySignature(
            ruleID: "apple-intelligence-siriknowledged-v2",
            schemaVersion: 2,
            signatureSetVersion: "bundled-v2",
            vendor: "Apple",
            category: .intelligence,
            displayName: "siriknowledged",
            processName: "siriknowledged",
            launchdLabel: "com.apple.siriknowledged",
            launchdDomain: .gui,
            bundleID: nil,
            executablePathPattern: "/System/Library/*/siriknowledged",
            teamID: nil,
            signingIdentifier: "com.apple.siriknowledged",
            minMacOS: nil,
            maxMacOS: nil,
            terminationStrategy: .launchctlDisable,
            severity: 2
        )
    ]
}
