//
//  main.swift
//  SceneSnapshot
//
//  Usage: scene-snapshot <output-directory>
//  Writes advisor-table.png and advisor-cards.png.
//

import AppKit
import BilliardsPhysics
import CoachKit
import CueSyncCore
import CueSyncUI
import SwiftUI

private func color(for shot: ShotOption) -> ColorToken {
    switch shot.rating {
    case .easy: Theme.adviceEasy
    case .medium: Theme.adviceMedium
    case .hard: Theme.adviceHard
    }
}

@MainActor
private func writePNG<V: View>(_ view: V, to url: URL, size: CGSize) throws {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = 2
    guard let image = renderer.cgImage else {
        throw CocoaError(.fileWriteUnknown)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
    print("wrote \(url.path) (\(data.count) bytes)")
}

@MainActor
private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        FileHandle.standardError.write(Data("usage: scene-snapshot <output-directory>\n".utf8))
        exit(2)
    }
    let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Synthetic mid-game layout on a 9-ft table.
    let table = Table(size: .nineFoot)
    let state = TableState(table: table, balls: [
        Ball(id: BallID(0), kind: .cue, position: Vec2(-0.75, -0.12)),
        Ball(id: BallID(3), kind: .solid(3), position: Vec2(0.30, 0.22)),
        Ball(id: BallID(5), kind: .solid(5), position: Vec2(0.85, -0.30)),
        Ball(id: BallID(8), kind: .eight, position: Vec2(0.62, 0.05)),
        Ball(id: BallID(11), kind: .stripe(11), position: Vec2(-0.20, 0.40)),
        Ball(id: BallID(13), kind: .stripe(13), position: Vec2(1.0, 0.30)),
    ])

    let options = ShotPlanner.plan(state: state)
    print("planner options (easiest first):")
    for option in options {
        print(String(format: "  %@ — %@ — difficulty %.2f",
                     option.title, option.detail, option.difficulty))
    }
    guard let best = options.first else {
        print("no viable shot in the demo layout")
        exit(1)
    }

    // The player's CURRENT aim deliberately differs from the advised shot
    // (toward the 8-ball), so both layers are visible and distinguishable.
    let cue = state.cueBall!.position
    let currentAim = AimRay(origin: cue, direction: Vec2(0.62, 0.05) - cue)
    let prediction = AnalyticSolver().predict(
        state: state, aim: currentAim, options: SolverOptions(initialSpeed: 3.5))
    let advice = TableScene.Advice(cue: best.aim.origin, ghost: best.ghostBall,
                                   target: best.targetPosition,
                                   pocket: best.pocketPosition,
                                   pocketRadius: best.pocketCaptureRadius,
                                   color: Theme.adviceLine)

    try writePNG(
        TableSceneView(state: state, prediction: prediction, advice: advice)
            .padding(24)
            .background(Color(red: 0.05, green: 0.06, blue: 0.08)),
        to: outDir.appendingPathComponent("advisor-table.png"),
        size: CGSize(width: 1100, height: 620))

    let cards = VStack(spacing: 14) {
        ForEach(Array(options.prefix(3).enumerated()), id: \.offset) { index, shot in
            ShotAdvisorCard(title: shot.title, detail: shot.detail,
                            color: color(for: shot), position: index + 1,
                            total: min(3, options.count), onNext: {})
        }
    }
    .padding(24)
    .background(Color(red: 0.05, green: 0.06, blue: 0.08))
    try writePNG(cards, to: outDir.appendingPathComponent("advisor-cards.png"),
                 size: CGSize(width: 460, height: 260))
}

do {
    try MainActor.assumeIsolated { try run() }
} catch {
    FileHandle.standardError.write(Data("scene-snapshot failed: \(error)\n".utf8))
    exit(1)
}
