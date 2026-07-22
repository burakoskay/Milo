// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Milo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "Packages/MiloKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Milo",
            dependencies: [
                .product(name: "MiloHardening", package: "MiloKit"),
                .product(name: "MiloLicense", package: "MiloKit"),
                .product(name: "MiloUpdates", package: "MiloKit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "App/Milo",
            exclude: [
                "Info.plist",
                "Milo.entitlements",
                "Sparkle"
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-strict-concurrency=targeted"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AuthenticationServices"),
                .linkedFramework("Cocoa"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "MiloRedTeamTests",
            path: "Tests/redteam"
        )
    ]
)
