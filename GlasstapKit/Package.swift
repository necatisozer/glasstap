// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GlasstapKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GlasstapKit", targets: ["GlasstapKit"]),
    ],
    targets: [
        .target(name: "GlasstapKit"),
        .testTarget(name: "GlasstapKitTests", dependencies: ["GlasstapKit"]),
    ]
)
