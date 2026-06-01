// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gulper",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "Gulper",
            path: "Sources/Gulper",
            exclude: ["Info.plist"],
            resources: [.copy("Resources")]
        )
    ]
)
