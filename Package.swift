// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SonosMenuBar",
    platforms: [.macOS(.v14)],
    // tools-version 6.0 is what makes the bundled swift-testing module available to the
    // test target; the sources stay in Swift 5 language mode.
    targets: [
        .executableTarget(name: "SonosMenuBar", path: "Sources/SonosMenuBar"),
        .testTarget(name: "SonosMenuBarTests", dependencies: ["SonosMenuBar"], path: "Tests/SonosMenuBarTests"),
    ],
    swiftLanguageModes: [.v5]
)
