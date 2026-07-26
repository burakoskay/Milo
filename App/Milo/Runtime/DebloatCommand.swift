import Foundation

enum DebloatCommand {
    case process(executable: String, arguments: [String], ignoreFailure: Bool)
    case touch(path: String, ignoreFailure: Bool)
    case removeFile(path: String, ignoreFailure: Bool)
    case killWidgetExtensions
    case adobeARMHelper(disable: Bool)

    static func parse(_ rawCommand: String) -> DebloatCommand? {
        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let adobeCommand = parseAdobeARMHelperCommand(trimmed) {
            return adobeCommand
        }
        if isWidgetKillPipeline(trimmed) {
            return .killWidgetExtensions
        }

        let stripped = stripIgnoredFailureSuffix(from: trimmed)
        guard let tokens = tokenize(stripped.command), !tokens.isEmpty else { return nil }

        switch executableName(tokens[0]) {
        case "defaults":
            return parseDefaults(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "launchctl":
            return parseLaunchctl(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "pluginkit":
            return parsePluginKit(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "killall":
            return parseKillAll(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "mdutil":
            return parseMDUtil(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "touch":
            return parseTouch(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "rm":
            return parseRemove(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        case "xattr":
            return parseXattr(tokens: tokens, ignoreFailure: stripped.ignoreFailure)
        default:
            return nil
        }
    }

    func run(privileged: Bool) -> Bool {
        switch self {
        case .process(let executable, let arguments, let ignoreFailure):
            let result = privileged
                ? CommandRunner.runPrivileged(executable, arguments: arguments)
                : CommandRunner.run(executable, arguments: arguments)
            return result.succeeded || (ignoreFailure && result.status != 126)
        case .touch(let path, let ignoreFailure):
            do {
                if !FileManager.default.fileExists(atPath: path) {
                    let created = FileManager.default.createFile(atPath: path, contents: Data())
                    return created || ignoreFailure
                }
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
                return true
            } catch {
                MiloLog.error(
                    .fileTouchFailed,
                    category: .persistence,
                    detail: "path=\(path) error=\(error.localizedDescription)"
                )
                return ignoreFailure
            }
        case .removeFile(let path, let ignoreFailure):
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                return true
            } catch {
                MiloLog.error(
                    .fileRemoveFailed,
                    category: .persistence,
                    detail: "path=\(path) error=\(error.localizedDescription)"
                )
                return ignoreFailure
            }
        case .killWidgetExtensions:
            Self.killWidgetExtensionProcesses()
            return true
        case .adobeARMHelper(let disable):
            Self.updateAdobeARMHelperLabels(disable: disable)
            return true
        }
    }

    private static func parseDefaults(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        var arguments = Array(tokens.dropFirst())
        if arguments.first == "-currentHost" {
            arguments.removeFirst()
            guard let parsed = parseDefaultsOperation(arguments: arguments) else { return nil }
            return .process(executable: "/usr/bin/defaults", arguments: ["-currentHost"] + parsed, ignoreFailure: ignoreFailure)
        }

        guard let parsed = parseDefaultsOperation(arguments: arguments) else { return nil }
        return .process(executable: "/usr/bin/defaults", arguments: parsed, ignoreFailure: ignoreFailure)
    }

    private static func parseDefaultsOperation(arguments: [String]) -> [String]? {
        guard arguments.count >= 3 else { return nil }
        let action = arguments[0]
        let domain = arguments[1]
        let key = arguments[2]
        guard isSafeDefaultsDomain(domain), isSafeDefaultsKey(key) else { return nil }

        if action == "delete", arguments.count == 3 {
            return arguments
        }

        if action == "write", arguments.count == 4 {
            guard isSafeDefaultsStringValue(arguments[3]) else { return nil }
            return arguments
        }

        guard action == "write", arguments.count == 5 else { return nil }
        let valueType = arguments[3]
        let value = arguments[4]
        switch valueType {
        case "-bool":
            guard value == "true" || value == "false" else { return nil }
        case "-int":
            guard Int(value) != nil else { return nil }
        case "-float":
            guard Double(value) != nil else { return nil }
        case "-string":
            guard isSafeDefaultsStringValue(value) else { return nil }
        default:
            return nil
        }
        return arguments
    }

    private static func parseLaunchctl(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        let arguments = Array(tokens.dropFirst())
        guard let action = arguments.first else { return nil }

        if ["disable", "enable", "bootout"].contains(action), arguments.count == 2 {
            guard isSafeLaunchctlDomainTarget(arguments[1]) else { return nil }
            return .process(executable: "/bin/launchctl", arguments: arguments, ignoreFailure: ignoreFailure)
        }

        if ["load", "unload"].contains(action), arguments.count == 3, arguments[1] == "-w" {
            guard isSafeLaunchctlPlistPath(arguments[2]) else { return nil }
            return .process(executable: "/bin/launchctl", arguments: arguments, ignoreFailure: ignoreFailure)
        }

        return nil
    }

    private static func parsePluginKit(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        let arguments = Array(tokens.dropFirst())
        guard arguments.count == 4,
              arguments[0] == "-e",
              ["ignore", "use"].contains(arguments[1]),
              arguments[2] == "-i",
              isSafeBundleIdentifier(arguments[3]) else {
            return nil
        }
        return .process(executable: "/usr/bin/pluginkit", arguments: arguments, ignoreFailure: ignoreFailure)
    }

    private static func parseKillAll(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        let arguments = Array(tokens.dropFirst())
        let allowedNames: Set<String> = ["Finder", "Dock", "SystemUIServer", "cfprefsd", "NotificationCenter"]
        guard arguments.count == 1, allowedNames.contains(arguments[0]) else { return nil }
        return .process(executable: "/usr/bin/killall", arguments: arguments, ignoreFailure: ignoreFailure)
    }

    private static func parseMDUtil(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        let arguments = Array(tokens.dropFirst())
        guard arguments == ["-a", "-i", "off"] || arguments == ["-a", "-i", "on"] else { return nil }
        return .process(executable: "/usr/bin/mdutil", arguments: arguments, ignoreFailure: ignoreFailure)
    }

    private static func parseTouch(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        guard tokens.count == 2, isWidgetMarkerPath(tokens[1]) else { return nil }
        return .touch(path: tokens[1], ignoreFailure: ignoreFailure)
    }

    private static func parseRemove(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        guard tokens.count == 3, tokens[1] == "-f", isWidgetMarkerPath(tokens[2]) else { return nil }
        return .removeFile(path: tokens[2], ignoreFailure: ignoreFailure)
    }

    private static func parseXattr(tokens: [String], ignoreFailure: Bool) -> DebloatCommand? {
        let arguments = Array(tokens.dropFirst())
        if arguments.count == 4,
           arguments[0] == "-w",
           arguments[1] == "com.apple.quarantine",
           arguments[2] == "0181;00000000;blocked;",
           isSafeStockAppPath(arguments[3]) {
            return .process(executable: "/usr/bin/xattr", arguments: arguments, ignoreFailure: ignoreFailure)
        }

        if arguments.count == 3,
           arguments[0] == "-d",
           arguments[1] == "com.apple.quarantine",
           isSafeStockAppPath(arguments[2]) {
            return .process(executable: "/usr/bin/xattr", arguments: arguments, ignoreFailure: ignoreFailure)
        }

        return nil
    }

    private static func parseAdobeARMHelperCommand(_ command: String) -> DebloatCommand? {
        guard command.contains("com.adobe.ARMDCHelper"),
              command.contains("|"),
              command.contains("launchctl print-disabled gui/\(getuid())") else {
            return nil
        }

        if command.contains("launchctl disable gui/\(getuid())/$label") {
            return .adobeARMHelper(disable: true)
        }
        if command.contains("launchctl enable gui/\(getuid())/$label") {
            return .adobeARMHelper(disable: false)
        }
        return nil
    }

    private static func isWidgetKillPipeline(_ command: String) -> Bool {
        command.contains("ps -Axo pid=,command=")
            && command.contains("appex")
            && command.contains("Contents")
            && command.contains("/usr/bin/xargs -n1 /bin/kill -9")
    }

    private static func stripIgnoredFailureSuffix(from command: String) -> (command: String, ignoreFailure: Bool) {
        var current = command
        var ignoreFailure = false

        for suffix in [" 2>/dev/null || true", " || true", " 2>/dev/null"] where current.hasSuffix(suffix) {
            current.removeLast(suffix.count)
            current = current.trimmingCharacters(in: .whitespacesAndNewlines)
            ignoreFailure = true
        }

        return (current, ignoreFailure)
    }

    private static func tokenize(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for character in command {
            if let quoteCharacter = quote {
                if character == quoteCharacter {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            if "|&;`$<>".contains(character) {
                return nil
            }

            current.append(character)
        }

        guard quote == nil else { return nil }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func killWidgetExtensionProcesses() {
        let result = CommandRunner.run("/bin/ps", arguments: ["-Axo", "pid=,command="])
        guard let output = result.succeeded ? Optional(result.stdout) : nil else { return }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let pid = Int32(parts[0]) else {
                continue
            }
            let command = parts[1].lowercased()
            guard command.contains(".appex/contents/macos/"), command.contains("widget") else { continue }
            _ = CommandRunner.run("/bin/kill", arguments: ["-9", String(pid)])
        }
    }

    private static func updateAdobeARMHelperLabels(disable: Bool) {
        let uid = getuid()
        let result = CommandRunner.run("/bin/launchctl", arguments: ["print-disabled", "gui/\(uid)"])
        guard result.succeeded else { return }

        for line in result.stdout.components(separatedBy: .newlines) {
            guard let label = adobeARMHelperLabel(from: line), isSafeLaunchdLabel(label) else { continue }
            let action = disable ? "disable" : "enable"
            _ = CommandRunner.run("/bin/launchctl", arguments: [action, "gui/\(uid)/\(label)"])
        }
    }

    private static func adobeARMHelperLabel(from line: String) -> String? {
        guard let start = line.range(of: "\"com.adobe.ARMDCHelper")?.lowerBound else { return nil }
        let remainder = line[start...].dropFirst()
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        let label = String(remainder[..<end])
        return label.hasPrefix("com.adobe.ARMDCHelper") ? label : nil
    }

    private static func executableName(_ executable: String) -> String {
        URL(fileURLWithPath: executable).lastPathComponent
    }

    private static func isSafeDefaultsDomain(_ value: String) -> Bool {
        value == "NSGlobalDomain" || isSafeBundleIdentifier(value)
    }

    private static func isSafeDefaultsKey(_ value: String) -> Bool {
        isSafeText(value, maxLength: 160, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-")))
    }

    private static func isSafeDefaultsStringValue(_ value: String) -> Bool {
        isSafeText(value, maxLength: 160, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-")))
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        isSafeText(value, maxLength: 256, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")))
    }

    private static func isSafeLaunchctlDomainTarget(_ value: String) -> Bool {
        let parts = value.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "system" {
            return isSafeLaunchdLabel(parts[1])
        }
        guard parts.count == 3, parts[0] == "gui", UInt32(parts[1]) == getuid() else { return false }
        return isSafeLaunchdLabel(parts[2])
    }

    private static func isSafeLaunchdLabel(_ value: String) -> Bool {
        isSafeText(value, maxLength: 256, allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")))
    }

    private static func isSafeLaunchctlPlistPath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        return standardized == value
            && value.hasSuffix(".plist")
            && (value.hasPrefix("/System/Library/LaunchDaemons/") || value.hasPrefix("/Library/LaunchDaemons/"))
            && !containsControlCharacters(value)
    }

    private static func isWidgetMarkerPath(_ value: String) -> Bool {
        URL(fileURLWithPath: value).standardizedFileURL.path == URL(fileURLWithPath: DebloatManager.widgetMarkerPath).standardizedFileURL.path
    }

    private static func isSafeStockAppPath(_ value: String) -> Bool {
        let standardized = URL(fileURLWithPath: value).standardizedFileURL.path
        return standardized == value
            && value.hasSuffix(".app")
            && (value.hasPrefix("/System/Applications/") || value.hasPrefix("/Applications/"))
            && !containsControlCharacters(value)
    }

    private static func isSafeText(_ value: String, maxLength: Int, allowedCharacters: CharacterSet) -> Bool {
        guard !value.isEmpty, value.count <= maxLength, !containsControlCharacters(value) else { return false }
        return value.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0 || CharacterSet.newlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
