// swift-tools-version: 6.0
import PackageDescription

// NOTE: release builds no longer pass `-Ounchecked`. That flag drops Swift's bounds /
// overflow / precondition checks, so a bug surfaces as a wrong result or memory
// corruption instead of a clean trap — unacceptable for a file-search tool people trust.
// (It once masked an `Int(UInt64.max)` overflow in _appendOne.) Standard `-O` (release
// default) keeps those checks. If a hot loop ever needs it, wrap just that loop in a
// perf-lab build (`swift build -c release -Xswiftc -Ounchecked`), never the shipped one.
let package = Package(
    name: "Maverything",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4")
    ],
    targets: [
        .target(
            name: "MaverythingCore"
        ),
        .executableTarget(
            name: "Maverything",
            dependencies: [
                "MaverythingCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "mvtest",
            dependencies: ["MaverythingCore"]
        ),
        .executableTarget(
            name: "mvsim",
            dependencies: ["MaverythingCore"]
        ),
        .executableTarget(
            name: "mvfind",
            dependencies: ["MaverythingCore"]
        ),
        .executableTarget(
            name: "mv-mcp",
            dependencies: ["MaverythingCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
