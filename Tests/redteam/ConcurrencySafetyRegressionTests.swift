import Foundation
import XCTest

final class ConcurrencySafetyRegressionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testUncheckedSendableConformancesHaveAdjacentSafetyProofs() throws {
        let marker = "@unchecked" + " Sendable"
        for fileURL in try shippingSwiftFiles() {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains(marker) {
                let proofStart = max(0, index - 4)
                let proof = lines[proofStart..<index].joined(separator: "\n")
                XCTAssertTrue(
                    proof.contains("SAFETY:"),
                    "Unchecked Sendable lacks an adjacent SAFETY proof: \(fileURL.path):\(index + 1)"
                )
            }
        }
    }

    func testUnsafeConcurrencyEscapeHatchesAreAbsent() throws {
        let forbiddenMarkers = [
            "nonisolated" + "(unsafe)",
            "@pre" + "concurrency"
        ]
        for fileURL in try shippingSwiftFiles() {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for marker in forbiddenMarkers {
                XCTAssertFalse(source.contains(marker), "Forbidden concurrency escape hatch in \(fileURL.path)")
            }
        }
    }

    func testEveryBuildGraphRequiresCompleteSwiftConcurrency() throws {
        let rootPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let kitPackage = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Packages/MiloKit/Package.swift"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(rootPackage.contains("-strict-concurrency=complete"))
        XCTAssertTrue(kitPackage.contains("-strict-concurrency=complete"))
        XCTAssertFalse(rootPackage.contains("-strict-concurrency=targeted"))
        XCTAssertFalse(kitPackage.contains("-strict-concurrency=targeted"))
        XCTAssertTrue(project.contains("SWIFT_STRICT_CONCURRENCY: complete"))
        XCTAssertTrue(project.contains("SWIFT_TREAT_WARNINGS_AS_ERRORS: YES"))
        XCTAssertTrue(project.contains("GCC_TREAT_WARNINGS_AS_ERRORS: YES"))
        XCTAssertTrue(project.contains("ALWAYS_SEARCH_USER_PATHS: NO"))
        XCTAssertTrue(project.contains("CLANG_ENABLE_OBJC_WEAK: YES"))
        XCTAssertTrue(project.contains("ENABLE_STRICT_OBJC_MSGSEND: YES"))
        XCTAssertTrue(project.contains("ENABLE_USER_SCRIPT_SANDBOXING: YES"))
    }

    private func shippingSwiftFiles() throws -> [URL] {
        let roots = ["App", "Helper", "Packages"].map { repositoryRoot.appendingPathComponent($0) }
        return try roots.flatMap { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "swift" else {
                    return nil
                }
                return url
            }
        }
    }
}
