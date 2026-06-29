// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maverything",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MaverythingCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "Maverything",
            dependencies: ["MaverythingCore"]
        ),
        .executableTarget(
            name: "mvtest",
            dependencies: ["MaverythingCore"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
    ],
    swiftLanguageModes: [.v5]
)
