import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

/// Deterministic raycaster: normalized image coordinates map linearly onto
/// the full playing field ((0,0) = top-left of the table seen from above).
/// Stands in for the ARKit raycast until M2-04 captures real fixtures.
struct LinearFixtureRaycaster: PlaneRaycasting {
    let calibration: TableCalibration

    func raycastToTablePlane(imagePoint: Vec2, frame: CapturedFrame) -> Vec3? {
        let (w, h) = calibration.size.playField
        let table = Vec2((imagePoint.x - 0.5) * w, (0.5 - imagePoint.y) * h)
        return calibration.tableToWorld(table)
    }
}

@Suite("PerceptionPipeline")
struct PerceptionPipelineTests {
    let calibration = TableCalibration(origin: .zero,
                                       xAxis: Vec3(1, 0, 0),
                                       yAxis: Vec3(0, 0, -1),
                                       size: .nineFoot)

    private func makeFrame(_ index: Int) -> CapturedFrame {
        CapturedFrame(timestamp: Double(index) / 30,
                      cameraTransform: .identity,
                      image: FixtureImageBuffer())
    }

    @Test func projectsDetectionsGatesConfidenceAndStabilizes() async throws {
        let detections = [
            // Box center (0.225, 0.475) → table (-0.6985, 0.03175).
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.20, y: 0.45, width: 0.05, height: 0.05),
                        confidence: 0.95),
            // Box center (0.75, 0.225) → table (0.635, 0.34925).
            Detection2D(classLabel: "8",
                        boundingBox: NormalizedRect(x: 0.725, y: 0.20, width: 0.05, height: 0.05),
                        confidence: 0.90),
            // Below the 0.35 confidence floor → must be ignored.
            Detection2D(classLabel: "3",
                        boundingBox: NormalizedRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05),
                        confidence: 0.20)
        ]
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: detections),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))

        var iterator = await pipeline.outputs.makeAsyncIterator()
        var lastState: TableState?
        for index in 0..<6 {
            await pipeline.ingest(makeFrame(index))
            lastState = await iterator.next()?.state
        }

        let state = try #require(lastState)
        // Low-confidence detection never appears; the two real balls do,
        // confirmed after the appearance gate.
        #expect(state.balls.count == 2)
        let cue = try #require(state.cueBall)
        #expect(abs(cue.position.x - (-0.6985)) < 1e-6)
        #expect(abs(cue.position.y - 0.03175) < 1e-6)
        let eight = try #require(state.balls.first { $0.kind == .eight })
        #expect(abs(eight.position.x - 0.635) < 1e-6)
        #expect(abs(eight.position.y - 0.34925) < 1e-6)
        // Table size flows from the calibration.
        #expect(state.table.size == .nineFoot)
        #expect(state.timestamp == 5.0 / 30)
    }

    @Test func rejectsObservationsProjectingOffTheTable() async throws {
        let detections = [
            // On the cloth: kept.
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.475, y: 0.475, width: 0.05, height: 0.05),
                        confidence: 0.9),
            // Box clipped at the frame edge: its foot point unprojects far
            // beyond the rails (the live "phantom tracks at (-4.5, -3.3)"
            // failure) — must never reach the tracker.
            Detection2D(classLabel: "9",
                        boundingBox: NormalizedRect(x: 0.45, y: 0.9, width: 0.1, height: 2.0),
                        confidence: 0.9)
        ]
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: detections),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))

        var iterator = await pipeline.outputs.makeAsyncIterator()
        var lastState: TableState?
        for index in 0..<6 {
            await pipeline.ingest(makeFrame(index))
            lastState = await iterator.next()?.state
        }
        let state = try #require(lastState)
        #expect(state.balls.count == 1)
        #expect(state.cueBall != nil)
    }

    @Test func appearanceGateDelaysFirstReport() async throws {
        let detections = [
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.475, y: 0.475, width: 0.05, height: 0.05),
                        confidence: 0.9)
        ]
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: detections),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))

        var iterator = await pipeline.outputs.makeAsyncIterator()
        var ballCounts: [Int] = []
        for index in 0..<4 {
            await pipeline.ingest(makeFrame(index))
            if let state = await iterator.next()?.state {
                ballCounts.append(state.balls.count)
            }
        }
        // Default appearance gate is 3 frames: empty, empty, then confirmed.
        #expect(ballCounts == [0, 0, 1, 1])
    }

    // MARK: - Playing-surface invariant (off-table tracks, 2026-09-07)

    /// Image x for a table-space x under `LinearFixtureRaycaster` on the
    /// nine-foot field (2.54 m long axis): x_img = 0.5 + x_table / 2.54.
    private func box(atTableX x: Double, y: Double = 0.475) -> NormalizedRect {
        let cx = 0.5 + x / 2.54
        return NormalizedRect(x: cx - 0.025, y: y, width: 0.05, height: 0.05)
    }

    private func settledState(_ detections: [Detection2D]) async throws -> TableState {
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: detections),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        var iterator = await pipeline.outputs.makeAsyncIterator()
        var lastState: TableState?
        for index in 0..<6 {
            await pipeline.ingest(makeFrame(index))
            lastState = await iterator.next()?.state
        }
        return try #require(lastState)
    }

    /// The invariant behind the live report "balls are being tracked off
    /// the table": a track whose estimate sits past the cushion nose must
    /// not be reported, however it got there. This one projects 3.2 cm
    /// beyond the nose line — physically impossible for a ball centre
    /// (the furthest a real ball can sit is one radius INSIDE the nose).
    @Test func trackedBallPastTheCushionNoseIsNotReported() async throws {
        let table = Table(size: .nineFoot)
        let offTable = table.halfExtents.x + 0.032
        let state = try await settledState([
            Detection2D(classLabel: "white-ball",
                        boundingBox: box(atTableX: offTable), confidence: 0.9)
        ])
        #expect(state.balls.isEmpty,
                "reported \(state.balls.map(\.position)) outside the playing surface")
        for ball in state.balls {
            #expect(table.contains(ball.position, ballRadius: Ball.standardRadius))
        }
    }

    /// A ball frozen to the cushion has its centre exactly one radius
    /// inside the nose line. It is the most common real ball near a rail
    /// and must be reported exactly where it is — clipping it would be
    /// worse than the bug.
    @Test func ballRestingAgainstTheCushionIsReported() async throws {
        let table = Table(size: .nineFoot)
        let railContact = table.halfExtents.x - Ball.standardRadius
        let state = try await settledState([
            Detection2D(classLabel: "white-ball",
                        boundingBox: box(atTableX: railContact), confidence: 0.9)
        ])
        let cue = try #require(state.cueBall)
        #expect(abs(cue.position.x - railContact) < 1e-6)
        #expect(table.contains(cue.position, ballRadius: Ball.standardRadius))
    }

    /// Calibration is never perfect: a rail ball can project a couple of
    /// centimetres past where a ball can physically be. It must still be
    /// reported (it is a real ball), and it must be reported INSIDE the
    /// surface — every ball in TableState has to satisfy the invariant.
    @Test func railBallWithCalibrationErrorIsReportedInsideTheSurface() async throws {
        let table = Table(size: .nineFoot)
        let railContact = table.halfExtents.x - Ball.standardRadius
        let state = try await settledState([
            Detection2D(classLabel: "white-ball",
                        boundingBox: box(atTableX: railContact + 0.02), confidence: 0.9)
        ])
        let cue = try #require(state.cueBall)
        #expect(table.contains(cue.position, ballRadius: Ball.standardRadius),
                "rail ball reported at x=\(cue.position.x), past the contact line \(railContact)")
        #expect(abs(cue.position.x - railContact) < 1e-6)
    }

    @Test func detectorFailuresDropFramesWithoutKillingThePipeline() async throws {
        struct FlakyDetector: DetectionProviding {
            struct Boom: Error {}
            func prepare() async throws {}
            func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
                // Fail on early frames (timestamp < 0.1s), succeed after.
                if frame.timestamp < 0.1 { throw Boom() }
                return [Detection2D(classLabel: "white-ball",
                                    boundingBox: NormalizedRect(x: 0.475, y: 0.475,
                                                                width: 0.05, height: 0.05),
                                    confidence: 0.9)]
            }
        }
        let pipeline = PerceptionPipeline(
            detector: FlakyDetector(),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))

        var iterator = await pipeline.outputs.makeAsyncIterator()
        var received = 0
        // Frames 0-2 fail (dropped, no yield); frames 3-8 succeed.
        for index in 0..<9 {
            await pipeline.ingest(makeFrame(index))
            if index >= 3 {
                if await iterator.next() != nil { received += 1 }
            }
        }
        #expect(received == 6)
    }
}

@Suite("Perception output carries what the cloth estimator needs")
struct PerceptionOutputClothSampleTests {

    /// The defect this pins: `recordClothPlaneSample` had exactly one
    /// call site, in the pre-tracking preview path, so the cloth estimate
    /// froze the moment tracking started. Measured on device — the app
    /// sat on -0.307 m for a whole session while the same maths over that
    /// session's own recording said -0.488. The fix is that every frame
    /// of live output carries the detections and the pose they were taken
    /// against, so the estimate keeps improving while the player plays.
    @Test func outputCarriesDetectionsAndPose() async throws {
        let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .nineFoot)
        let boxes = [
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.20, y: 0.45, width: 0.05, height: 0.05),
                        confidence: 0.95),
            Detection2D(classLabel: "3",
                        boundingBox: NormalizedRect(x: 0.75, y: 0.225, width: 0.05, height: 0.05),
                        confidence: 0.80)
        ]
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: boxes),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        let transform = Transform3D(columns: [
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 1.2, 2, 1)
        ])
        let intrinsics = CameraIntrinsics(focalX: 1300, focalY: 1300,
                                          principalX: 720, principalY: 540,
                                          imageWidth: 1440, imageHeight: 1080)
        let frame = CapturedFrame(timestamp: 42,
                                  cameraTransform: transform,
                                  image: FixtureImageBuffer(),
                                  intrinsics: intrinsics)
        let output = try #require(await pipeline.processFrame(frame))
        #expect(output.detections.count == boxes.count,
                "the estimator cannot run on detections it never receives")
        let pose = try #require(output.pose,
                                "no pose means no range, means no cloth height")
        #expect(pose.cameraTransform == transform)
        #expect(pose.intrinsics != nil)
        #expect(pose.timestamp == 42)
        // And it must not smuggle a pixel buffer past the frame's life:
        // ARKit's capture pool is tiny and holding one freezes the camera.
        #expect(pose.image == nil)
    }
}
