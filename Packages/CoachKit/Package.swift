// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CoachKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CoachKit", targets: ["CoachKit"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        // Test-only: the planner is cross-checked against the real solver.
        .package(path: "../BilliardsPhysics"),
        // Test-only: canonical fixtures (full eight-ball rack) for the speed budget.
        .package(path: "../CueSyncTestSupport")
    ],
    targets: [
        .target(name: "CoachKit", dependencies: ["CueSyncCore"]),
        .testTarget(name: "CoachKitTests",
                    dependencies: ["CoachKit", "BilliardsPhysics", "CueSyncTestSupport"])
    ]
)
