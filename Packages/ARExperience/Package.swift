// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ARExperience",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ARExperience", targets: ["ARExperience"])
    ],
    dependencies: [
        .package(path: "../CueSyncCore"),
        .package(path: "../TableSpace"),
        .package(path: "../PerceptionKit")
    ],
    targets: [
        .target(name: "ARExperience",
                dependencies: ["CueSyncCore", "TableSpace", "PerceptionKit"]),
        .testTarget(name: "ARExperienceTests", dependencies: ["ARExperience"])
    ]
)
