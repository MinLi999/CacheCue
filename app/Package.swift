// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CacheCue",
    platforms: [.macOS(.v13)],
    dependencies: [
        // In-place updates. The app's only dependency; the core below has none.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Everything that decides what is shown, kept free of AppKit so it can be tested.
        .target(name: "CacheCueCore"),
        .executableTarget(
            name: "CacheCue",
            dependencies: ["CacheCueCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // Inside the app bundle the framework sits in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .testTarget(name: "CacheCueCoreTests", dependencies: ["CacheCueCore"]),
    ]
)
