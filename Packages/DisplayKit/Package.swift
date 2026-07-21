// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DisplayKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DisplayKit", targets: ["DisplayKit"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../CueSyncUI")
    ],
    targets: [
        .target(name: "DisplayKit", dependencies: ["CueSyncCore", "CueSyncUI"]),
        .testTarget(name: "DisplayKitTests", dependencies: ["DisplayKit"])
    ]
)
