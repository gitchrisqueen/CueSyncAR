//
//  ClipStats.swift
//  CueSync AR
//
//  Per-clip numbers for the findings write-up. Selection flicker is counted
//  between consecutive processed frames: `swaps` is id -> different id, and
//  `dropouts` is a selection appearing or vanishing.
//

import Foundation

public struct ClipStats: Codable, Sendable {
    public var frames = 0
    public var meanDetections = 0.0
    public var meanBallObservations = 0.0
    public var meanTrackedBalls = 0.0
    public var cueFramePercent = 0.0
    public var ambiguousCueFrames = 0
    public var viableShotFramePercent = 0.0
    public var swaps = 0
    public var dropouts = 0
    public var changesPer10Frames = 0.0
    public var stickFramePercent = 0.0
    public var stickOnTableFramePercent = 0.0
    public var rejectedOffTable = 0
    public var cueObservationFramePercent = 0.0
    /// Median of detector-box width / predicted ball diameter (see FrameResult).
    public var medianScaleRatio = 0.0
    /// Selected option id per frame ("" when none), for flicker inspection.
    public var selectionTimeline: [String] = []
    /// One line per frame so findings can cite frame numbers.
    public var perFrame: [FrameLine] = []

    public struct FrameLine: Codable, Sendable {
        public var frame: Int
        public var detections: Int
        /// `white-ball` boxes that passed the confidence and on-table gates.
        public var cueObservations: Int
        public var observations: Int
        public var tracked: Int
        public var cue: String
        public var shots: Int
        public var selected: String
        public var sticks: Int
    }

    public init() {}

    public static func summarize(_ results: [FrameResult]) -> ClipStats {
        var stats = ClipStats()
        let count = Double(results.count)
        guard count > 0 else { return stats }
        stats.frames = results.count
        stats.meanDetections = Double(results.map(\.detections.count).reduce(0, +)) / count
        stats.meanBallObservations = Double(results.map(\.usedObservations).reduce(0, +)) / count
        stats.meanTrackedBalls = Double(results.map(\.tracked.count).reduce(0, +)) / count
        stats.cueFramePercent = percent(results.filter { $0.cueStatus.isOK }.count, of: count)
        stats.ambiguousCueFrames = results.filter {
            if case .ambiguous = $0.cueStatus { return true }
            return false
        }.count
        stats.viableShotFramePercent = percent(results.filter { !$0.options.isEmpty }.count, of: count)
        stats.stickFramePercent = percent(results.filter { $0.stickDetections > 0 }.count, of: count)
        stats.stickOnTableFramePercent = percent(results.filter(\.stickOnTable).count, of: count)
        stats.rejectedOffTable = results.map(\.rejectedOffTable).reduce(0, +)
        stats.cueObservationFramePercent = percent(results.filter { $0.cueObservations > 0 }.count, of: count)
        let ratios = results.flatMap(\.scaleRatios).sorted()
        stats.medianScaleRatio = ratios.isEmpty ? 0 : ratios[ratios.count / 2]

        stats.perFrame = results.map { result in
            FrameLine(frame: result.index + 1, detections: result.detections.count,
                      cueObservations: result.cueObservations,
                      observations: result.usedObservations, tracked: result.tracked.count,
                      cue: String(describing: result.cueStatus), shots: result.options.count,
                      selected: result.selected?.id ?? "", sticks: result.stickDetections)
        }
        stats.selectionTimeline = results.map { $0.selected?.id ?? "" }
        for pair in zip(stats.selectionTimeline, stats.selectionTimeline.dropFirst()) where pair.0 != pair.1 {
            if pair.0.isEmpty || pair.1.isEmpty { stats.dropouts += 1 } else { stats.swaps += 1 }
        }
        let transitions = Double(max(1, results.count - 1))
        stats.changesPer10Frames = Double(stats.swaps + stats.dropouts) / transitions * 10
        return stats
    }

    private static func percent(_ part: Int, of total: Double) -> Double {
        Double(part) / total * 100
    }

    /// One-line-per-metric text block for stdout and the findings file.
    public var report: String {
        func format(_ value: Double) -> String { String(format: "%.1f", value) }
        return """
        frames processed:            \(frames)
        mean detections (>=0.25):    \(format(meanDetections))
        mean ball observations used: \(format(meanBallObservations))
        mean tracked (confirmed):    \(format(meanTrackedBalls))
        frames with a white-ball box: \(format(cueObservationFramePercent))% (passed floor + on-table gate)
        frames with one cue ball:    \(format(cueFramePercent))% (ambiguous: \(ambiguousCueFrames))
        frames with >=1 viable shot: \(format(viableShotFramePercent))%
        selection swaps / dropouts:  \(swaps) / \(dropouts)
        selection changes per 10:    \(format(changesPer10Frames))
        frames with stick (>=0.3):   \(format(stickFramePercent))% (on table: \(format(stickOnTableFramePercent))%)
        observations off table:      \(rejectedOffTable)
        median box/ball-size ratio:  \(String(format: "%.2f", medianScaleRatio)) (~1.0-1.3 = calibration scale plausible)
        """
    }
}
