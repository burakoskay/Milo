import Foundation
import MiloDomain
import Testing

@Suite("Uninstall plan containment")
struct UninstallPlanTests {
    private let home = "/Users/tester"

    private var paths: Set<String> {
        Set(MiloUninstallPlan.items(homeDirectory: home).map(\.path))
    }

    @Test("the plan covers the artifacts Milo actually writes")
    func planCoversKnownArtifacts() {
        let expected = [
            "/Users/tester/Library/Application Support/Milo",
            "/Users/tester/Library/Preferences/Milo.plist",
            "/Users/tester/Library/Preferences/com.gonggong.milo.plist",
            "/Users/tester/Library/Preferences/com.gonggong.milo.preview.plist",
            "/Users/tester/Library/Caches/com.gonggong.milo",
            "/Users/tester/Library/Saved Application State/com.gonggong.milo.savedState",
            "/Users/tester/Library/Containers/com.gonggong.milo.lite"
        ]
        for path in expected {
            #expect(paths.contains(path), "missing \(path)")
        }
    }

    @Test("retired monomacaw identifiers are covered and flagged as legacy")
    func legacyArtifactsAreCovered() {
        let legacy = MiloUninstallPlan.items(homeDirectory: home).filter(\.isLegacy)
        #expect(!legacy.isEmpty)
        #expect(legacy.allSatisfy { $0.path.contains("com.monomacaw.milo") })
        #expect(paths.contains("/Users/tester/Library/HTTPStorages/com.monomacaw.milo"))
        #expect(paths.contains("/Users/tester/Library/Preferences/com.monomacaw.milo.preview.plist"))
    }

    @Test("legacy artifacts can be excluded")
    func legacyCanBeExcluded() {
        let currentOnly = MiloUninstallPlan.items(homeDirectory: home, includingLegacy: false)
        #expect(currentOnly.allSatisfy { !$0.isLegacy })
        #expect(!currentOnly.contains { $0.path.contains("monomacaw") })
    }

    @Test("unrelated products by the same developer are never in the plan")
    func unrelatedProductsAreUntouched() {
        // Both of these exist alongside Milo on the developer's own machine. A rule that
        // matched the vendor name rather than an explicit identifier table would delete them.
        let bystanders = [
            "/Users/tester/Library/Preferences/com.monomacaw.picoberry.prototype.plist",
            "/Users/tester/Library/Containers/com.monomacaw.squeaky.preview",
            "/Users/tester/Library/Containers/tech.gonggong.squeaky.preview",
            "/Users/tester/Library/Preferences/com.gonggong.other.plist"
        ]
        for path in bystanders {
            #expect(!paths.contains(path), "plan must not contain \(path)")
            #expect(!MiloUninstallPlan.isRemovable(path, homeDirectory: home))
        }
    }

    @Test("every plan entry lives under the user's Library")
    func everyEntryIsContained() {
        #expect(!paths.isEmpty)
        for path in paths {
            #expect(path.hasPrefix("/Users/tester/Library/"))
        }
    }

    @Test("removability is exact-set membership, not prefix matching")
    func removabilityIsExact() {
        #expect(MiloUninstallPlan.isRemovable("/Users/tester/Library/Application Support/Milo", homeDirectory: home))
        // A child of a plan entry is not itself a plan entry; the directory is removed whole.
        #expect(!MiloUninstallPlan.isRemovable("/Users/tester/Library/Application Support/Milo/whitelist.json", homeDirectory: home))
        #expect(!MiloUninstallPlan.isRemovable("/Users/tester/Library/Application Support", homeDirectory: home))
        #expect(!MiloUninstallPlan.isRemovable("/Users/tester/Library", homeDirectory: home))
        #expect(!MiloUninstallPlan.isRemovable("/Users/tester", homeDirectory: home))
    }

    @Test("traversal and relative paths are refused")
    func traversalIsRefused() {
        let attacks = [
            "/Users/tester/Library/Application Support/Milo/../../../../../System",
            "/Users/tester/Library/Preferences/../../../etc/passwd",
            "Library/Application Support/Milo",
            "",
            "/",
            "/System/Library/CoreServices"
        ]
        for path in attacks {
            #expect(!MiloUninstallPlan.isRemovable(path, homeDirectory: home), "must refuse \(path)")
        }
    }

    @Test("an implausible home directory produces an empty plan")
    func implausibleHomeProducesEmptyPlan() {
        // The failure this prevents: a home directory that resolved to the root would
        // generate real system paths such as /Library/Preferences/com.gonggong.milo.plist.
        for badHome in ["", "/", "/Users", "relative/path", "/Users/tester/", "/Users/../etc"] {
            #expect(
                MiloUninstallPlan.items(homeDirectory: badHome).isEmpty,
                "\(badHome) must not generate a plan"
            )
            #expect(!MiloUninstallPlan.isRemovable("/Library/Preferences/com.gonggong.milo.plist", homeDirectory: badHome))
        }
    }

    @Test("preferences entries carry the defaults domain that backs them")
    func preferencesCarryDomains() {
        let preferences = MiloUninstallPlan.items(homeDirectory: home).filter { $0.preferencesDomain != nil }
        #expect(!preferences.isEmpty)
        for item in preferences {
            #expect(item.kind == .file)
            #expect(item.path.hasSuffix(".plist"))
            // Deleting the file without clearing the domain lets cfprefsd write it back.
            let domain = item.preferencesDomain ?? ""
            #expect(item.path.hasSuffix("/\(domain).plist"))
        }
    }

    @Test("plan entries are unique")
    func planEntriesAreUnique() {
        let all = MiloUninstallPlan.items(homeDirectory: home)
        #expect(all.count == Set(all.map(\.path)).count)
    }

    @Test("the retired helper identifier is recorded for detection, not deletion")
    func legacyHelperIsDetectionOnly() {
        // An app may only unregister its own SMAppService records, so a pre-rename helper
        // can be reported but never removed programmatically.
        #expect(MiloUninstallPlan.legacyHelperServiceIdentifiers.contains("com.monomacaw.milo.helper"))
        #expect(MiloUninstallPlan.helperServiceIdentifier == "com.gonggong.milo.helper")
        #expect(!paths.contains { $0.contains("helper") })
    }
}
