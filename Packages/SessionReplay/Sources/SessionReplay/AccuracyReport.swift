//
//  AccuracyReport.swift
//  SessionReplay
//
//  Scores a replay's outputs against the bundle's truth.json. Position
//  RMS, recall and precision are the 04-TESTING-STRATEGY accuracy bars;
//  track churn / identity switches are the stability bar ("no flicker, no
//  identity swaps"). Deterministic: matching is greedy nearest-first with
//  total-order tie-breaks.
//

import CueSyncCore
import Foundation

public struct AccuracyReport: Sendable, Equatable, Codable {
    /// Frames scored (after `warmupFrames` were skipped).
    public var evaluatedFrames: Int
    /// Σ truth balls over evaluated frames.
    public var truthBallFrames: Int
    /// Σ tracked balls over evaluated frames.
    public var trackedBallFrames: Int
    /// Truth balls that had a tracked ball within `matchRadius`.
    public var matchedBallFrames: Int
    /// RMS distance (m) over matched pairs; 0 when nothing matched.
    public var positionRMS: Double
    public var maxPositionError: Double
    /// matched / truth (1 when there is no truth).
    public var recall: Double
    /// matched / tracked (1 when nothing was tracked).
    public var precision: Double
    /// Distinct track ids that ever appeared in the evaluated frames.
    public var distinctTrackIDs: Int
    /// Times a truth ball's matched track id differed from the id it
    /// matched on the previous frame it was seen.
    public var identitySwitches: Int
    /// Distinct ids beyond the most balls truth ever had in one frame —
    /// every extra id is a track that was born and died (flicker, phantom,
    /// duplicate).
    public var trackChurn: Int

    /// Score `outputs` against `truth`, ignoring the first `warmupFrames`
    /// (the tracker's appearance gate legitimately reports nothing there).
    public static func compute(outputs: [OutputRecord], truth: SessionTruth,
                               warmupFrames: Int = 0) -> AccuracyReport {
        var evaluated = 0
        var truthCount = 0
        var trackedCount = 0
        var matched = 0
        var sumSquares = 0.0
        var maxError = 0.0
        var ids = Set<Int>()
        var switches = 0
        var maxTruthBalls = 0
        var lastMatchedID: [Int: Int] = [:]  // truth index → track id

        for record in outputs where record.frame >= warmupFrames {
            evaluated += 1
            let truthBalls = truth.balls(atFrame: record.frame)
            truthCount += truthBalls.count
            trackedCount += record.balls.count
            maxTruthBalls = max(maxTruthBalls, truthBalls.count)
            for ball in record.balls { ids.insert(ball.id) }

            for (truthIndex, trackIndex, distance) in Self.match(
                truth: truthBalls, tracked: record.balls, radius: truth.matchRadius) {
                matched += 1
                sumSquares += distance * distance
                maxError = max(maxError, distance)
                let id = record.balls[trackIndex].id
                if let previous = lastMatchedID[truthIndex], previous != id {
                    switches += 1
                }
                lastMatchedID[truthIndex] = id
            }
        }

        return AccuracyReport(
            evaluatedFrames: evaluated,
            truthBallFrames: truthCount,
            trackedBallFrames: trackedCount,
            matchedBallFrames: matched,
            positionRMS: matched > 0 ? (sumSquares / Double(matched)).squareRoot() : 0,
            maxPositionError: maxError,
            recall: truthCount > 0 ? Double(matched) / Double(truthCount) : 1,
            precision: trackedCount > 0 ? Double(matched) / Double(trackedCount) : 1,
            distinctTrackIDs: ids.count,
            identitySwitches: switches,
            trackChurn: max(0, ids.count - maxTruthBalls))
    }

    /// Greedy one-to-one matching, closest pair first; ties broken by
    /// truth index then track index.
    static func match(truth: [TruthBall], tracked: [OutputBall],
                      radius: Double) -> [(truthIndex: Int, trackIndex: Int, distance: Double)] {
        var pairs: [(truthIndex: Int, trackIndex: Int, distance: Double)] = []
        for (ti, truthBall) in truth.enumerated() {
            for (ki, ball) in tracked.enumerated() {
                let distance = truthBall.position.distance(to: ball.position)
                if distance <= radius { pairs.append((ti, ki, distance)) }
            }
        }
        pairs.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.truthIndex != b.truthIndex { return a.truthIndex < b.truthIndex }
            return a.trackIndex < b.trackIndex
        }
        var usedTruth = Set<Int>()
        var usedTrack = Set<Int>()
        var result: [(truthIndex: Int, trackIndex: Int, distance: Double)] = []
        for pair in pairs where !usedTruth.contains(pair.truthIndex)
            && !usedTrack.contains(pair.trackIndex) {
            usedTruth.insert(pair.truthIndex)
            usedTrack.insert(pair.trackIndex)
            result.append(pair)
        }
        return result
    }

    /// Canonical JSON (for committing a report next to its bundle).
    public func canonical() -> JSONValue {
        .object([
            "evaluatedFrames": .int(evaluatedFrames),
            "truthBallFrames": .int(truthBallFrames),
            "trackedBallFrames": .int(trackedBallFrames),
            "matchedBallFrames": .int(matchedBallFrames),
            "positionRMS": .double(positionRMS),
            "maxPositionError": .double(maxPositionError),
            "recall": .double(recall),
            "precision": .double(precision),
            "distinctTrackIDs": .int(distinctTrackIDs),
            "identitySwitches": .int(identitySwitches),
            "trackChurn": .int(trackChurn)
        ])
    }

    /// One-line human summary for test output and CI logs.
    public var summary: String {
        "frames=\(evaluatedFrames) rms=\(CanonicalJSON.formatFixed(positionRMS))m"
            + " max=\(CanonicalJSON.formatFixed(maxPositionError))m"
            + " recall=\(CanonicalJSON.formatFixed(recall))"
            + " precision=\(CanonicalJSON.formatFixed(precision))"
            + " ids=\(distinctTrackIDs) switches=\(identitySwitches) churn=\(trackChurn)"
    }
}
