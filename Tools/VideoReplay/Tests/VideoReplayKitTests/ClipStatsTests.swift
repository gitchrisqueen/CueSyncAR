//
//  ClipStatsTests.swift
//  CueSync AR
//
//  Selection-flicker accounting and percentages over hand-built frame results.
//

import CoachKit
import CoreGraphics
import CueSyncCore
import Testing
@testable import VideoReplayKit

@Suite struct ClipStatsTests {
    /// Two real planner options from a synthetic layout (cue ball + two targets).
    private func twoOptions() throws -> (ShotOption, ShotOption) {
        let balls = [
            Ball(id: BallID(0), kind: .cue, position: Vec2(-0.5, 0)),
            Ball(id: BallID(1), kind: .solid(1), position: Vec2(0.3, 0.3)),
            Ball(id: BallID(2), kind: .solid(2), position: Vec2(0.4, -0.3)),
        ]
        let state = TableState(table: Table(size: .nineFoot), balls: balls)
        let options = ShotPlanner.plan(state: state)
        let first = try #require(options.first)
        let second = try #require(options.first { $0.id != first.id })
        return (first, second)
    }

    private func frame(_ index: Int, cue: CueStatus = .ok, selected: ShotOption? = nil,
                       sticks: Int = 0) -> FrameResult {
        FrameResult(index: index, imageSize: CGSize(width: 100, height: 100), detections: [],
                    usedObservations: 3, cueObservations: cue.isOK ? 1 : 0, rejectedOffTable: 0,
                    scaleRatios: [1.0, 1.2, 1.4], tracked: [], cueStatus: cue,
                    stickDetections: sticks, stickOnTable: false,
                    options: selected.map { [$0] } ?? [], selected: selected)
    }

    @Test func countsSwapsAndDropoutsSeparately() throws {
        let (first, second) = try twoOptions()
        // A A B none B: one swap (A->B), two dropouts (B->none, none->B).
        let results = [frame(0, selected: first), frame(1, selected: first), frame(2, selected: second),
                       frame(3, cue: .missing), frame(4, selected: second)]
        let stats = ClipStats.summarize(results)
        #expect(stats.swaps == 1)
        #expect(stats.dropouts == 2)
        #expect(stats.changesPer10Frames == 7.5)
        #expect(stats.cueFramePercent == 80)
        #expect(stats.viableShotFramePercent == 80)
        #expect(stats.medianScaleRatio == 1.2)
        #expect(stats.perFrame.map(\.frame) == [1, 2, 3, 4, 5])
    }

    @Test func emptyInputIsAllZeros() {
        let stats = ClipStats.summarize([])
        #expect(stats.frames == 0)
        #expect(stats.changesPer10Frames == 0)
    }

    @Test func countsAmbiguousCueAndSticks() {
        let results = [frame(0, cue: .ambiguous(2), sticks: 1), frame(1, cue: .missing)]
        let stats = ClipStats.summarize(results)
        #expect(stats.ambiguousCueFrames == 1)
        #expect(stats.stickFramePercent == 50)
    }
}
