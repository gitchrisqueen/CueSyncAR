//
//  StabilityReport.swift
//  SessionReplay
//
//  How STEADY the app's output is over a bundle, as distinct from how
//  ACCURATE it is (`AccuracyReport`, which needs ground truth).
//
//  It exists because the operator's report — "the guide lines move across
//  the screen in weird formations" — had no number attached to it, so no
//  change could be shown to have helped. Every metric here was chosen
//  because it separated two real recordings of the same table:
//
//    cue LYING on the cloth   stick accepted 99.2 % of frames, 0 source
//                             flips — a flat cue is a clean, fully visible
//                             box and it captures the aim completely
//    operator AIMING          stick accepted 53.8 %, 5.3 source flips/min
//
//  The gate accepts a discarded cue MORE reliably than one being aimed
//  with. That is the shape of the bug, and these are the numbers that will
//  show it fixed.
//
//  Pure and Linux-safe: it reads `OutputRecord`s and nothing else.
//

import Foundation

/// Steadiness metrics over one replayed bundle.
public struct StabilityReport: Sendable, Equatable {
    public var frames: Int
    public var seconds: Double
    /// Frames where the pipeline offered a stick footprint.
    public var stickPresentRate: Double
    /// Frames with an aim, and how that aim was sourced.
    public var aimedFrames: Int
    public var stickAimRate: Double
    /// Aim-source changes between consecutive aimed frames.
    public var sourceTransitions: Int
    public var sourceTransitionsPerMinute: Double
    /// Heading change between consecutive aimed frames that share a source
    /// AND whose aim origin barely moved — so this measures the guide
    /// twitching, not the cue ball being struck.
    public var headingDeltaP50: Double
    public var headingDeltaP95: Double
    public var headingDeltaMax: Double
    public var headingSamples: Int
    /// Re-solves, and how often the plan was dropped entirely.
    public var planChangedRate: Double
    public var planClearedRate: Double
    /// Drawn guide size. A long polyline is what turns a degree of aim
    /// noise into metres of movement at the far end.
    public var predictionLengthP95: Double
    public var predictionLengthMax: Double
    public var segmentCountP95: Int
    public var segmentCountMax: Int
    /// Predictions with no cushion and no pocket — a guide that just stops
    /// in open cloth, which reads as a bug whether or not it is one.
    public var predictionsWithoutCushionOrPocket: Int
    /// How far the LAST vertex of the polyline moves per re-solve. The
    /// deadband bounds the aim; this bounds what the user actually sees.
    public var farEndShiftP95: Double
    public var farEndShiftMax: Double
    /// Track identity churn: ids issued beyond the most balls ever held at
    /// once, and tracks that lived almost no time at all.
    public var distinctTrackIDs: Int
    public var maxConcurrentBalls: Int
    public var trackChurn: Int
    public var shortTracks: Int
    /// Times the cue ball's track id changed (ignoring frames with none) —
    /// every one of these teleports the aim origin to a different ball.
    public var cueIDChanges: Int

    public var summary: String {
        String(format: """
            stick present %.1f%% | stick aim %.1f%% | source flips %d (%.1f/min) \
            | heading d p95 %.2f max %.1f | planChanged %.1f%% | \
            segs p95 %d max %d | length p95 %.2f m | farEnd p95 %.2f m | \
            churn %d (%d ids, %d short) | cue id changes %d
            """,
            stickPresentRate * 100, stickAimRate * 100,
            sourceTransitions, sourceTransitionsPerMinute,
            headingDeltaP95, headingDeltaMax, planChangedRate * 100,
            segmentCountP95, segmentCountMax, predictionLengthP95,
            farEndShiftP95, trackChurn, distinctTrackIDs, shortTracks,
            cueIDChanges)
    }

    // MARK: - Computation

    /// Aim origins closer than this count as "the cue ball did not move",
    /// so a heading change between them is the guide twitching on its own.
    static let stillOriginMetres = 0.02
    /// A track alive for no more than this many frames is noise.
    static let shortTrackFrames = 5

    public static func compute(outputs: [OutputRecord]) -> StabilityReport {
        guard !outputs.isEmpty else { return .empty }
        let seconds = max(outputs.last!.timestamp - outputs.first!.timestamp, 0)

        let stickPresent = outputs.count { $0.stick != nil }
        let aimed = outputs.filter { $0.aim != nil }
        let stickAim = aimed.count { $0.aim?.source == "stick" }

        var transitions = 0
        var headings: [Double] = []
        for (a, b) in zip(aimed, aimed.dropFirst()) {
            guard let aa = a.aim, let ba = b.aim else { continue }
            if aa.source != ba.source { transitions += 1 }
            // Consecutive frames only: a gap means something else happened
            // in between, and the delta across it is not a twitch.
            guard b.frame == a.frame + 1, aa.source == ba.source else { continue }
            let moved = hypot(ba.originX - aa.originX, ba.originY - aa.originY)
            guard moved <= stillOriginMetres else { continue }
            let ha = atan2(aa.directionY, aa.directionX)
            let hb = atan2(ba.directionY, ba.directionX)
            headings.append(abs(wrapDegrees((hb - ha) * 180 / .pi)))
        }

        var lengths: [Double] = []
        var segCounts: [Int] = []
        var withoutTerminal = 0
        var farEndShifts: [Double] = []
        var lastFarEnd: [Double]?
        for record in outputs {
            guard let prediction = record.prediction else { continue }
            let length = prediction.segments.reduce(0.0) {
                $0 + hypot($1.endX - $1.startX, $1.endY - $1.startY)
            }
            lengths.append(length)
            segCounts.append(prediction.segments.count)
            let terminal = prediction.events.contains { $0.type == "cushion" || $0.type == "pocket" }
            if !terminal { withoutTerminal += 1 }
            if let last = prediction.segments.last {
                let end = [last.endX, last.endY]
                if record.planChanged, let previous = lastFarEnd {
                    farEndShifts.append(hypot(end[0] - previous[0], end[1] - previous[1]))
                }
                lastFarEnd = end
            }
        }

        // Track lifetimes and cue identity.
        var firstSeen: [Int: Int] = [:], lastSeen: [Int: Int] = [:]
        var maxConcurrent = 0
        var cueChanges = 0
        var lastCueID: Int?
        for record in outputs {
            maxConcurrent = max(maxConcurrent, record.balls.count)
            for ball in record.balls {
                if firstSeen[ball.id] == nil { firstSeen[ball.id] = record.frame }
                lastSeen[ball.id] = record.frame
            }
            if let cue = record.balls.first(where: { $0.kind == "cue" })?.id {
                if let last = lastCueID, last != cue { cueChanges += 1 }
                lastCueID = cue
            }
        }
        let short = firstSeen.keys.count {
            (lastSeen[$0] ?? 0) - (firstSeen[$0] ?? 0) <= shortTrackFrames
        }

        return StabilityReport(
            frames: outputs.count,
            seconds: seconds,
            stickPresentRate: ratio(stickPresent, outputs.count),
            aimedFrames: aimed.count,
            stickAimRate: ratio(stickAim, aimed.count),
            sourceTransitions: transitions,
            sourceTransitionsPerMinute: seconds > 0 ? Double(transitions) * 60 / seconds : 0,
            headingDeltaP50: percentile(headings, 0.50),
            headingDeltaP95: percentile(headings, 0.95),
            headingDeltaMax: headings.max() ?? 0,
            headingSamples: headings.count,
            planChangedRate: ratio(outputs.count { $0.planChanged }, outputs.count),
            planClearedRate: ratio(outputs.count { $0.prediction == nil }, outputs.count),
            predictionLengthP95: percentile(lengths, 0.95),
            predictionLengthMax: lengths.max() ?? 0,
            segmentCountP95: Int(percentile(segCounts.map(Double.init), 0.95)),
            segmentCountMax: segCounts.max() ?? 0,
            predictionsWithoutCushionOrPocket: withoutTerminal,
            farEndShiftP95: percentile(farEndShifts, 0.95),
            farEndShiftMax: farEndShifts.max() ?? 0,
            distinctTrackIDs: firstSeen.count,
            maxConcurrentBalls: maxConcurrent,
            trackChurn: max(firstSeen.count - maxConcurrent, 0),
            shortTracks: short,
            cueIDChanges: cueChanges)
    }

    static let empty = StabilityReport(
        frames: 0, seconds: 0, stickPresentRate: 0, aimedFrames: 0, stickAimRate: 0,
        sourceTransitions: 0, sourceTransitionsPerMinute: 0,
        headingDeltaP50: 0, headingDeltaP95: 0, headingDeltaMax: 0, headingSamples: 0,
        planChangedRate: 0, planClearedRate: 0,
        predictionLengthP95: 0, predictionLengthMax: 0,
        segmentCountP95: 0, segmentCountMax: 0, predictionsWithoutCushionOrPocket: 0,
        farEndShiftP95: 0, farEndShiftMax: 0,
        distinctTrackIDs: 0, maxConcurrentBalls: 0, trackChurn: 0, shortTracks: 0,
        cueIDChanges: 0)

    static func ratio(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) : 0
    }

    /// Nearest-rank percentile, so the result is always an observed value
    /// and never an interpolation between two of them.
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((q * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func wrapDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
