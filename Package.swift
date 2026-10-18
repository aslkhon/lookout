// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookout",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
    ],
    targets: [
        .target(name: "LookoutCore"),
        .executableTarget(name: "lookout-hook", dependencies: ["LookoutCore"]),
        .executableTarget(name: "Lookout", dependencies: ["LookoutCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(
            name: "LookoutCoreTests",
            dependencies: ["LookoutCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
