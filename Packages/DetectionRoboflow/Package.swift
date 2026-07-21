// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DetectionRoboflow",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DetectionRoboflow", targets: ["DetectionRoboflow"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../CueSyncTestSupport")
    ],
    targets: [
        .target(name: "DetectionRoboflow", dependencies: ["CueSyncCore"]),
        .testTarget(name: "DetectionRoboflowTests",
                    dependencies: ["DetectionRoboflow", "CueSyncTestSupport"])
    ]
)
