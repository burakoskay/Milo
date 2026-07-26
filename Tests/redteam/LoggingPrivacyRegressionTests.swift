import Foundation
import XCTest

final class LoggingPrivacyRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLogBoundaryPublishesOnlyTypedCodes() throws {
        let logSource = try String(
            contentsOf: runtimeDirectory.appendingPathComponent("MiloLog.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(logSource.contains("is" + "Public"))
        XCTAssertTrue(logSource.contains("code.rawValue, privacy: .public"))
        XCTAssertTrue(logSource.contains("detail, privacy: .private"))
        XCTAssertFalse(logSource.contains("message, privacy: .public"))

        let rawValuePattern = #"case\s+\w+\s*=\s*\"([a-z][a-z0-9.-]+)\""#
        let rawValues = try captures(matching: rawValuePattern, in: logSource)
        XCTAssertFalse(rawValues.isEmpty)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "Log codes must be globally unique")
    }

    func testRuntimeCannotSubmitFreeFormPublicLogs() throws {
        let freeFormPattern = #"MiloLog\.(?:error|warning|info)\s*\(\s*\""#
        let freeFormExpression = try NSRegularExpression(pattern: freeFormPattern)

        for fileURL in try runtimeSwiftFiles() where fileURL.lastPathComponent != "MiloLog.swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
            XCTAssertNil(
                freeFormExpression.firstMatch(in: source, range: fullRange),
                "Runtime log calls must begin with a typed MiloLog.Code: \(fileURL.path)"
            )
            XCTAssertFalse(
                source.contains("privacy: .public"),
                "Only MiloLog may define public logging fields: \(fileURL.path)"
            )
        }
    }

    private var runtimeDirectory: URL {
        repositoryRoot.appendingPathComponent("App/Milo/Runtime")
    }

    private func runtimeSwiftFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: runtimeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        return enumerator.compactMap { item -> URL? in
            guard
                let url = item as? URL,
                url.pathExtension == "swift",
                url.lastPathComponent != "Secrets.swift"
            else {
                return nil
            }
            return url
        }
    }

    private func captures(matching pattern: String, in source: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: fullRange).compactMap { match in
            guard
                match.numberOfRanges == 2,
                let range = Range(match.range(at: 1), in: source)
            else {
                return nil
            }
            return String(source[range])
        }
    }
}
