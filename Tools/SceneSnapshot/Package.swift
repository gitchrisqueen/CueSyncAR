// swift-tools-version: 6.1
//
//  Package.swift
//  SceneSnapshot
//
//  Offline renderer (macOS): composes a synthetic mid-game layout, runs the
//  REAL ShotPlanner + AnalyticSolver on it, and renders the app's own
//  TableSceneView / ShotAdvisorCard to PNG. Lets the advisor visuals be
//  reviewed without a device or simulator runtime. Output is synthetic data
//  only (no photos, no venue data).
//

import PackageDescription

let package = Package(
    name: "SceneSnapshot",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/CueSyncUI"),
        .package(path: "../../Packages/CoachKit"),
        .package(path: "../../Packages/BilliardsPhysics"),
    ],
    targets: [
        .executableTarget(
            name: "scene-snapshot",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "CueSyncUI", package: "CueSyncUI"),
                .product(name: "CoachKit", package: "CoachKit"),
                .product(name: "BilliardsPhysics", package: "BilliardsPhysics"),
            ]
        ),
    ]
)
