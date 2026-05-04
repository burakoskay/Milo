// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Milo",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Milo",
            path: "Milo/Sources",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-framework", "-Xlinker", "Cocoa",
                    "-Xlinker", "-framework", "-Xlinker", "SwiftUI",
                    "-Xlinker", "-framework", "-Xlinker", "WebKit"
                ])
            ]
        )
    ]
)
