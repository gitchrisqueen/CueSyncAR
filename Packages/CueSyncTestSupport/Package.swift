// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CueSyncTestSupport",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CueSyncTestSupport", targets: ["CueSyncTestSupport"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        // The synthetic pinhole harness projects onto TableCalibration
        // planes. The graph stays acyclic: TableSpace depends on CueSyncCore
        // only, and nothing TableSpace builds depends on this package.
        .package(path: "../TableSpace")
    ],
    targets: [
        .target(name: "CueSyncTestSupport", dependencies: ["CueSyncCore", "TableSpace"]),
        .testTarget(name: "CueSyncTestSupportTests", dependencies: ["CueSyncTestSupport"])
    ]
)
