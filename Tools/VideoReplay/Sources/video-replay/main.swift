//
//  main.swift
//  video-replay
//
//  Usage:
//    video-replay --model <BallDetector.mlpackage> --clip <clip dir> [--clip <dir> ...]
//                 [--out <name>] [--anchor foot|center] [--min-confidence 0.35]
//                 [--appearance-frames 2] [--disappearance-frames 4] [--sheet-frames 12]
//
//  Tracker defaults: the app confirms a ball after 3 frames and drops it after
//  30 misses at ~15 Hz (about 0.2 s / 2 s). The clips are extracted at 2 fps, so
//  this tool uses 2 / 4 frames (1 s / 2 s); appearance stays at 2 so a single
//  stray box never becomes a ball.
//
//  Each clip dir holds frames/ (png or jpg, sorted by name) and corners.json
//  (see ClipConfig.swift). Annotated frames, contact-sheet.png and
//  summary.json go to <clip dir>/<out> (default "out"): footage never enters
//  the repo. Exit code 1 on any failure, reason on stderr.
//

import Foundation
import PerceptionKit
import VideoReplayKit

struct Arguments {
    var modelPath = ""
    var clips: [String] = []
    var outName = "out"
    var anchor: BallAnchor = .foot
    var minConfidence = PerceptionConfig.default.confidenceFloor
    var appearanceFrames = 2
    var disappearanceFrames = 4
    var sheetFrames = 12

    static let usage = "usage: video-replay --model <path> --clip <dir> [--clip <dir>...] [--out <name>] "
        + "[--anchor foot|center] [--min-confidence <0-1>] [--appearance-frames <n>] "
        + "[--disappearance-frames <n>] [--sheet-frames <n>]"

    static func parse(_ arguments: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ReplayError.usage("missing value for \(arguments[index])") }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--model": result.modelPath = value
            case "--clip": result.clips.append(value)
            case "--out": result.outName = value
            case "--anchor":
                guard let anchor = BallAnchor(rawValue: value) else { throw ReplayError.usage("--anchor foot|center") }
                result.anchor = anchor
            case "--min-confidence":
                guard let number = Double(value), (0...1).contains(number) else {
                    throw ReplayError.usage("--min-confidence must be in 0...1")
                }
                result.minConfidence = number
            case "--appearance-frames":
                guard let number = Int(value), number >= 1 else { throw ReplayError.usage("--appearance-frames >= 1") }
                result.appearanceFrames = number
            case "--disappearance-frames":
                guard let number = Int(value), number >= 1 else {
                    throw ReplayError.usage("--disappearance-frames >= 1")
                }
                result.disappearanceFrames = number
            case "--sheet-frames":
                guard let number = Int(value), number >= 1 else { throw ReplayError.usage("--sheet-frames >= 1") }
                result.sheetFrames = number
            default: throw ReplayError.usage("unexpected argument '\(arguments[index])'")
            }
            index += 2
        }
        guard !result.modelPath.isEmpty, !result.clips.isEmpty else {
            throw ReplayError.usage("--model and at least one --clip are required")
        }
        return result
    }
}

enum ReplayError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): "usage error: \(message)\n\(Arguments.usage)"
        }
    }
}

do {
    let arguments = try Arguments.parse(CommandLine.arguments)
    let detector = try ClipReplayer.makeDetector(modelURL: URL(fileURLWithPath: arguments.modelPath))
    let config = AnalyzerConfig(
        minConfidence: arguments.minConfidence, anchor: arguments.anchor,
        tracker: TrackerConfig(appearanceFrames: arguments.appearanceFrames,
                               disappearanceFrames: arguments.disappearanceFrames))

    for clip in arguments.clips {
        let clipURL = URL(fileURLWithPath: clip)
        let outcome = try await ClipReplayer.replay(
            clipDirectory: clipURL,
            outputDirectory: clipURL.appendingPathComponent(arguments.outName),
            detector: detector, config: config, sheetFrames: arguments.sheetFrames)
        print("== \(clipURL.lastPathComponent)\n\(outcome.stats.report)")
        if let sheet = outcome.contactSheetURL { print("contact sheet: \(sheet.path)") }
    }
} catch {
    FileHandle.standardError.write(Data("video-replay: \(error)\n".utf8))
    exit(1)
}
