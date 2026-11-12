// swift-tools-version: 6.1
//
//  Package.swift
//  IdentityEval
//
//  Local harness (macOS only): replays a recorded session's video and
//  detector boxes through the app's own BallAppearancePass, BallAppearance,
//  BallIdentity and EightElection, and scores the names against a truth
//  table of numbers and names. The recording stays on disk outside the
//  repo; nothing here reads a path unless it is given one.
//

import PackageDescription

let package = Package(
    name: "IdentityEval",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/TableSpace"),
        .package(path: "../../Packages/PerceptionKit"),
    ],
    targets: [
        .executableTarget(
            name: "identity-eval",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "TableSpace", package: "TableSpace"),
                .product(name: "PerceptionKit", package: "PerceptionKit"),
            ]
        ),
    ]
)
