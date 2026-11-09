// swift-tools-version: 6.1
//
//  Package.swift
//  OverlayRender
//
//  Offscreen renderer (macOS): builds the app's REAL AR overlay entities
//  (ARExperience.OverlayEntityBuilder, the same code OverlayRenderer runs on
//  device) for a synthetic table + the REAL ShotPlanner's advice, renders
//  them with RealityKit's RealityRenderer from a phone-like camera pose and
//  composites the result over a still image. No ARKit, no device. Output is
//  synthetic data only (no photos, no venue data).
//

import PackageDescription

let package = Package(
    name: "OverlayRender",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/TableSpace"),
        .package(path: "../../Packages/CoachKit"),
        .package(path: "../../Packages/ARExperience"),
    ],
    targets: [
        .executableTarget(
            name: "overlay-render",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "TableSpace", package: "TableSpace"),
                .product(name: "CoachKit", package: "CoachKit"),
                .product(name: "ARExperience", package: "ARExperience"),
            ]
        ),
    ]
)
