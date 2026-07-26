import Foundation
import XCTest

final class BuildConfigurationRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testShippingTargetsUseExplicitPerConfigurationFiles() throws {
        let project = try source(at: repositoryRoot.appendingPathComponent("project.yml"))
        let mappings = [
            "Debug: Configurations/MiloPro.Debug.xcconfig",
            "Release: Configurations/MiloPro.Release.xcconfig",
            "Debug: Configurations/MiloLite.Debug.xcconfig",
            "Release: Configurations/MiloLite.Release.xcconfig",
            "Debug: Configurations/MiloPrivilegedHelper.Debug.xcconfig",
            "Release: Configurations/MiloPrivilegedHelper.Release.xcconfig"
        ]
        for mapping in mappings {
            XCTAssertTrue(project.contains(mapping), "Missing configuration mapping: \(mapping)")
        }
        XCTAssertFalse(project.contains("DEVELOPMENT_TEAM: 8N738727QB"))
        XCTAssertEqual(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER: $(MILO_BUNDLE_ID)").count - 1, 3)
    }

    func testTrackedConfigurationSeparatesProductsAndEnvironments() throws {
        let expectedValues: [(path: String, flavor: String, bundleID: String, environment: String)] = [
            ("MiloPro.Debug.xcconfig", "pro", "com.monomacaw.milo", "development"),
            ("MiloPro.Release.xcconfig", "pro", "com.monomacaw.milo", "production"),
            ("MiloLite.Debug.xcconfig", "lite", "com.monomacaw.milo.lite", "development"),
            ("MiloLite.Release.xcconfig", "lite", "com.monomacaw.milo.lite", "production"),
            (
                "MiloPrivilegedHelper.Debug.xcconfig",
                "privileged-helper",
                "com.monomacaw.milo.helper",
                "development"
            ),
            (
                "MiloPrivilegedHelper.Release.xcconfig",
                "privileged-helper",
                "com.monomacaw.milo.helper",
                "production"
            )
        ]
        let configurationDirectory = repositoryRoot.appendingPathComponent("Configurations")
        for expected in expectedValues {
            let configuration = try source(at: configurationDirectory.appendingPathComponent(expected.path))
            XCTAssertTrue(configuration.contains("MILO_PRODUCT_FLAVOR = \(expected.flavor)"))
            XCTAssertTrue(configuration.contains("MILO_BUNDLE_ID = \(expected.bundleID)"))
            XCTAssertTrue(configuration.contains("MILO_CONFIGURATION_ENVIRONMENT = \(expected.environment)"))
            XCTAssertTrue(configuration.contains("#include \"Shared.xcconfig\""))
        }

        let proDebug = try source(at: configurationDirectory.appendingPathComponent("MiloPro.Debug.xcconfig"))
        XCTAssertTrue(proDebug.contains("https:/$()/milo-development.invalid"))
        XCTAssertFalse(proDebug.contains("https:/$()/monomacaw.com"))

        let proRelease = try source(at: configurationDirectory.appendingPathComponent("MiloPro.Release.xcconfig"))
        XCTAssertTrue(proRelease.contains("https:/$()/monomacaw.com"))
        XCTAssertTrue(proRelease.contains("MILO_LICENSE_PUBLIC_KEY =\n"))
        XCTAssertTrue(proRelease.contains("SPARKLE_PUBLIC_ED_KEY =\n"))
    }

    func testTrackedConfigurationContainsNoClientSecretSurface() throws {
        let paths = [
            repositoryRoot.appendingPathComponent("Configurations"),
            repositoryRoot.appendingPathComponent("Tools/generate-build-configuration.sh"),
            repositoryRoot.appendingPathComponent("App/Milo/Info.plist")
        ]
        let sourceText = try paths.map { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw BuildConfigurationTestError.missingPath(url.path)
            }
            return isDirectory.boolValue ? try sourceTree(at: url) : try source(at: url)
        }.joined(separator: "\n")
        let forbiddenMarkers = [
            "SUPABASE_" + "SERVICE_ROLE_KEY",
            "PADDLE_" + "API_KEY",
            "PADDLE_" + "WEBHOOK_SECRET",
            "LICENSE_SIGNING_" + "PRIVATE_KEY",
            "SPARKLE_" + "PRIVATE_KEY",
            "MiloSupabase" + "AnonKey",
            "MiloPaddle" + "ClientToken"
        ]
        for marker in forbiddenMarkers {
            XCTAssertFalse(sourceText.contains(marker), "Forbidden client configuration marker: \(marker)")
        }
    }

    func testGeneratorFailsClosedAndRedactsDiagnostics() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("milo-configuration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: outputDirectory)
            } catch {
                XCTFail("Failed to remove temporary configuration test directory: \(error.localizedDescription)")
            }
        }

        let developmentOutput = outputDirectory.appendingPathComponent("Development.xcconfig")
        let development = try runGenerator(
            output: developmentOutput,
            environment: ["MILO_CONFIGURATION_ENVIRONMENT": "development"]
        )
        XCTAssertEqual(development.status, 0)
        let generated = try source(at: developmentOutput)
        XCTAssertTrue(generated.contains("MILO_CONFIGURATION_ENVIRONMENT = development"))
        XCTAssertTrue(generated.contains("MILO_SERVICE_BASE_URL = https:/$()/milo-development.invalid"))
        XCTAssertEqual(try permissions(of: developmentOutput) & 0o777, 0o600)

        let productionOutput = outputDirectory.appendingPathComponent("Production.xcconfig")
        let production = try runGenerator(
            output: productionOutput,
            environment: [
                "MILO_CONFIGURATION_ENVIRONMENT": "production",
                "MILO_SERVICE_BASE_URL": "https://monomacaw.com"
            ]
        )
        XCTAssertEqual(production.status, 78)
        XCTAssertFalse(FileManager.default.fileExists(atPath: productionOutput.path))
        XCTAssertFalse(production.output.contains("MILO_LICENSE_PUBLIC_KEY="))
        XCTAssertFalse(production.output.contains("SPARKLE_PUBLIC_ED_KEY="))

        let invalidOrigin = try runGenerator(
            output: outputDirectory.appendingPathComponent("InvalidOrigin.xcconfig"),
            environment: [
                "MILO_CONFIGURATION_ENVIRONMENT": "development",
                "MILO_SERVICE_BASE_URL": "https://bad..invalid"
            ]
        )
        XCTAssertEqual(invalidOrigin.status, 78)
    }

    func testPackagingConsumesCanonicalXcodeAndValidatedConfiguration() throws {
        let packaging = try source(at: repositoryRoot.appendingPathComponent("build_app.sh"))
        XCTAssertTrue(packaging.contains("Tools/generate-build-configuration.sh"))
        XCTAssertTrue(packaging.contains("-workspace Milo.xcworkspace"))
        XCTAssertTrue(packaging.contains("-scheme MiloPro"))
        XCTAssertTrue(packaging.contains("MiloPrivilegedHelper"))
        XCTAssertFalse(packaging.contains("swift build"))
        XCTAssertFalse(packaging.contains("plutil -replace MiloServiceBaseURL"))
        XCTAssertFalse(packaging.contains("plutil -replace MiloLicensePublicKey"))
        XCTAssertFalse(packaging.contains("plutil -replace SUPublicEDKey"))

        let verifier = try source(at: repositoryRoot.appendingPathComponent("Tools/verify-build.sh"))
        XCTAssertTrue(verifier.contains("MiloConfigurationEnvironment"))
        XCTAssertTrue(verifier.contains("MiloServiceBaseURL"))
        XCTAssertTrue(verifier.contains("MiloLicensePublicKey"))

        let ignoreRules = try source(at: repositoryRoot.appendingPathComponent(".gitignore"))
        XCTAssertTrue(ignoreRules.contains("*.generated.xcconfig"))
    }

    private func runGenerator(
        output: URL,
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent("Tools/generate-build-configuration.sh").path,
            output.path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputText = String(data: data, encoding: .utf8) else {
            throw BuildConfigurationTestError.invalidUTF8
        }
        return (process.terminationStatus, outputText)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw BuildConfigurationTestError.missingPermissions(url.path)
        }
        return permissions.intValue
    }

    private func sourceTree(at directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw BuildConfigurationTestError.cannotEnumerate(directory.path)
        }
        var result = ""
        for case let url as URL in enumerator where url.pathExtension == "xcconfig" || url.pathExtension == "md" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result += try source(at: url)
            }
        }
        return result
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

private enum BuildConfigurationTestError: LocalizedError {
    case cannotEnumerate(String)
    case invalidUTF8
    case missingPath(String)
    case missingPermissions(String)
}
