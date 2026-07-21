// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CueSyncTestSupport",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CueSyncTestSupport", targets: ["CueSyncTestSupport"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore")
    ],
    targets: [
        .target(name: "CueSyncTestSupport", dependencies: ["CueSyncCore"]),
        .testTarget(name: "CueSyncTestSupportTests", dependencies: ["CueSyncTestSupport"])
    ]
)
