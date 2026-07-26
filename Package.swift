// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let ignoredCompatibilityFile = packageRoot.appendingPathComponent("App/Milo/Runtime/Secrets.swift")
let appTargetExcludes = [
    "Info.plist",
    "Milo.entitlements",
    "Sparkle"
] + (FileManager.default.fileExists(atPath: ignoredCompatibilityFile.path) ? ["Runtime/Secrets.swift"] : [])

let package = Package(
    name: "Milo",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "Packages/MiloKit")
    ],
    targets: [
        .executableTarget(
            name: "Milo",
            dependencies: [
                .product(name: "MiloDomain", package: "MiloKit"),
                .product(name: "MiloHardening", package: "MiloKit"),
                .product(name: "MiloLicense", package: "MiloKit"),
                .product(name: "MiloSparkle", package: "MiloKit"),
                .product(name: "MiloUpdates", package: "MiloKit")
            ],
            path: "App/Milo",
            exclude: appTargetExcludes,
            sources: [
                "MiloApp.swift",
                "Runtime/AppState.swift",
                "Runtime/BackendConfiguration.swift",
                "Runtime/CloudSignatureManager.swift",
                "Runtime/CommandRunner.swift",
                "Runtime/ContentView.swift",
                "Runtime/DebloatCommand.swift",
                "Runtime/DebloatManager.swift",
                "Runtime/DebloatView.swift",
                "Runtime/DedicatedWindowView.swift",
                "Runtime/IconManager.swift",
                "Runtime/LicenseManager.swift",
                "Runtime/MemoryManager.swift",
                "Runtime/MenuBarAppDelegate.swift",
                "Runtime/MiloClientConfiguration.swift",
                "Runtime/MiloLog.swift",
                "Runtime/MiloUpdateManager.swift",
                "Runtime/PaywallView.swift",
                "Runtime/PrivilegeManager.swift",
                "Runtime/ProcessData.swift",
                "Runtime/ProcessManager.swift",
                "Runtime/SIPChecker.swift",
                "Runtime/SelfTestRunner.swift",
                "Runtime/SettingsManager.swift",
                "Runtime/SettingsView.swift",
                "Runtime/SharedUI.swift",
                "Runtime/StatsManager.swift",
                "Runtime/StatsView.swift",
                "Runtime/WhitelistManager.swift",
                "Runtime/WhitelistView.swift"
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .unsafeFlags(["-strict-concurrency=complete"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MiloRedTeamTests",
            path: "Tests/redteam"
        )
    ]
)
