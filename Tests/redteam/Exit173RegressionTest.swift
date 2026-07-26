import XCTest

final class Exit173RegressionTest: XCTestCase {
    func testExit173DoesNotAppearInShippingSources() throws {
        let forbiddenMarker = "exit" + "(173)"
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let paths = [
            "App",
            "Packages",
            "Tools",
            "Tests"
        ]

        for path in paths {
            let directory = root.appendingPathComponent(path)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            let textExtensions: Set<String> = ["swift", "c", "h", "m", "mm", "ts", "sql", "sh", "md", "plist", "json", "yml", "yaml"]
            for case let fileURL as URL in enumerator where textExtensions.contains(fileURL.pathExtension) {
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    continue
                }
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertFalse(contents.contains(forbiddenMarker), "\(fileURL.path) contains forbidden tamper-exit marker")
            }
        }
    }
}
