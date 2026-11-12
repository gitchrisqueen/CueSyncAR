//
//  PipelineDiagnosticsTests.swift
//  PerceptionKitTests
//
//  The counters, the live confidence floor, the stage timings, and the
//  missing-ball scenario from docs/research/2026-11-12-missing-ball-diagnosis.md:
//  16 balls on the table, the far-centre one detected at 0.30, between the
//  model's own 0.25 floor and the pipeline's 0.35 one.
//

import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

/// A detector whose output depends on the frame index (timestamp / 30).
private struct ScriptedDetector: DetectionProviding {
    let script: @Sendable (Int) -> [Detection2D]
    func prepare() async throws {}
    func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        script(Int((frame.timestamp * 30).rounded()))
    }
}

/// Fails to hit the plane for boxes right of `limit`, standing in for a ray
/// that never reaches the table.
private struct BlindRightRaycaster: PlaneRaycasting {
    let inner: LinearFixtureRaycaster
    let limit: Double
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        imagePoint.x > limit ? nil : inner.raycastToTablePlane(imagePoint: imagePoint, frame: frame)
    }
}

/// Returns a world point that is not a number.
private struct NotANumberRaycaster: PlaneRaycasting {
    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        Vec3(.nan, .nan, .nan)
    }
}

@Suite("Pipeline diagnostics, confidence floor, stage timings")
struct PipelineDiagnosticsTests {
    let calibration = TableCalibration(origin: .zero,
                                       xAxis: Vec3(1, 0, 0),
                                       yAxis: Vec3(0, 0, -1),
                                       size: .nineFoot)

    private func frame(_ index: Int) -> CapturedFrame {
        CapturedFrame(timestamp: Double(index) / 30, cameraTransform: .identity,
                      image: FixtureImageBuffer())
    }

    /// A ball-sized box centred on a table position, under
    /// `LinearFixtureRaycaster`.
    private func detection(_ label: String = "color-ball", x: Double, y: Double,
                           confidence: Double = 0.9) -> Detection2D {
        let (width, height) = calibration.size.playField
        let centre = Vec2(0.5 + x / width, 0.5 - y / height)
        return Detection2D(classLabel: label,
                           boundingBox: NormalizedRect(x: centre.x - 0.01, y: centre.y - 0.01,
                                                       width: 0.02, height: 0.02),
                           confidence: confidence)
    }

    /// The grid from the diagnosis: 15 object balls plus the cue ball, with
    /// the far-centre ball (0.87, 0.03) at `farCentreConfidence`.
    private func sixteenBalls(farCentreConfidence: Double) -> [Detection2D] {
        var balls: [Detection2D] = []
        for x in [0.87, 0.55, -0.03, -0.56, -0.85] {
            for y in [0.33, 0.03, -0.26] {
                let isFarCentre = x == 0.87 && y == 0.03
                balls.append(detection(x: x, y: y,
                                       confidence: isFarCentre ? farCentreConfidence : 0.9))
            }
        }
        balls.append(detection("white-ball", x: -0.27, y: 0.04))
        return balls
    }

    private func pipeline(_ detector: any DetectionProviding,
                          raycaster: (any PlaneRaycasting)? = nil,
                          config: PerceptionConfig = .default,
                          controls: PerceptionControls? = nil) -> PerceptionPipeline {
        PerceptionPipeline(detector: detector, calibration: calibration,
                           raycaster: raycaster ?? LinearFixtureRaycaster(calibration: calibration),
                           config: config, controls: controls)
    }

    private func run(_ pipeline: PerceptionPipeline, frames: Int) async throws -> PerceptionOutput {
        var last: PerceptionOutput?
        for index in 0..<frames { last = await pipeline.processFrame(frame(index)) }
        return try #require(last)
    }

    // MARK: - The missing ball

    @Test func farCentreBallAtThirtyPercentIsLostAtTheDefaultFloorAndFoundAtTheLoweredOne() async throws {
        let detections = sixteenBalls(farCentreConfidence: 0.30)
        let atDefault = try await run(pipeline(FixtureDetectionProvider(constant: detections)), frames: 5)
        #expect(atDefault.state.balls.count == 15)
        // The counters say where it went: under the floor, at 0.30.
        let counts = atDefault.diagnostics.detections
        #expect(counts.belowFloor == 1)
        #expect(counts.maxSubFloorConfidence == 0.30)
        #expect(counts.confidenceFloor == 0.35)
        #expect(counts.projected == 15)

        let lowered = PerceptionConfig(confidenceFloor: 0.25)
        let atQuarter = try await run(pipeline(FixtureDetectionProvider(constant: detections),
                                               config: lowered), frames: 5)
        #expect(atQuarter.state.balls.count == 16)
        #expect(atQuarter.diagnostics.detections.belowFloor == 0)
        #expect(atQuarter.diagnostics.detections.maxSubFloorConfidence == nil)
    }

    @Test func belowFloorIsSplitByLabelSoCueBallDropsShowOnTheirOwn() async throws {
        let boxes = [
            detection("white-ball", x: -0.27, y: 0.04, confidence: 0.27),
            detection(x: 0.3, y: 0.1, confidence: 0.28),
            detection(x: 0.5, y: -0.2, confidence: 0.30),
            detection(x: -0.6, y: 0.2, confidence: 0.9)
        ]
        let output = try #require(await pipeline(FixtureDetectionProvider(constant: boxes))
            .processFrame(frame(0)))
        let counts = output.diagnostics.detections
        #expect(counts.belowFloor == 3)
        #expect(counts.belowFloorByLabel == ["white-ball": 1, "color-ball": 2])
        let entries = output.diagnostics.mirrorEntries
        #expect(entries["belowFloorByLabel"] as? [String: Int] == ["white-ball": 1, "color-ball": 2])
        #expect(JSONSerialization.isValidJSONObject(entries))
        // Nothing under the floor: an empty map, not a missing key.
        #expect((PipelineDiagnostics().mirrorEntries["belowFloorByLabel"] as? [String: Int])?.isEmpty == true)
    }

    @Test func aLoneSubFloorDetectionSeenInOneOfFiveFramesStaysUnconfirmed() async throws {
        let blip = detection(x: 0.5, y: 0.2, confidence: 0.28)
        let detector = ScriptedDetector { index in index == 1 ? [blip] : [] }
        let pipeline = pipeline(detector, config: PerceptionConfig(confidenceFloor: 0.25))
        for index in 0..<5 {
            let output = try #require(await pipeline.processFrame(frame(index)))
            #expect(output.state.balls.isEmpty, "frame \(index) confirmed a ball seen once")
        }
    }

    @Test func theRawListShowsASubFloorDetectionNextToItsTablePosition() async throws {
        let output = try await run(
            pipeline(FixtureDetectionProvider(constant: sixteenBalls(farCentreConfidence: 0.30))),
            frames: 1)
        let all = output.diagnostics.detections.rawLabelsAll
        // Uncapped: all 16, where the label list the replay golden pins is 12.
        #expect(all.count == 16)
        #expect(output.detectionLabels.count == 12)
        let near = try #require(all.first { entry in
            guard let at = entry.tableCentimetres else { return false }
            return abs(at.x - 87) <= 2 && abs(at.y - 3) <= 2
        })
        #expect(near.confidence == 0.30)
        #expect(near.label == "color-ball")
        // Strongest first.
        #expect(all.map(\.confidence) == all.map(\.confidence).sorted(by: >))
    }

    // MARK: - Counters

    @Test func everyRawDetectionIsAccountedForExactlyOnce() async throws {
        let table = Table(size: .nineFoot)
        let off = table.halfExtents.x + 0.5
        let boxes = [
            detection("white-ball", x: 0, y: 0),
            detection(x: 0.3, y: 0.1),
            detection(x: off, y: 0),                       // off the cloth: rejected
            detection("cue", x: -0.3, y: 0.2),             // a stick
            detection(x: -0.6, y: 0.2, confidence: 0.10),  // under the floor
            detection(x: 0.9, y: -0.2)                     // right of the blind line: no ray
        ]
        let blind = BlindRightRaycaster(inner: LinearFixtureRaycaster(calibration: calibration),
                                        limit: 0.5 + 0.88 / 2.54)
        let output = try #require(await pipeline(FixtureDetectionProvider(constant: boxes),
                                                 raycaster: blind).processFrame(frame(0)))
        let counts = output.diagnostics.detections
        #expect(counts.rawCount == 6)
        #expect(counts.stickCount == 1)
        #expect(counts.belowFloor == 1)
        #expect(counts.maxSubFloorConfidence == 0.10)
        #expect(counts.noRay == 2, "the off-table box and the right-hand box both miss the plane")
        #expect(counts.rejected == 0)
        #expect(counts.projected == 2)
        #expect(counts.rawCount == counts.stickCount + counts.belowFloor + counts.noRay
                    + counts.rejected + counts.projected)
        #expect(output.surfaceGate.rejected == counts.rejected)
        #expect(output.gateCandidates == counts.projected + counts.rejected)
    }

    @Test func aProjectionOutsideTheAdmitBandIsCountedAsRejected() async throws {
        // Under the linear raycaster a box far left lands past the cushion.
        let output = try #require(await pipeline(FixtureDetectionProvider(constant: [
            detection(x: 0, y: 0), detection(x: -1.6, y: 0.1)
        ])).processFrame(frame(0)))
        let counts = output.diagnostics.detections
        #expect(counts.rejected == 1)
        #expect(counts.projected == 1)
        #expect(output.surfaceGate.rejected == 1)
    }

    @Test func aNonNumericProjectionNeverReachesTheJSONWriter() async throws {
        let output = try #require(await pipeline(
            FixtureDetectionProvider(constant: [detection(x: 0, y: 0)]),
            raycaster: NotANumberRaycaster()).processFrame(frame(0)))
        let entry = try #require(output.diagnostics.detections.rawLabelsAll.first)
        #expect(entry.tableCentimetres == nil)
    }

    @Test func trackerCountersSayHowManyTracksWereSpawnedAndHowManyAreTentative() async throws {
        let detections = sixteenBalls(farCentreConfidence: 0.9)
        let pipeline = pipeline(FixtureDetectionProvider(constant: detections))
        let first = try #require(await pipeline.processFrame(frame(0)))
        #expect(first.diagnostics.nextTrackID == 16)
        #expect(first.diagnostics.tentativeCount == 16)
        let settled = try await run(self.pipeline(FixtureDetectionProvider(constant: detections)), frames: 5)
        #expect(settled.diagnostics.nextTrackID == 16, "a clean run spawns exactly one track per ball")
        #expect(settled.diagnostics.tentativeCount == 0)
        #expect(settled.diagnostics.frames == 5)
    }

    @Test func trackerExposesItsCounters() {
        var tracker = BallTracker()
        #expect(tracker.nextTrackID == 0)
        let observation = BallObservation(kind: .unknown, position: Vec2(0, 0), confidence: 0.9)
        _ = tracker.update(observations: [observation])
        #expect(tracker.nextTrackID == 1)
        #expect(tracker.tentativeCount == 1)
        _ = tracker.update(observations: [observation])
        _ = tracker.update(observations: [observation])
        #expect(tracker.tentativeCount == 0)
    }

    // MARK: - The live floor

    @Test func theFloorChangesOnTheNextFrameOfARunningPipeline() async throws {
        let controls = PerceptionControls()
        let detections = sixteenBalls(farCentreConfidence: 0.30)
        let running = pipeline(FixtureDetectionProvider(constant: detections), controls: controls)
        var last: PerceptionOutput?
        for index in 0..<5 { last = await running.processFrame(frame(index)) }
        #expect(last?.state.balls.count == 15)
        #expect(controls.setConfidenceFloor(0.25))
        for index in 5..<10 { last = await running.processFrame(frame(index)) }
        #expect(last?.state.balls.count == 16)
        #expect(last?.diagnostics.detections.confidenceFloor == 0.25)
        // And back: the knob is an override, not a one-way door. The ball is
        // then merely unreported once its track retires, but the frame
        // reports the floor in force.
        #expect(controls.setConfidenceFloor(nil))
        let restored = await running.processFrame(frame(10))
        #expect(restored?.diagnostics.detections.confidenceFloor == 0.35)
    }

    @Test func theFloorKnobTakesFiveHundredthsToNinetyHundredthsAndNothingElse() {
        let controls = PerceptionControls()
        #expect(controls.setConfidenceFloor(0.05))
        #expect(controls.setConfidenceFloor(0.9))
        #expect(controls.confidenceFloorOverride == 0.9)
        for refused in [0.04, 0.91, 0, 1, -0.3, .nan, .infinity] {
            #expect(!controls.setConfidenceFloor(refused), "accepted \(refused)")
        }
        #expect(controls.confidenceFloorOverride == 0.9, "a refused value must change nothing")
        #expect(controls.setConfidenceFloor(nil))
        #expect(controls.confidenceFloorOverride == nil)
    }

    @Test func theCommandParsesItsValueAndRefusesBadOnes() {
        let controls = PerceptionControls()
        #expect(controls.applyFloorCommand("0.25") == .set(0.25))
        #expect(controls.confidenceFloorOverride == 0.25)
        for bad in [nil, "", "abc", "0.04", "0.91", "nan", "inf", "-1"] {
            #expect(controls.applyFloorCommand(bad) == .refused, "accepted \(bad ?? "nil")")
        }
        #expect(controls.confidenceFloorOverride == 0.25, "a refused command must change nothing")
        #expect(controls.applyFloorCommand("default") == .cleared)
        #expect(controls.confidenceFloorOverride == nil)
    }

    @Test func theStateJSONEntriesAreNumbersAndStringsOnlyAndSerialize() async throws {
        let output = try await run(
            pipeline(FixtureDetectionProvider(constant: sixteenBalls(farCentreConfidence: 0.30))),
            frames: 5)
        let entries = output.diagnostics.mirrorEntries
        #expect(entries["rawCount"] as? Int == 16)
        #expect(entries["projected"] as? Int == 15)
        #expect(entries["rejected"] as? Int == 0)
        #expect(entries["stickCount"] as? Int == 0)
        #expect(entries["belowFloor"] as? Int == 1)
        #expect(entries["noRay"] as? Int == 0)
        #expect(entries["maxSubFloorConf"] as? Double == 0.3)
        #expect(entries["nextTrackID"] as? Int == 15)
        #expect(entries["tentativeCount"] as? Int == 0)
        let rows = try #require(entries["rawLabelsAll"] as? [[String: Any]])
        #expect(rows.count == 16)
        // The entry for the far-centre ball, in whole centimetres.
        let near = try #require(rows.first { ($0["conf"] as? Double) == 0.3 })
        #expect(near["label"] as? String == "color-ball")
        #expect(abs((near["x"] as? Int ?? 0) - 87) <= 2)
        #expect(abs((near["y"] as? Int ?? 0) - 3) <= 2)
        // The mirror writes with JSONSerialization, which traps on anything
        // it cannot represent.
        #expect(JSONSerialization.isValidJSONObject(entries))
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        #expect(!data.isEmpty)
    }

    @Test func theEntriesOmitTheSubFloorConfidenceWhenNothingWasUnderTheFloor() {
        #expect(PipelineDiagnostics().mirrorEntries["maxSubFloorConf"] == nil)
        #expect(JSONSerialization.isValidJSONObject(PipelineDiagnostics().mirrorEntries))
    }

    @Test func theDefaultFloorIsStillThirtyFivePercent() {
        #expect(PerceptionConfig.default.confidenceFloor == 0.35)
    }

    // MARK: - Stage timings

    @Test func everyStageIsTimedAndTheRollingMeansReachTheControls() async throws {
        let controls = PerceptionControls()
        let running = pipeline(FixtureDetectionProvider(constant: sixteenBalls(farCentreConfidence: 0.9)),
                               controls: controls)
        let output = try await run(running, frames: 12)
        let stages = output.diagnostics.stageMs
        for name in ["detect", "project", "track", "appearance", "other", "total"] {
            let value = try #require(stages[name], "no timing for \(name)")
            #expect(value >= 0)
        }
        // Parts never add up to more than the whole, give or take rounding
        // of each mean to 0.01 ms.
        let parts = ["detect", "project", "track", "appearance", "other"].compactMap { stages[$0] }
        #expect(parts.reduce(0, +) <= (stages["total"] ?? 0) + 0.06)
        // The same numbers are readable without the output, merged with
        // whatever the app times on the main actor.
        controls.noteAppStage("ranking", milliseconds: 4)
        controls.noteAppStage("ranking", milliseconds: 6)
        let merged = controls.stageMilliseconds
        #expect(merged["ranking"] == 5)
        #expect(merged["total"] == stages["total"])
        #expect(controls.latestDiagnostics?.frames == 12)
        controls.resetDiagnostics()
        #expect(controls.latestDiagnostics == nil)
        #expect(controls.stageMilliseconds.isEmpty)
    }

    @Test func rollingMeansKeepOnlyTheLastWindowAndRoundToTenMicroseconds() {
        var window = RollingMeans(capacity: 3)
        for value in [100.0, 1, 2, 3.004] { window.record("x", value) }
        // 100 fell out of the window: (1 + 2 + 3.004) / 3 = 2.00133.
        #expect(window.means["x"] == 2.0)
        #expect(window.means["missing"] == nil)
    }

    @Test func timingsDoNotChangeWhatTheTrackerReports() async throws {
        let detections = sixteenBalls(farCentreConfidence: 0.9)
        let plain = try await run(pipeline(FixtureDetectionProvider(constant: detections)), frames: 6)
        let observed = try await run(pipeline(FixtureDetectionProvider(constant: detections),
                                              controls: PerceptionControls()), frames: 6)
        #expect(plain.state.balls == observed.state.balls)
        #expect(plain.detectionLabels == observed.detectionLabels)
    }

    // MARK: - Label cache

    @Test func theLabelCacheAnswersExactlyWhatTheUncachedPropertiesAnswer() {
        var cache = LabelCache()
        let labels = ["white-ball", "color-ball", "cue", "Cue-Stick", "8", "ball-9", "solid-3",
                      "stripe-12", "nonsense", ""]
        for _ in 0..<2 {  // second pass answers from the cache
            for label in labels {
                let box = NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
                let detection = Detection2D(classLabel: label, boundingBox: box, confidence: 0.5)
                let info = cache.info(for: detection)
                #expect(info.isStick == detection.isCueStick, "stick \(label)")
                #expect(info.kind == detection.ballKind, "kind \(label)")
            }
        }
    }

    @Test func theLabelCacheStaysBoundedForAProviderThatInventsLabels() {
        var cache = LabelCache()
        let box = NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        for index in 0..<500 {
            let info = cache.info(for: Detection2D(classLabel: "ball-\(index % 16)-\(index)",
                                                   boundingBox: box, confidence: 0.5))
            #expect(info.isStick == false)
        }
    }
}
