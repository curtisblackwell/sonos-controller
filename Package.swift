// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonosMenuBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "SonosMenuBar", path: "Sources/SonosMenuBar"),
        .testTarget(name: "SonosMenuBarTests", dependencies: ["SonosMenuBar"], path: "Tests/SonosMenuBarTests"),
    ]
)
