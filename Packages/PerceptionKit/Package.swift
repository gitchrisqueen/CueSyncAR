// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PerceptionKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "PerceptionKit", targets: ["PerceptionKit"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../TableSpace"),
        .package(path: "../CueSyncTestSupport")
    ],
    targets: [
        .target(name: "PerceptionKit", dependencies: ["CueSyncCore", "TableSpace"]),
        .testTarget(name: "PerceptionKitTests",
                    dependencies: ["PerceptionKit", "CueSyncTestSupport"])
    ]
)
