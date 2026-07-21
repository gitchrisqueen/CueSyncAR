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
            // Foot point (0.225, 0.5) → table (-0.6985, 0).
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.20, y: 0.45, width: 0.05, height: 0.05),
                        confidence: 0.95),
            // Foot point (0.75, 0.25) → table (0.635, 0.3175).
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
        #expect(abs(cue.position.y) < 1e-6)
        let eight = try #require(state.balls.first { $0.kind == .eight })
        #expect(abs(eight.position.x - 0.635) < 1e-6)
        #expect(abs(eight.position.y - 0.3175) < 1e-6)
        // Table size flows from the calibration.
        #expect(state.table.size == .nineFoot)
        #expect(state.timestamp == 5.0 / 30)
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
