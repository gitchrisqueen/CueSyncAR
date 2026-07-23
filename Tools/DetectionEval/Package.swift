// swift-tools-version: 6.1
//
//  Package.swift
//  DetectionEval
//
//  Offline model-eval CLI (04-TESTING-STRATEGY "Model evaluation"): runs the
//  bundled Core ML ball detector against still images on macOS — no device,
//  no camera. Feeds the T2.2 replay-suite fixtures and the T1.3 ANE-export
//  parity checks (same image, --compute cpu vs all, diff the boxes).
//

import PackageDescription

let package = Package(
    name: "DetectionEval",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/CueSyncCore"),
        .package(path: "../../Packages/PerceptionKit"),
    ],
    targets: [
        .executableTarget(
            name: "detection-eval",
            dependencies: [
                .product(name: "CueSyncCore", package: "CueSyncCore"),
                .product(name: "PerceptionKit", package: "PerceptionKit"),
            ]
        ),
    ]
)
