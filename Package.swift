// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.10.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoiceApp",
            dependencies: [
                "VoiceAppCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/VoiceApp"
        ),
        .target(
            name: "VoiceAppCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "VoiceAppCoreTests",
            dependencies: ["VoiceAppCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
