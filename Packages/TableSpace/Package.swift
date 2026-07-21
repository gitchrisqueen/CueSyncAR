// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TableSpace",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TableSpace", targets: ["TableSpace"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore")
    ],
    targets: [
        .target(name: "TableSpace", dependencies: ["CueSyncCore"]),
        .testTarget(name: "TableSpaceTests", dependencies: ["TableSpace"])
    ]
)
