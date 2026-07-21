// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BilliardsPhysics",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BilliardsPhysics", targets: ["BilliardsPhysics"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../CueSyncTestSupport")
    ],
    targets: [
        .target(name: "BilliardsPhysics", dependencies: ["CueSyncCore"]),
        .testTarget(name: "BilliardsPhysicsTests",
                    dependencies: ["BilliardsPhysics", "CueSyncTestSupport"])
    ]
)
