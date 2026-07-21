// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CueSyncUI",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CueSyncUI", targets: ["CueSyncUI"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore")
    ],
    targets: [
        .target(name: "CueSyncUI", dependencies: ["CueSyncCore"]),
        .testTarget(name: "CueSyncUITests", dependencies: ["CueSyncUI"])
    ]
)
