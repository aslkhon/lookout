// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lookout",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LookoutCore"),
        .executableTarget(name: "lookout-hook", dependencies: ["LookoutCore"]),
        .executableTarget(name: "Lookout", dependencies: ["LookoutCore"]),
        .testTarget(
            name: "LookoutCoreTests",
            dependencies: ["LookoutCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
