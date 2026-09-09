import CueSyncCore
import Foundation
import PerceptionKit
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

    /// B3 under replay: a bundle carrying the lock-time anchor and per-frame
    /// anchor transforms is re-derived each frame exactly as live; a moving
    /// anchor therefore moves the tracked balls, and the manifest's
    /// `followsTableAnchor: false` (or a config with it off) pins them.
    @Test func recordedAnchorTransformsAreFollowedUnderReplay() async throws {
        var bundle = ScriptedFiveBall.makeBundle()
        let pinned = try await ReplayRunner().run(bundle)

        bundle.calibration = RecordedCalibration(ScriptedFiveBall.calibration,
                                                 anchorTransform: .identity)
        var drifted = Transform3D.identity
        drifted.columns[3] = SIMD4(0.05, 0, 0, 1) // anchor moved 5 cm along world x
        for index in bundle.frames.indices {
            let transform = index >= 20 ? drifted : Transform3D.identity
            bundle.frames[index].tableAnchorTransform = transform.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        let followed = try await ReplayRunner().run(bundle)
        #expect(followed.outputsText != pinned.outputsText)
        #expect(followed.droppedFrames.isEmpty)
        // Before the drift the two replays agree line for line; after it
        // the followed calibration's origin has moved, so table-space
        // positions shift by ~5 cm along the table's x axis (world x).
        let pinnedLines = pinned.outputsText.split(separator: "\n")
        let followedLines = followed.outputsText.split(separator: "\n")
        #expect(Array(pinnedLines[..<20]) == Array(followedLines[..<20]))
        #expect(pinnedLines[30] != followedLines[30])
        let pinnedBall = try #require(pinned.outputs[30].balls.min { $0.id < $1.id })
        let followedBall = try #require(followed.outputs[30].balls.min { $0.id < $1.id })
        let dx = followedBall.x - pinnedBall.x
        #expect(abs(abs(dx) - 0.05) < 0.02, "shift \(dx)")

        // Config OFF pins it again; a manifest that says OFF overrides config ON.
        let off = ReplayConfig(perception: PerceptionConfig(followsTableAnchor: false))
        #expect(try await ReplayRunner(config: off).run(bundle).outputsText == pinned.outputsText)
        bundle.manifest.recording = RecordingInfo(
            appCommit: "x", appBranch: "y", appDirty: false, appVersion: "1", detector: "on-device",
            hardwareModel: "test", systemVersion: "0", displayScale: 1, viewWidth: 1, viewHeight: 1,
            nativeWidth: 1920, nativeHeight: 1440, tickMilliseconds: 150, snapshotIntervalSeconds: 1,
            capSeconds: 300, durationSeconds: 4.4, videoFrames: 0, videoDroppedFrames: 0,
            guideSpeed: 3.5, visibleMissGrace: 0.75, practiceMode: "freePlay",
            metricPalette: false, followsTableAnchor: false, stopReason: "user")
        #expect(try await ReplayRunner().run(bundle).outputsText == pinned.outputsText)
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
        // frame 23 under fresh ids. The called pocket is gone.
        #expect(try output(20).balls.isEmpty)
        #expect(try output(20).aim == nil)
        #expect(try output(20).calledPocket == nil)
        #expect(try output(22).balls.isEmpty)
        #expect(try output(23).balls.count == 5)
        #expect(try output(23).balls.map(\.id).min() ?? 0 == 0)
        // The cue ball, however, comes BACK. The ids are new; the balls
        // never moved. Making the user re-tap after every reset was the
        // old behaviour and it is what this test used to lock in.
        #expect(try output(23).balls.contains { $0.kind == "cue" })
        #expect(try output(23).aim != nil)
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
        // The second tap clears the MARK, but the ball is still the cue
        // ball: the app keeps following the track it was told about until
        // something better comes along. Clearing the mark is not the same
        // as declaring there is no cue ball on the table.
        #expect(try output(10).balls.contains { $0.kind == "cue" })
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
        var session = makeSession()
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: BallID(1), kind: .cue, position: .zero),
            Ball(id: BallID(2), kind: .unknown, position: Vec2(0.5, 0))
        ])
        // A tap on ball 2 moves the mark, and demotes ball 1's own claim
        // so exactly one cue ball exists.
        var designated = session
        designated.cueIdentity.toggle(near: Vec2(0.5, 0), in: state, maxDistance: 0.4)
        #expect(designated.cueIdentity.apply(to: state).balls.map(\.kind) == [.unknown, .cue])

        // With no tap, the detector's own claim is adopted and kept — the
        // state it produces is already correct, so it is unchanged.
        #expect(session.cueIdentity.apply(to: state) == state)
    }

    @Test func theCueBallSurvivesTheDetectorLosingItsLabel() {
        var session = makeSession()
        let table = Table(size: .eightFoot)
        // Frame 0: the detector calls ball 1 the cue ball.
        let seen = TableState(table: table, balls: [
            Ball(id: BallID(1), kind: .cue, position: .zero),
            Ball(id: BallID(2), kind: .unknown, position: Vec2(0.5, 0))
        ], timestamp: 0)
        _ = session.cueIdentity.apply(to: seen)

        // Frame 1: it does not. Nothing about the TRACK changed, so the
        // identity must not either — this is the case that left 49 % of a
        // real aiming recording with no cue ball and therefore no guide.
        let lost = TableState(table: table, balls: [
            Ball(id: BallID(1), kind: .unknown, position: Vec2(0.01, 0)),
            Ball(id: BallID(2), kind: .unknown, position: Vec2(0.5, 0))
        ], timestamp: 0.2)
        let held = session.cueIdentity.apply(to: lost)
        #expect(held.cueBall?.id == BallID(1))
    }

    @Test func theCueBallIsReadoptedInPlaceAfterATrackingReset() {
        var session = makeSession()
        let table = Table(size: .eightFoot)
        let before = TableState(table: table, balls: [
            Ball(id: BallID(1), kind: .cue, position: Vec2(-0.6, 0.05))
        ], timestamp: 0)
        _ = session.cueIdentity.apply(to: before)

        session.cueIdentity.trackingReset(at: 1.0)
        // Fresh ids, same felt: the ball has not moved, so the user should
        // not have to tap it again.
        let after = TableState(table: table, balls: [
            Ball(id: BallID(7), kind: .unknown, position: Vec2(-0.61, 0.05))
        ], timestamp: 1.2)
        #expect(session.cueIdentity.apply(to: after).cueBall?.id == BallID(7))
    }

    private func makeSession() -> ReplaySession {
        ReplaySession(config: .default,
                      calibration: ScriptedFiveBall.calibration,
                      detector: RecordedDetectionProvider(detections: []))
    }
}
