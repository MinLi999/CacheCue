// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CacheCue",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that decides what is shown, kept free of AppKit so it can be tested.
        .target(name: "CacheCueCore"),
        .executableTarget(name: "CacheCue", dependencies: ["CacheCueCore"]),
        .testTarget(name: "CacheCueCoreTests", dependencies: ["CacheCueCore"]),
    ]
)
