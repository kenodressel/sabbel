// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sabbel",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .target(name: "SabbelCore"),
        .target(name: "SabbelEngine", dependencies: [
            "SabbelCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "SabbelSystem", dependencies: ["SabbelCore"], linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("AVFoundation"),
        ]),
        .executableTarget(name: "Sabbel", dependencies: ["SabbelCore", "SabbelEngine", "SabbelSystem"]),
        .executableTarget(name: "sabbel-eval", dependencies: ["SabbelCore", "SabbelEngine"]),
        .testTarget(name: "SabbelCoreTests", dependencies: ["SabbelCore"]),
        .testTarget(name: "SabbelSystemTests", dependencies: ["SabbelSystem"]),
        .testTarget(name: "SabbelEngineTests", dependencies: ["SabbelEngine"], exclude: ["Fixtures"]),
    ]
)
