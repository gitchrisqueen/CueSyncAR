import CueSyncCore
import Foundation
import Testing
@testable import SessionReplay

@Suite("AccuracyReport")
struct AccuracyReportTests {
    private func record(frame: Int, balls: [(id: Int, x: Double, y: Double)]) -> OutputRecord {
        OutputRecord(frame: frame, timestamp: Double(frame),
                     balls: balls.map {
                         OutputBall(Ball(id: BallID($0.id), kind: .unknown,
                                         position: Vec2($0.x, $0.y), confidence: 0.9))
                     },
                     stick: nil, labels: [], aim: nil, prediction: nil,
                     planChanged: false, calledPocket: nil, calledShotOnLine: false)
    }

    private let truth = SessionTruth(matchRadius: 0.03, balls: [
        TruthBall(kind: "cue", x: 0, y: 0),
        TruthBall(kind: "unknown", x: 0.5, y: 0.2)
    ], method: "test")

    @Test func perfectTrackingScoresPerfectly() {
        let outputs = (0..<4).map {
            record(frame: $0, balls: [(0, 0, 0), (1, 0.5, 0.2)])
        }
        let report = AccuracyReport.compute(outputs: outputs, truth: truth)
        #expect(report.evaluatedFrames == 4)
        #expect(report.truthBallFrames == 8)
        #expect(report.matchedBallFrames == 8)
        #expect(report.positionRMS == 0)
        #expect(report.recall == 1)
        #expect(report.precision == 1)
        #expect(report.distinctTrackIDs == 2)
        #expect(report.identitySwitches == 0)
        #expect(report.trackChurn == 0)
    }

    @Test func rmsRecallAndPrecisionAreComputedOverMatchedPairs() {
        let outputs = [
            // Frame 0: cue 3 cm off (matches at the radius), object ball missed.
            record(frame: 0, balls: [(0, 0.03, 0)]),
            // Frame 1: both found, cue 4 mm off; plus a phantom far away.
            record(frame: 1, balls: [(0, 0, 0.004), (1, 0.5, 0.2), (9, -0.9, -0.4)])
        ]
        let report = AccuracyReport.compute(outputs: outputs, truth: truth)
        #expect(report.truthBallFrames == 4)
        #expect(report.matchedBallFrames == 3)
        #expect(report.trackedBallFrames == 4)
        #expect(abs(report.recall - 0.75) < 1e-12)
        #expect(abs(report.precision - 0.75) < 1e-12)
        let expectedRMS = ((0.03 * 0.03 + 0.004 * 0.004 + 0) / 3).squareRoot()
        #expect(abs(report.positionRMS - expectedRMS) < 1e-12)
        #expect(abs(report.maxPositionError - 0.03) < 1e-12)
        // Three ids ever seen, at most two truth balls → one churned track.
        #expect(report.distinctTrackIDs == 3)
        #expect(report.trackChurn == 1)
    }

    @Test func identitySwitchesCountTrackIDChangesPerTruthBall() {
        let outputs = [
            record(frame: 0, balls: [(0, 0, 0), (1, 0.5, 0.2)]),
            record(frame: 1, balls: [(0, 0, 0), (1, 0.5, 0.2)]),
            // The object ball comes back under a new id.
            record(frame: 2, balls: [(0, 0, 0), (2, 0.5, 0.2)]),
            record(frame: 3, balls: [(0, 0, 0), (2, 0.5, 0.2)])
        ]
        let report = AccuracyReport.compute(outputs: outputs, truth: truth)
        #expect(report.identitySwitches == 1)
        #expect(report.trackChurn == 1)
    }

    @Test func warmupFramesAreSkipped() {
        let outputs = [
            record(frame: 0, balls: []),
            record(frame: 1, balls: []),
            record(frame: 2, balls: [(0, 0, 0), (1, 0.5, 0.2)])
        ]
        let all = AccuracyReport.compute(outputs: outputs, truth: truth)
        #expect(abs(all.recall - 1.0 / 3.0) < 1e-12)
        let warmed = AccuracyReport.compute(outputs: outputs, truth: truth, warmupFrames: 2)
        #expect(warmed.evaluatedFrames == 1)
        #expect(warmed.recall == 1)
    }

    @Test func perFrameTruthOverridesTheStaticLayout() {
        var moving = truth
        moving.frames = [TruthFrame(frame: 1, balls: [TruthBall(kind: "cue", x: 0.1, y: 0)])]
        let outputs = [
            record(frame: 0, balls: [(0, 0, 0), (1, 0.5, 0.2)]),
            record(frame: 1, balls: [(0, 0.1, 0)])
        ]
        let report = AccuracyReport.compute(outputs: outputs, truth: moving)
        #expect(report.truthBallFrames == 3)
        #expect(report.matchedBallFrames == 3)
        #expect(report.recall == 1)
    }

    @Test func matchingIsOneToOneClosestFirstWithDeterministicTies() {
        // Two truth balls, one tracked ball exactly between them: it may
        // match only one, and the tie goes to the lower truth index.
        let between = SessionTruth(matchRadius: 0.05, balls: [
            TruthBall(kind: "a", x: -0.02, y: 0), TruthBall(kind: "b", x: 0.02, y: 0)
        ], method: "test")
        let matches = AccuracyReport.match(
            truth: between.balls,
            tracked: [OutputBall(Ball(id: BallID(5), kind: .unknown, position: .zero))],
            radius: 0.05)
        #expect(matches.count == 1)
        #expect(matches[0].truthIndex == 0)
        #expect(matches[0].trackIndex == 0)
    }

    @Test func emptyInputsAreWellDefined() {
        let report = AccuracyReport.compute(outputs: [], truth: truth)
        #expect(report.evaluatedFrames == 0)
        #expect(report.recall == 1)
        #expect(report.precision == 1)
        #expect(report.positionRMS == 0)
        #expect(report.summary.contains("frames=0"))
        #expect(CanonicalJSON.serialize(report.canonical()).contains("\"recall\":1.000000"))
    }
}
