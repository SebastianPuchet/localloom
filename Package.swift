// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LocalLoom",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LocalLoom",
            path: "Sources/LocalLoom",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
