// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnowMac",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "SnowMac",
            path: "Sources/SnowMac"
        )
    ]
)
