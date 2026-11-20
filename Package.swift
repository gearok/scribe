// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Scribe",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Scribe", targets: ["Scribe"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "ScribeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "Scribe", dependencies: [
            "ScribeCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Sparkle", package: "Sparkle"),
        ], resources: [.process("Resources")]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
        .testTarget(name: "ScribeAudioTests", dependencies: ["Scribe", "ScribeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
