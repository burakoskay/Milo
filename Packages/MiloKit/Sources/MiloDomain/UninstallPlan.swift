import Foundation

public enum MiloUninstallItemKind: String, Sendable, Hashable {
    case directory
    case file
}

/// One filesystem artifact Milo created and is therefore entitled to remove.
public struct MiloUninstallItem: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: MiloUninstallItemKind
    public let title: String
    public let detail: String
    /// Left behind by a build published under the retired `monomacaw` identifiers.
    public let isLegacy: Bool
    /// The `UserDefaults` suite backing this file, when the artifact is a preferences plist.
    /// Removing the file alone is not sufficient while `cfprefsd` holds the domain in memory.
    public let preferencesDomain: String?

    public init(
        path: String,
        kind: MiloUninstallItemKind,
        title: String,
        detail: String,
        isLegacy: Bool,
        preferencesDomain: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isLegacy = isLegacy
        self.preferencesDomain = preferencesDomain
    }
}

/// The complete, closed set of artifacts an uninstall may delete.
///
/// Deleting files on a user's behalf is the least reversible thing Milo does, so the plan is
/// an *exact-path allowlist* generated from an explicit identifier table — never a pattern
/// match. This is not academic: the machine this was written on carries
/// `com.monomacaw.picoberry.prototype` and `com.monomacaw.squeaky.preview` preferences from
/// unrelated products by the same developer. A "delete anything containing the old vendor
/// name" rule would have destroyed both.
///
/// `isRemovable(_:homeDirectory:)` re-derives the same set and is checked immediately before
/// every deletion, so a path that did not come from this table cannot be removed even if a
/// caller constructs one by hand.
public enum MiloUninstallPlan {
    /// Bundle identifiers shipped under the current brand.
    public static let currentIdentifiers: [String] = [
        "com.gonggong.milo",
        "com.gonggong.milo.preview",
        "com.gonggong.milo.lite",
        "com.gonggong.milo.SelfTest"
    ]

    /// Identifiers retired by the 2026-08-04 rename. Still present on machines that ran a
    /// pre-rename build; see `docs/decisions/0001-rename-monomacaw-to-gonggong.md`.
    public static let legacyIdentifiers: [String] = [
        "com.monomacaw.milo",
        "com.monomacaw.milo.preview",
        "com.monomacaw.milo.lite",
        "com.monomacaw.milo.SelfTest"
    ]

    /// A defaults domain written by early builds under a bare product name rather than a
    /// bundle identifier. Observed live at `~/Library/Preferences/Milo.plist`.
    public static let bareProductDomain = "Milo"

    /// The `SMAppService` daemon Milo registers and is able to unregister.
    public static let helperServiceIdentifier = "com.gonggong.milo.helper"

    /// Helper registrations from pre-rename builds. Milo cannot unregister these — an app may
    /// only unregister its own `SMAppService` records — so they are detected and reported
    /// with recovery steps rather than removed.
    public static let legacyHelperServiceIdentifiers: [String] = [
        "com.monomacaw.milo.helper"
    ]

    /// Directories under `~/Library` that hold one entry per bundle identifier.
    private static let identifierKeyedDirectories: [(subpath: String, suffix: String, kind: MiloUninstallItemKind, detail: String)] = [
        ("Library/Caches", "", .directory, "Cached data"),
        ("Library/HTTPStorages", "", .directory, "Network cache and cookies"),
        ("Library/Containers", "", .directory, "Sandbox container"),
        ("Library/Saved Application State", ".savedState", .directory, "Restored window state")
    ]

    /// Builds the removable set for a home directory.
    ///
    /// Returns an empty plan for any home directory that is not a plausible user home, so a
    /// caller that passes `/` or an empty string deletes nothing rather than something
    /// catastrophic.
    public static func items(homeDirectory: String, includingLegacy: Bool = true) -> [MiloUninstallItem] {
        guard let home = validatedHome(homeDirectory) else {
            return []
        }

        var items: [MiloUninstallItem] = [
            MiloUninstallItem(
                path: home + "/Library/Application Support/Milo",
                kind: .directory,
                title: "Application Support",
                detail: "Protected-process list, statistics, and local state",
                isLegacy: false
            ),
            MiloUninstallItem(
                path: home + "/Library/Preferences/\(bareProductDomain).plist",
                kind: .file,
                title: "Preferences",
                detail: "Settings written under the bare product name",
                isLegacy: false,
                preferencesDomain: bareProductDomain
            ),
            MiloUninstallItem(
                path: home + "/Library/Logs/Milo",
                kind: .directory,
                title: "Logs",
                detail: "Local diagnostic logs",
                isLegacy: false
            )
        ]

        let identifiers = includingLegacy
            ? currentIdentifiers.map { ($0, false) } + legacyIdentifiers.map { ($0, true) }
            : currentIdentifiers.map { ($0, false) }

        for (identifier, isLegacy) in identifiers {
            items.append(
                MiloUninstallItem(
                    path: home + "/Library/Preferences/\(identifier).plist",
                    kind: .file,
                    title: "Preferences",
                    detail: identifier,
                    isLegacy: isLegacy,
                    preferencesDomain: identifier
                )
            )

            for directory in identifierKeyedDirectories {
                items.append(
                    MiloUninstallItem(
                        path: home + "/\(directory.subpath)/\(identifier)\(directory.suffix)",
                        kind: directory.kind,
                        title: directory.detail,
                        detail: identifier,
                        isLegacy: isLegacy
                    )
                )
            }
        }

        return items
    }

    /// The containment gate. A path is removable only when it is a member of the generated
    /// plan for this home directory — exact string equality after standardization.
    public static func isRemovable(_ path: String, homeDirectory: String) -> Bool {
        guard let home = validatedHome(homeDirectory) else {
            return false
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else {
            return false
        }
        return items(homeDirectory: home, includingLegacy: true).contains { $0.path == standardized }
    }

    /// A home directory Milo is willing to write inside.
    ///
    /// Rejects the root, single-component paths such as `/Users`, relative paths, and
    /// anything that does not survive standardization unchanged. Without this, a caller that
    /// resolved the home directory to `/` would generate `/Library/Preferences/...` — real
    /// system paths.
    private static func validatedHome(_ homeDirectory: String) -> String? {
        guard homeDirectory.hasPrefix("/"), !homeDirectory.hasSuffix("/") else {
            return nil
        }
        let standardized = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        guard standardized == homeDirectory else {
            return nil
        }
        // "/Users/name" is two components once the leading empty component is dropped.
        let components = standardized.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            return nil
        }
        guard !standardized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return standardized
    }
}
