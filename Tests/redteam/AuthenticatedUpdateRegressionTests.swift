import Foundation
import XCTest

final class AuthenticatedUpdateRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProSparkleSecuritySettingsFailClosed() throws {
        let info = try propertyList(at: repositoryRoot.appendingPathComponent("App/Milo/Info.plist"))

        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUSignedFeedFailureExpirationInterval"] as? Int, 0)
        XCTAssertEqual(info["SUShowReleaseNotes"] as? Bool, false)
        XCTAssertNil(info["SUFeedURL"])
        XCTAssertNil(info["SUEnableDownloaderService"])
        XCTAssertNil(info["SUEnableInstallerLauncherService"])

        let transportSecurity = try XCTUnwrap(info["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(transportSecurity["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(transportSecurity["NSAllowsArbitraryLoads"])
        XCTAssertNil(transportSecurity["NSAllowsArbitraryLoadsInWebContent"])
    }

    func testMLPDescriptorAndExactByteBridgeAreTheOnlyUpdatePath() throws {
        let updateSource = try sourceText(
            in: repositoryRoot.appendingPathComponent("Packages/MiloKit/Sources/MiloUpdates")
        )
        let sparkleSource = try sourceText(
            in: repositoryRoot.appendingPathComponent("Packages/MiloKit/Sources/MiloSparkle")
        )
        let combinedSource = updateSource + sparkleSource

        XCTAssertTrue(updateSource.contains("MiloAppcastVerifier"))
        XCTAssertTrue(updateSource.contains("MiloRedirectRejectingDelegate"))
        XCTAssertTrue(updateSource.contains("MiloLoopbackAppcastServer"))
        XCTAssertTrue(sparkleSource.contains("MLPUpdateFeed"))
        XCTAssertTrue(sparkleSource.contains("shouldProceedWithUpdate"))
        XCTAssertTrue(sparkleSource.contains("clearFeedURLFromUserDefaults"))

        let forbiddenMarkers = [
            "AuthenticatedUpdateFeed" + "State",
            "license_" + "id",
            "device_" + "hash",
            "set" + "FeedURL(",
            ".http" + "Headers ="
        ]
        for marker in forbiddenMarkers {
            XCTAssertFalse(combinedSource.contains(marker), "Obsolete updater marker remains: \(marker)")
        }
    }

    func testSparkleDependencyIsExactAndProOnly() throws {
        let package = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/MiloKit/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(package.contains("exact: \"2.9.4\""))
        XCTAssertFalse(package.contains("from: \"2.9.4\""))

        let resolvedData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/MiloKit/Package.resolved")
        )
        let resolved = try JSONSerialization.jsonObject(with: resolvedData)
        let root = try XCTUnwrap(resolved as? [String: Any])
        let pins = try XCTUnwrap(root["pins"] as? [[String: Any]])
        let sparklePin = try XCTUnwrap(pins.first { $0["identity"] as? String == "sparkle" })
        let state = try XCTUnwrap(sparklePin["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, "2.9.4")
        XCTAssertEqual(
            state["revision"] as? String,
            "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
        )

        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let proSection = try section(named: "MiloPro", before: "MiloLite", in: project)
        let liteSection = try section(named: "MiloLite", before: "MiloPrivilegedHelper", in: project)
        XCTAssertTrue(proSection.contains("product: MiloSparkle"))
        XCTAssertTrue(proSection.contains("product: MiloUpdates"))
        XCTAssertFalse(liteSection.contains("Sparkle"))
        XCTAssertFalse(liteSection.contains("MiloUpdates"))
    }

    private func sourceText(in directory: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw AuthenticatedUpdateRegressionError.cannotEnumerate(directory.path)
        }
        var source = ""
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                source += try String(contentsOf: fileURL, encoding: .utf8)
            }
        }
        return source
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw AuthenticatedUpdateRegressionError.expectedDictionary(url.path)
        }
        return dictionary
    }

    private func section(named name: String, before nextName: String, in source: String) throws -> String {
        let startMarker = "\n  \(name):\n"
        let endMarker = "\n  \(nextName):\n"
        guard let startRange = source.range(of: startMarker) else {
            throw AuthenticatedUpdateRegressionError.missingSection(name)
        }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: endMarker) else {
            throw AuthenticatedUpdateRegressionError.missingSection(nextName)
        }
        return String(remainder[..<endRange.lowerBound])
    }
}

private enum AuthenticatedUpdateRegressionError: LocalizedError {
    case cannotEnumerate(String)
    case expectedDictionary(String)
    case missingSection(String)

    var errorDescription: String? {
        switch self {
        case let .cannotEnumerate(path):
            return "Could not enumerate \(path)."
        case let .expectedDictionary(path):
            return "Expected a property-list dictionary at \(path)."
        case let .missingSection(name):
            return "Missing project section \(name)."
        }
    }
}
