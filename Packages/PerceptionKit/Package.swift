// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PerceptionKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PerceptionKit", targets: ["PerceptionKit"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore")
    ],
    targets: [
        .target(name: "PerceptionKit", dependencies: ["CueSyncCore"]),
        .testTarget(name: "PerceptionKitTests", dependencies: ["PerceptionKit"])
    ]
)
