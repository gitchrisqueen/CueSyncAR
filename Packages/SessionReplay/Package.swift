// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "SessionReplay",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SessionReplay", targets: ["SessionReplay"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../TableSpace"),
        .package(path: "../PerceptionKit"),
        .package(path: "../ARExperience"),
        .package(path: "../BilliardsPhysics"),
        .package(path: "../CueSyncTestSupport")
    ],
    targets: [
        .target(name: "SessionReplay",
                dependencies: ["CueSyncCore", "TableSpace", "PerceptionKit",
                               "ARExperience", "BilliardsPhysics"]),
        .testTarget(name: "SessionReplayTests",
                    dependencies: ["SessionReplay", "CueSyncTestSupport"],
                    resources: [.copy("Fixtures")])
    ]
)
