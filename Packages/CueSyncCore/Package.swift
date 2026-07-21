// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CueSyncCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CueSyncCore", targets: ["CueSyncCore"])
    ],
    targets: [
        .target(name: "CueSyncCore"),
        .testTarget(name: "CueSyncCoreTests", dependencies: ["CueSyncCore"])
    ]
)
