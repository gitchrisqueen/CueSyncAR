//
//  StabilityReportTests.swift
//  SessionReplayTests
//
//  The report has to separate a steady guide from a twitching one, and it
//  has to do it on the shapes real bundles produce — a source that flips,
//  a track that dies and is reborn, a polyline that stops in open cloth.
//

import Foundation
import Testing
@testable import SessionReplay

@Suite("Stability report")
struct StabilityReportTests {
    private func aim(_ source: String, headingDegrees: Double,
                     origin: (Double, Double) = (0, 0)) -> OutputAim {
        let radians = headingDegrees * .pi / 180
        return OutputAim(source: source, originX: origin.0, originY: origin.1,
                         directionX: cos(radians), directionY: sin(radians))
    }

    private func record(_ frame: Int, aim: OutputAim? = nil, planChanged: Bool = false,
                        balls: [OutputBall] = [], stick: Bool = false,
                        prediction: OutputPrediction? = nil) -> OutputRecord {
        OutputRecord(frame: frame, timestamp: Double(frame) * 0.1, balls: balls,
                     stick: stick ? [[0, 0], [1, 0], [1, 1], [0, 1]] : nil,
                     labels: [], aim: aim, prediction: prediction,
                     planChanged: planChanged, calledPocket: nil,
                     calledShotOnLine: false)
    }

    private func ball(_ id: Int, _ kind: String = "unknown") -> OutputBall {
        OutputBall(id: id, kind: kind, x: 0, y: 0, radius: 0.028575, confidence: 0.9)
    }

    @Test("An empty run reports zeroes rather than dividing by zero")
    func emptyIsSafe() {
        let report = StabilityReport.compute(outputs: [])
        #expect(report.frames == 0)
        #expect(report.stickPresentRate == 0)
        #expect(report.sourceTransitionsPerMinute == 0)
    }

    @Test("A steady stick aim has no transitions and no heading movement")
    func steadyAimIsQuiet() {
        let outputs = (0..<20).map { record($0, aim: aim("stick", headingDegrees: 30), stick: true) }
        let report = StabilityReport.compute(outputs: outputs)
        #expect(report.sourceTransitions == 0)
        #expect(report.headingDeltaMax == 0)
        #expect(abs(report.stickAimRate - 1) < 1e-12)
        #expect(abs(report.stickPresentRate - 1) < 1e-12)
    }

    @Test("Source flapping is counted, and per-minute is time-normalised")
    func flappingIsCounted() {
        // 10 frames at 0.1 s = 0.9 s span, alternating every frame.
        let outputs = (0..<10).map {
            record($0, aim: aim($0.isMultiple(of: 2) ? "stick" : "devicePose",
                                headingDegrees: 0))
        }
        let report = StabilityReport.compute(outputs: outputs)
        #expect(report.sourceTransitions == 9)
        #expect(report.sourceTransitionsPerMinute > 500) // 9 flips in 0.9 s
    }

    @Test("Heading deltas ignore frames where the cue ball moved")
    func headingIgnoresAStruckBall() {
        // A 40 degree swing, but the origin jumped 30 cm — that is the ball
        // being hit, not the guide twitching, and must not be counted.
        let outputs = [
            record(0, aim: aim("stick", headingDegrees: 0, origin: (0, 0))),
            record(1, aim: aim("stick", headingDegrees: 40, origin: (0.30, 0)))
        ]
        let report = StabilityReport.compute(outputs: outputs)
        #expect(report.headingSamples == 0)
        #expect(report.headingDeltaMax == 0)

        // Same swing with the origin still IS counted.
        let still = [
            record(0, aim: aim("stick", headingDegrees: 0)),
            record(1, aim: aim("stick", headingDegrees: 40))
        ]
        let stillReport = StabilityReport.compute(outputs: still)
        #expect(stillReport.headingSamples == 1)
        #expect(abs(stillReport.headingDeltaMax - 40) < 1e-9)
    }

    @Test("Heading wrap does not manufacture a 350 degree jump")
    func headingWraps() {
        let outputs = [
            record(0, aim: aim("stick", headingDegrees: 179)),
            record(1, aim: aim("stick", headingDegrees: -179))
        ]
        let report = StabilityReport.compute(outputs: outputs)
        #expect(abs(report.headingDeltaMax - 2) < 1e-9)
    }

    @Test("Track churn counts ids beyond the most balls ever held")
    func churnCountsRebirths() {
        // Two balls on the table throughout, but the second one dies and is
        // reborn with a new id twice: 4 ids, 2 concurrent, churn 2.
        let outputs = [
            record(0, balls: [ball(0), ball(1)]),
            record(1, balls: [ball(0), ball(1)]),
            record(2, balls: [ball(0), ball(2)]),
            record(3, balls: [ball(0), ball(2)]),
            record(4, balls: [ball(0), ball(3)]),
            record(5, balls: [ball(0), ball(3)])
        ]
        let report = StabilityReport.compute(outputs: outputs)
        #expect(report.distinctTrackIDs == 4)
        #expect(report.maxConcurrentBalls == 2)
        #expect(report.trackChurn == 2)
    }

    @Test("Cue identity changes are counted across a gap with no cue")
    func cueIdentityChanges() {
        let outputs = [
            record(0, balls: [ball(0, "cue")]),
            record(1, balls: [ball(0, "cue")]),
            record(2, balls: [ball(1)]),            // cue lost entirely
            record(3, balls: [ball(2, "cue")]),      // reborn under a new id
            record(4, balls: [ball(2, "cue")])
        ]
        let report = StabilityReport.compute(outputs: outputs)
        #expect(report.cueIDChanges == 1)
    }
}
