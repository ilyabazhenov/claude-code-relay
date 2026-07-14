// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // In-app updates. Sparkle is embedded into the hand-assembled .app bundle by
        // scripts/build_app.sh (copied into Contents/Frameworks and ad-hoc signed).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Relay",
            linkerSettings: [
                // The framework lives in Contents/Frameworks of the assembled bundle, so
                // the executable must carry an rpath pointing there. Without this dyld can't
                // find Sparkle.framework and the app aborts on launch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "RelayTests",
            dependencies: ["Relay"],
            path: "Tests/RelayTests"
        )
    ]
)
