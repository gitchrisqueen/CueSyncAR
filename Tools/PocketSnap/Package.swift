// swift-tools-version: 6.1
//
//  Package.swift
//  PocketSnap
//
//  Offline pocket-snap CLI: runs TableSpace.PocketSnap on a grayscale frame
//  (for example a debug-mirror /frame.jpg converted with ffmpeg) so pocket
//  picks can be refined and inspected on the Mac. Scripts/calibrate-pockets.py
//  uses it with --snap.
//

import PackageDescription

let package = Package(
    name: "PocketSnap",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/TableSpace"),
    ],
    targets: [
        .executableTarget(
            name: "pocket-snap",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "TableSpace", package: "TableSpace"),
            ]
        ),
    ]
)
