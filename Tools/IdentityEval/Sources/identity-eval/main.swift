//
//  main.swift
//  identity-eval
//
//  Usage:
//    identity-eval --recording <dir> [--interval N] [--looks <out.jsonl>]
//
//  Replays a device recording through the app's own colour path:
//  detector boxes -> table positions (PlaneGeometryRaycaster, sphere-centre
//  ray, as DetectionProjector does) -> nearest labelled ball -> the same
//  BallAppearancePass the pipeline calls -> BallIdentity.observe / retain /
//  apply, exactly as SessionModel does each frame. Track ids are the
//  labelled ball numbers, i.e. perfect tracking: this measures the colour
//  and group decisions, not the tracker.
//
//  Prints, per ball, how often the colour name, the group and the shot-card
//  kind are right, and how often the name changes. Writes nothing into the
//  recording; --looks dumps per-look numbers (no pixels) for analysis.
//

import CoreVideo
import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

struct Arguments {
    var recording: URL
    var interval = 1
    var looksPath: String?

    static func parse(_ arguments: [String]) -> Arguments? {
        var recording = ProcessInfo.processInfo.environment["IDENTITY_EVAL_DIR"]
        var interval = 1
        var looks: String?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--recording": recording = value
            case "--interval": interval = Int(value) ?? 1
            case "--looks": looks = value
            default: return nil
            }
            index += 2
        }
        guard let recording else { return nil }
        return Arguments(recording: URL(fileURLWithPath: recording), interval: max(1, interval), looksPath: looks)
    }
}

struct Tally {
    var present = 0
    var named = 0
    var colourRight = 0
    var groupKnown = 0
    var groupRight = 0
    var kindRight = 0
    var changes = 0
    var cardChanges = 0
    var lastKind: Ball.Kind?
    var lastName: ColorFamily?
    var wrongNames: [String: Int] = [:]
    var wrongGroups: [String: Int] = [:]
}

func percent(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "   - " : String(format: "%4.0f%%", 100 * Double(part) / Double(whole))
}

func run() throws {
    guard let arguments = Arguments.parse(CommandLine.arguments) else {
        FileHandle.standardError.write(Data(
            "usage: identity-eval --recording <dir> [--interval N] [--looks <out.jsonl>]\n  (or set IDENTITY_EVAL_DIR)\n".utf8))
        exit(1)
    }
    let recording = try RecordingLoader.load(directory: arguments.recording)
    let truth = Truth.gridLayout()
    let truthByID = Dictionary(uniqueKeysWithValues: truth.map { ($0.id, $0) })
    let raycaster = PlaneGeometryRaycaster(calibration: recording.calibration)
    let colourConfig = PerceptionConfig.default.colour
    let decoder = try VideoDecoder(url: recording.videoURL)
    var identity = BallIdentity()
    var tallies: [BallID: Tally] = [:]
    var looksOut = ""
    var videoIndex = 0
    var frameCount = 0
    // The tracker coasts a ball through a missed detection and keeps the
    // kind it voted for, so a track is live once seen and the cue ball
    // stays the cue ball. The harness does the same with the labelled ids.
    var liveTracks: [BallID: Ball.Kind] = [:]
    var framesWithoutCue: [Int] = []

    for recorded in recording.frames {
        var buffer: CVPixelBuffer?
        while videoIndex <= recorded.videoFrame {
            buffer = decoder.nextBuffer()
            videoIndex += 1
        }
        guard let buffer else { break }
        frameCount += 1

        // Locate each detection, then give it to the nearest labelled ball.
        var claimed: [BallID: (position: Vec2, box: NormalizedRect, kind: Ball.Kind, distance: Double)] = [:]
        for detection in recorded.detections where !detection.isCueStick && detection.confidence >= 0.35 {
            let box = detection.boundingBox
            let centre = Vec2(box.x + box.width / 2, box.y + box.height / 2)
            guard let world = raycaster.raycastToTablePlane(imagePoint: centre, frame: recorded.frame,
                                                            planeHeightOffset: Ball.standardRadius) else { continue }
            let position = recording.calibration.worldToTable(world)
            var best: (TruthBall, Double)?
            for candidate in truth {
                let distance = candidate.position.distance(to: position)
                if best == nil || distance < best!.1 { best = (candidate, distance) }
            }
            guard let (ball, distance) = best, distance < Truth.spacing * 0.45 else { continue }
            if let existing = claimed[ball.id], existing.distance <= distance { continue }
            claimed[ball.id] = (position, box, detection.ballKind, distance)
        }

        for (id, entry) in claimed where entry.kind == .cue { liveTracks[id] = .cue }
        for id in claimed.keys where liveTracks[id] == nil { liveTracks[id] = .unknown }
        let balls = liveTracks.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
            let position = claimed[id]?.position ?? truthByID[id]?.position ?? Vec2(0, 0)
            return Ball(id: id, kind: liveTracks[id] ?? .unknown, position: position)
        }
        let located = claimed.values.map { LocatedDetection(position: $0.position, box: $0.box, kind: $0.kind) }
        // The pipeline names a cue ball from the detector's own class, so a
        // frame in which the white-ball detection matches no labelled
        // position (its projection lands off the grid) would have the pass
        // guess a reference from the picture. Count those frames and skip
        // their colour looks; the report says how many.
        let cueMatched = claimed.values.contains { $0.kind == .cue }
        if !cueMatched { framesWithoutCue.append(recorded.index) }
        let colourFrame = recorded.index % arguments.interval == 0 && cueMatched
        var observations: [BallID: AppearanceObservation] = [:]
        if colourFrame {
            observations = PixelBufferImage(pixelBuffer: buffer).withReader { reader in
                BallAppearancePass.run(balls: balls, detections: located, image: reader, config: colourConfig)
            } ?? [:]
            identity.observe(observations)
            identity.retain(Set(balls.map(\.id)))
            if arguments.looksPath != nil {
                for (id, look) in observations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    looksOut += lookLine(frame: recorded.index, id: id, look: look)
                }
            }
        }

        let applied = identity.apply(to: TableState(table: Table(size: .eightFoot), balls: balls, timestamp: recorded.frame.timestamp))
        for ball in applied.balls {
            guard let expected = truthByID[ball.id], claimed[ball.id] != nil else { continue }
            var tally = tallies[ball.id] ?? Tally()
            tally.present += 1
            if let colour = identity.family(for: ball.id) {
                tally.named += 1
                if colour.family == expected.family { tally.colourRight += 1 } else {
                    tally.wrongNames[colour.family.rawValue, default: 0] += 1
                }
                if let last = tally.lastName, last != colour.family { tally.changes += 1 }
                tally.lastName = colour.family
            }
            if let group = identity.group(for: ball.id) {
                tally.groupKnown += 1
                if group == expected.grouping { tally.groupRight += 1 } else {
                    tally.wrongGroups[group.rawValue, default: 0] += 1
                }
            }
            if ball.kind == expected.kind { tally.kindRight += 1 }
            if let last = tally.lastKind, last != .unknown, ball.kind != .unknown, last != ball.kind { tally.cardChanges += 1 }
            if ball.kind != .unknown { tally.lastKind = ball.kind }
            tallies[ball.id] = tally
        }
    }

    print("recording frames used: \(frameCount), colour looks every \(arguments.interval) recorded frame(s)")
    print("frames with no matched white-ball detection (colour looks skipped): \(framesWithoutCue)")
    print("ball                  seen named colour% group-known group% card% changes cardChg wrong colours / wrong groups")
    var totals = Tally()
    for expected in truth {
        let tally = tallies[expected.id] ?? Tally()
        let wrong = tally.wrongNames.sorted { $0.value > $1.value }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        let wrongGroup = tally.wrongGroups.sorted { $0.value > $1.value }.map { "\($0.key)x\($0.value)" }.joined(separator: " ")
        let label = expected.label.padding(toLength: 20, withPad: " ", startingAt: 0)
        print("\(label) \(String(format: "%4d %5d", tally.present, tally.named)) \(percent(tally.colourRight, tally.present))"
            + "    \(percent(tally.groupKnown, tally.present))      \(percent(tally.groupRight, tally.present))"
            + " \(percent(tally.kindRight, tally.present)) \(String(format: "%5d", tally.changes))\(String(format: "%8d", tally.cardChanges))"
            + "     \(wrong) / \(wrongGroup)")
        totals.present += tally.present
        totals.colourRight += tally.colourRight
        totals.groupRight += tally.groupRight
        totals.groupKnown += tally.groupKnown
        totals.kindRight += tally.kindRight
        totals.changes += tally.changes
        totals.cardChanges += tally.cardChanges
    }
    print("ALL (ball-frames)     \(String(format: "%4d", totals.present))       \(percent(totals.colourRight, totals.present))"
        + "    \(percent(totals.groupKnown, totals.present))      \(percent(totals.groupRight, totals.present))"
        + " \(percent(totals.kindRight, totals.present)) \(String(format: "%5d", totals.changes))\(String(format: "%8d", totals.cardChanges))")
    print("colour% = right / frames the ball was seen (unnamed counts as not right); group% likewise; "
        + "card% = the kind the shot card would show equals the truth kind.")

    if let path = arguments.looksPath {
        try looksOut.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func lookLine(frame: Int, id: BallID, look: AppearanceObservation) -> String {
    let rgb = look.meanRGB.map { [$0.x, $0.y, $0.z] } ?? []
    let object: [String: Any] = [
        "frame": frame, "id": id.rawValue, "family": look.family.rawValue, "confidence": look.confidence,
        "relChroma": look.relativeChroma ?? -1, "relValue": look.relativeValue ?? -1,
        "whiteFraction": look.whiteFraction, "hueSpread": look.hueSpread ?? -1,
        "meanRGB": rgb, "fallback": look.fallbackFamily?.rawValue ?? "",
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "" }
    return text + "\n"
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("identity-eval: \(error)\n".utf8))
    exit(1)
}
