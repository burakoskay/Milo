// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiloKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MiloDomain", targets: ["MiloDomain"]),
        .library(name: "MiloLicense", targets: ["MiloLicense"]),
        .library(name: "MiloHardening", targets: ["MiloHardening"]),
        .library(name: "MiloUpdates", targets: ["MiloUpdates"]),
        .library(name: "MiloSparkle", targets: ["MiloSparkle"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(name: "MiloDomain", swiftSettings: strictSwiftSettings),
        .target(
            name: "MiloHardeningC",
            path: "Sources/MiloHardening",
            sources: [
                "ConstantTime.c",
                "HoneypotChecks.c",
                "LicenseVerify.c",
                "KeychainKey.c",
                "Integrity.c",
                "Fingerprint.c",
                "AntiDebug.c",
                "AntiInstrumentation.c"
            ],
            publicHeadersPath: ".",
            cSettings: hardeningCSettings,
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "MiloHardening",
            dependencies: ["MiloHardeningC"],
            path: "Sources/MiloHardening",
            exclude: [
                "AntiDebug.c",
                "AntiDebug.h",
                "AntiInstrumentation.c",
                "AntiInstrumentation.h",
                "ConstantTime.c",
                "ConstantTime.h",
                "Fingerprint.c",
                "Fingerprint.h",
                "HoneypotChecks.c",
                "HoneypotChecks.h",
                "Integrity.c",
                "Integrity.h",
                "LicenseVerify.c",
                "LicenseVerify.h",
                "KeychainKey.c",
                "KeychainKey.h"
            ],
            sources: [
                "EdDSAPrimitive.swift",
                "Integrity.swift"
            ],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "MiloLicense",
            dependencies: ["MiloDomain", "MiloHardening", "MiloHardeningC"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "MiloUpdates",
            dependencies: ["MiloDomain", "MiloLicense"],
            swiftSettings: strictSwiftSettings
        ),
        .target(
            name: "MiloSparkle",
            dependencies: [
                "MiloUpdates",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "MiloUpdatesTests",
            dependencies: ["MiloUpdates"],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "MiloLicenseTests",
            dependencies: ["MiloLicense"],
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "MiloDomainTests",
            dependencies: ["MiloDomain"],
            swiftSettings: strictSwiftSettings
        )
    ]
)

private let strictSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-strict-concurrency=complete",
        "-warnings-as-errors"
    ])
]

private let hardeningCSettings: [CSetting] = [
    .define("_FORTIFY_SOURCE", to: "2"),
    .unsafeFlags([
        "-fstack-protector-all",
        "-fvisibility=hidden",
        "-fno-asynchronous-unwind-tables"
    ])
]
