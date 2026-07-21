// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DisplayKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DisplayKit", targets: ["DisplayKit"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore")
    ],
    targets: [
        .target(name: "DisplayKit", dependencies: ["CueSyncCore"]),
        .testTarget(name: "DisplayKitTests", dependencies: ["DisplayKit"])
    ]
)
