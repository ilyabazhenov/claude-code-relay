// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            path: "Sources/Relay"
        ),
        .testTarget(
            name: "RelayTests",
            dependencies: ["Relay"],
            path: "Tests/RelayTests"
        )
    ]
)
