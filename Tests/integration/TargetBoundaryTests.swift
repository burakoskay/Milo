import Foundation
import XCTest

final class TargetBoundaryTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLiteTargetHasNoProDependenciesOrNetworkEntitlement() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))
        let liteSection = try section(
            named: "MiloLite",
            before: "MiloPrivilegedHelper",
            in: projectSpec
        )

        XCTAssertTrue(liteSection.contains("ENABLE_APP_SANDBOX: YES"))
        XCTAssertTrue(liteSection.contains("PRODUCT_BUNDLE_IDENTIFIER: com.monomacaw.milo.lite"))
        XCTAssertFalse(liteSection.contains("MiloLicense"))
        XCTAssertFalse(liteSection.contains("MiloSparkle"))
        XCTAssertFalse(liteSection.contains("MiloPrivilegedHelper"))

        let entitlements = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent("App/MiloLite/MiloLite.entitlements")
        )
        XCTAssertEqual(entitlements.keys.sorted(), ["com.apple.security.app-sandbox"])
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
    }

    func testHelperBundleLayoutAndDenyAllEntryPointAreFrozen() throws {
        let helperPlist = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent(
                "Helper/MiloPrivilegedHelper/com.monomacaw.milo.helper.plist"
            )
        )

        XCTAssertEqual(helperPlist["Label"] as? String, "com.monomacaw.milo.helper")
        XCTAssertEqual(
            helperPlist["BundleProgram"] as? String,
            "Contents/Resources/MiloPrivilegedHelper"
        )
        guard let machServices = helperPlist["MachServices"] as? [String: Any] else {
            XCTFail("MachServices must be a dictionary")
            return
        }
        XCTAssertEqual(machServices["com.monomacaw.milo.helper"] as? Bool, true)
        XCTAssertNil(helperPlist["Program"])
        XCTAssertNil(helperPlist["ProgramArguments"])
        XCTAssertNil(helperPlist["RunAtLoad"])

        let helperSource = try readText(
            at: repositoryRoot.appendingPathComponent("Helper/MiloPrivilegedHelper/main.swift")
        )
        XCTAssertTrue(helperSource.contains("DenyAllConnectionDelegate"))
        XCTAssertFalse(helperSource.contains("Process("))
        XCTAssertFalse(helperSource.contains("/bin/"))
        XCTAssertFalse(helperSource.contains("/usr/bin/"))
    }

    func testProSchemeLaunchesAppAndEmbedsHelperOnlyAsDependency() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))
        let proTargetSection = try section(named: "MiloPro", before: "MiloLite", in: projectSpec)

        XCTAssertTrue(proTargetSection.contains("target: MiloPrivilegedHelper"))
        XCTAssertTrue(proTargetSection.contains("destination: resources"))
        XCTAssertTrue(proTargetSection.contains("Contents/Library/LaunchDaemons"))

        let scheme = try readText(
            at: repositoryRoot.appendingPathComponent(
                "Milo.xcodeproj/xcshareddata/xcschemes/MiloPro.xcscheme"
            )
        )
        let launchAction = try contents(between: "<LaunchAction", and: "</LaunchAction>", in: scheme)
        let profileAction = try contents(between: "<ProfileAction", and: "</ProfileAction>", in: scheme)

        XCTAssertTrue(launchAction.contains("BuildableName = \"Milo.app\""))
        XCTAssertTrue(launchAction.contains("BlueprintName = \"MiloPro\""))
        XCTAssertFalse(launchAction.contains("MiloPrivilegedHelper"))
        XCTAssertTrue(profileAction.contains("BuildableName = \"Milo.app\""))
        XCTAssertFalse(profileAction.contains("MiloPrivilegedHelper"))
    }

    func testReleaseConfigurationRejectsCompilerWarningsAndDebugEntitlementInjection() throws {
        let projectSpec = try readText(at: repositoryRoot.appendingPathComponent("project.yml"))

        XCTAssertTrue(projectSpec.contains("GCC_TREAT_WARNINGS_AS_ERRORS: YES"))
        let releaseSection = try contents(
            between: "    Release:\n",
            and: "\ntargets:\n",
            in: projectSpec
        )
        XCTAssertTrue(releaseSection.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO"))
        XCTAssertTrue(releaseSection.contains("VALIDATE_PRODUCT: YES"))
    }

    func testLitePrivacyManifestDeclaresNoCollectionOrTracking() throws {
        let manifest = try readPropertyListDictionary(
            at: repositoryRoot.appendingPathComponent("App/MiloLite/PrivacyInfo.xcprivacy")
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertTrue((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        XCTAssertTrue((manifest["NSPrivacyAccessedAPITypes"] as? [Any])?.isEmpty == true)
    }

    private func readText(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func readPropertyListDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw TargetBoundaryTestError.expectedDictionary(url.path)
        }
        return dictionary
    }

    private func section(named name: String, before nextName: String, in source: String) throws -> String {
        let startMarker = "\n  \(name):\n"
        let endMarker = "\n  \(nextName):\n"
        guard let startRange = source.range(of: startMarker) else {
            throw TargetBoundaryTestError.missingSection(name)
        }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: endMarker) else {
            throw TargetBoundaryTestError.missingSection(nextName)
        }
        return String(remainder[..<endRange.lowerBound])
    }

    private func contents(between startMarker: String, and endMarker: String, in source: String) throws -> String {
        guard let startRange = source.range(of: startMarker) else {
            throw TargetBoundaryTestError.missingMarker(startMarker)
        }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: endMarker) else {
            throw TargetBoundaryTestError.missingMarker(endMarker)
        }
        return String(remainder[..<endRange.lowerBound])
    }
}

private enum TargetBoundaryTestError: LocalizedError {
    case expectedDictionary(String)
    case missingMarker(String)
    case missingSection(String)

    var errorDescription: String? {
        switch self {
        case .expectedDictionary(let path):
            return "Expected a property-list dictionary at \(path)"
        case .missingMarker(let marker):
            return "Missing marker \(marker)"
        case .missingSection(let name):
            return "Missing project section \(name)"
        }
    }
}
