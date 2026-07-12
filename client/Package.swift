// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Meadow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Meadow",
            path: "Sources/Meadow"
        )
    ]
)
