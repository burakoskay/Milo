import Foundation
import XCTest

final class LegacyDesktopAuthRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProRuntimeContainsNoBrowserSessionOrEmbeddedCheckoutPath() throws {
        let runtimeDirectory = repositoryRoot.appendingPathComponent("App/Milo/Runtime")
        let runtimeSource = try sourceText(in: runtimeDirectory)
        let forbidden = [
            "Bearer" + " ",
            "access_" + "token",
            "Milo" + "Supabase" + "AnonKey",
            "Milo" + "Paddle",
            "Paddle." + "Initialize",
            "WK" + "WebView",
            "Authentication" + "Services",
            "Checkout" + "Manager",
            "localDevelopment" + "UnlockEnabled",
            "verifyLicenseAndFetch" + "Signatures",
            "#if DEBUG || AD_" + "HOC"
        ]

        for marker in forbidden {
            XCTAssertFalse(runtimeSource.contains(marker), "Pro runtime contains forbidden legacy marker: \(marker)")
        }

        let licenseManager = try String(
            contentsOf: runtimeDirectory.appendingPathComponent("LicenseManager.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(licenseManager.contains("MLPDeviceLicenseClient"))
        XCTAssertTrue(licenseManager.contains("startEnrollment"))
        XCTAssertTrue(licenseManager.contains("completeEnrollment"))

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let rootPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("Runtime/Secrets.swift"))
        XCTAssertTrue(rootPackage.contains("sources: ["))
        XCTAssertTrue(rootPackage.contains("ignoredCompatibilityFile"))
    }

    func testProBundleHasOnlyPublicMLPClientConfiguration() throws {
        let info = try propertyList(
            at: repositoryRoot.appendingPathComponent("App/Milo/Info.plist")
        )
        XCTAssertEqual(info["MiloConfigurationEnvironment"] as? String, "$(MILO_CONFIGURATION_ENVIRONMENT)")
        XCTAssertEqual(info["MiloServiceBaseURL"] as? String, "$(MILO_SERVICE_BASE_URL)")
        XCTAssertEqual(info["MiloLicensePublicKey"] as? String, "$(MILO_LICENSE_PUBLIC_KEY)")
        XCTAssertNil(info["CFBundleURLTypes"])

        let forbiddenKeys = [
            "Milo" + "Supabase" + "AnonKey",
            "Milo" + "Supabase" + "URL",
            "Milo" + "Paddle" + "ClientToken",
            "Milo" + "Paddle" + "Environment",
            "Milo" + "Paddle" + "PriceID"
        ]
        for key in forbiddenKeys {
            XCTAssertNil(info[key], "Pro Info.plist contains forbidden legacy key: \(key)")
        }
    }

    func testProEntitlementsAndDependenciesExcludeDesktopWebAuthentication() throws {
        let entitlements = try propertyList(
            at: repositoryRoot.appendingPathComponent("App/Milo/Milo.entitlements")
        )
        XCTAssertNil(entitlements["com.apple.developer.apple" + "signin"])

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let rootPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let forbiddenDependencies = [
            "Authentication" + "Services.framework",
            "Web" + "Kit.framework"
        ]
        for dependency in forbiddenDependencies {
            XCTAssertFalse(project.contains(dependency))
            XCTAssertFalse(rootPackage.contains(dependency))
        }
    }

    func testPlaceholderPackageProductsAndSourcesAreRemoved() throws {
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/MiloKit/Package.swift"),
            encoding: .utf8
        )
        let removedTargets = [
            "MiloProcess" + "Engine",
            "Milo" + "Signatures",
            "Milo" + "Permissions",
            "Milo" + "Paywall",
            "Milo" + "Settings",
            "Milo" + "Stats",
            "Milo" + "Debloat",
            "Milo" + "Whitelist",
            "Milo" + "UI",
            "MiloTest" + "Support"
        ]
        for target in removedTargets {
            XCTAssertFalse(package.contains(target), "Placeholder target remains in package manifest: \(target)")
            let directory = repositoryRoot.appendingPathComponent("Packages/MiloKit/Sources/\(target)")
            let swiftFiles: [URL]
            if FileManager.default.fileExists(atPath: directory.path) {
                swiftFiles = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "swift" }
            } else {
                swiftFiles = []
            }
            XCTAssertTrue(swiftFiles.isEmpty, "Placeholder Swift sources remain for \(target)")
        }
    }

    private func sourceText(in directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw LegacyDesktopAuthTestError.cannotEnumerate(directory.path)
        }

        var source = ""
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension == "swift" && fileURL.lastPathComponent != "Secrets.swift" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            source += try String(contentsOf: fileURL, encoding: .utf8)
        }
        return source
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw LegacyDesktopAuthTestError.expectedDictionary(url.path)
        }
        return dictionary
    }
}

private enum LegacyDesktopAuthTestError: LocalizedError {
    case cannotEnumerate(String)
    case expectedDictionary(String)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerate(let path):
            return "Could not enumerate Swift source files at \(path)."
        case .expectedDictionary(let path):
            return "Expected a property-list dictionary at \(path)."
        }
    }
}
