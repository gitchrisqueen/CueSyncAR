// swift-tools-version: 6.1
//
//  Package.swift
//  VideoReplay
//
//  Offline video replay (macOS): runs the app's Core ML detector, the real
//  BallTracker and the real ShotPlanner over frames extracted from real pool
//  footage and draws the advised shot over each frame. A plane homography
//  from four hand-marked cushion corners stands in for ARKit's raycaster,
//  which needs intrinsics that plain video lacks. Footage and annotated
//  frames stay OUTSIDE the repo (see clips/clips.md).
//

import PackageDescription

let package = Package(
    name: "VideoReplay",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/PerceptionKit"),
        .package(path: "../../Packages/CoachKit"),
        .package(path: "../../Packages/TableSpace"),
    ],
    targets: [
        .target(
            name: "VideoReplayKit",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "PerceptionKit", package: "PerceptionKit"),
                .product(name: "CoachKit", package: "CoachKit"),
                .product(name: "TableSpace", package: "TableSpace"),
            ]
        ),
        .executableTarget(
            name: "video-replay",
            dependencies: ["VideoReplayKit"]
        ),
        .testTarget(
            name: "VideoReplayKitTests",
            dependencies: [
                "VideoReplayKit",
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "CoachKit", package: "CoachKit"),
            ]
        ),
    ]
)
