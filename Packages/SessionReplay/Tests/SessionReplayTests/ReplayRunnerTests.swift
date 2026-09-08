import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import SessionReplay

@Suite("ReplayRunner")
struct ReplayRunnerTests {
    @Test func replaysTheScriptedBundleWithoutDrops() async throws {
        let result = try await ReplayRunner().run(ScriptedFiveBall.makeBundle())
        #expect(result.outputs.count == ScriptedFiveBall.frameCount)
        #expect(result.droppedFrames.isEmpty)
        #expect(result.outputs.map(\.frame) == Array(0..<ScriptedFiveBall.frameCount))
        #expect(result.outputsText.hasSuffix("\n"))
        #expect(result.outputsText.split(separator: "\n").count == ScriptedFiveBall.frameCount)
    }

    @Test func framesWithoutDetectionsAreDroppedAndReported() async throws {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.detections.removeAll { $0.frame == 7 || $0.frame == 21 }
        let result = try await ReplayRunner().run(bundle)
        #expect(result.droppedFrames == [7, 21])
        #expect(result.outputs.count == ScriptedFiveBall.frameCount - 2)
        #expect(!result.outputs.contains { $0.frame == 7 })
    }

    @Test func invalidBundlesAreRejectedBeforeReplay() async {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.manifest.frameCount = 1
        await #expect(throws: SessionBundleError.frameCountMismatch(manifest: 1, frames: 45)) {
            try await ReplayRunner().run(bundle)
        }
    }

    @Test func resetTrackingEventStartsTheTrackerOver() async throws {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.events.append(RecordedEvent(frame: 20, timestamp: ScriptedFiveBall.timestamp(20),
                                           kind: .resetTracking))
        let outputs = try await ReplayRunner().run(bundle).outputs
        func output(_ frame: Int) throws -> OutputRecord {
            try #require(outputs.first { $0.frame == frame })
        }
        #expect(try output(19).balls.count == 5)
        // The reset frame reports nothing; the fresh pipeline sees frames
        // 21+ and the 3-frame appearance gate confirms the layout again at
        // frame 23 under fresh ids; designation and the called pocket are gone.
        #expect(try output(20).balls.isEmpty)
        #expect(try output(20).aim == nil)
        #expect(try output(20).calledPocket == nil)
        #expect(try output(22).balls.isEmpty)
        #expect(try output(23).balls.count == 5)
        #expect(try output(23).balls.allSatisfy { $0.kind == "unknown" })
        #expect(try output(23).balls.map(\.id).min() ?? 0 == 0)
        #expect(try output(23).aim == nil)
    }

    @Test func designationTogglesAndRespectsTheDistanceLimit() async throws {
        var bundle = ScriptedFiveBall.makeBundle()
        // A tap far from every ball is ignored; a second tap on the
        // designated ball clears the designation again.
        bundle.events.append(RecordedEvent(frame: 8, timestamp: ScriptedFiveBall.timestamp(8),
                                           kind: .designateCueBall, x: 1.0, y: -0.5))
        bundle.events.append(RecordedEvent(frame: 10, timestamp: ScriptedFiveBall.timestamp(10),
                                           kind: .designateCueBall,
                                           x: ScriptedFiveBall.designateTap.x,
                                           y: ScriptedFiveBall.designateTap.y))
        let outputs = try await ReplayRunner().run(bundle).outputs
        func output(_ frame: Int) throws -> OutputRecord {
            try #require(outputs.first { $0.frame == frame })
        }
        #expect(try output(9).balls.contains { $0.kind == "cue" })
        #expect(try output(10).balls.allSatisfy { $0.kind == "unknown" })
        #expect(try output(10).aim == nil)
    }

    @Test func calledPocketTogglesOffOnASecondCall() async throws {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.events.append(RecordedEvent(frame: 25, timestamp: ScriptedFiveBall.timestamp(25),
                                           kind: .callPocket,
                                           pocket: ScriptedFiveBall.calledPocket.rawValue))
        let outputs = try await ReplayRunner().run(bundle).outputs
        #expect(outputs.first { $0.frame == 24 }?.calledPocket == "cornerTopRight")
        #expect(outputs.first { $0.frame == 25 }?.calledPocket == nil)
    }

    @Test func configurationChangesTheOutcome() async throws {
        // A different guide speed must change predictions but nothing else
        // — proves the config is actually wired through to the solver.
        let bundle = ScriptedFiveBall.makeBundle()
        let slow = try await ReplayRunner(config: ReplayConfig(guideSpeed: 1.0)).run(bundle)
        let fast = try await ReplayRunner(config: ReplayConfig(guideSpeed: 3.5)).run(bundle)
        #expect(slow.outputs.map(\.balls) == fast.outputs.map(\.balls))
        #expect(slow.outputs.map(\.aim) == fast.outputs.map(\.aim))
        #expect(slow.outputs.map(\.prediction) != fast.outputs.map(\.prediction))
    }

    @Test func cueDesignationDemotesOtherCueClaims() {
        let session = makeSession()
        var designated = session
        designated.designatedCueBallID = BallID(2)
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: BallID(1), kind: .cue, position: .zero),
            Ball(id: BallID(2), kind: .unknown, position: Vec2(0.5, 0))
        ])
        let adjusted = designated.applyingCueDesignation(state)
        #expect(adjusted.balls.map(\.kind) == [.unknown, .cue])
        // No designation, or a designated id that is not tracked: untouched.
        #expect(session.applyingCueDesignation(state) == state)
        designated.designatedCueBallID = BallID(9)
        #expect(designated.applyingCueDesignation(state) == state)
    }

    private func makeSession() -> ReplaySession {
        ReplaySession(config: .default,
                      calibration: ScriptedFiveBall.calibration,
                      detector: RecordedDetectionProvider(detections: []))
    }
}
