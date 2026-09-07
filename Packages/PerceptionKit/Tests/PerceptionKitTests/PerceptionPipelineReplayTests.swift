import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

/// The inline `processFrame` seam SessionReplay drives: every frame is
/// processed in order, results come back to the caller, and the stream is
/// untouched.
@Suite("PerceptionPipeline — inline processFrame (replay seam)")
struct PerceptionPipelineReplayTests {
    let calibration = TableCalibration(origin: .zero,
                                       xAxis: Vec3(1, 0, 0),
                                       yAxis: Vec3(0, 0, -1),
                                       size: .nineFoot)

    private func makeFrame(_ index: Int) -> CapturedFrame {
        CapturedFrame(timestamp: Double(index) / 30,
                      cameraTransform: .identity,
                      image: FixtureImageBuffer())
    }

    private let cueDetection = Detection2D(
        classLabel: "white-ball",
        boundingBox: NormalizedRect(x: 0.475, y: 0.475, width: 0.05, height: 0.05),
        confidence: 0.9)

    @Test func processesEveryFrameInOrderAndReturnsOutputs() async throws {
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: [cueDetection]),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        var ballCounts: [Int] = []
        var timestamps: [TimeInterval] = []
        for index in 0..<5 {
            let output = try #require(await pipeline.processFrame(makeFrame(index)))
            ballCounts.append(output.state.balls.count)
            timestamps.append(output.state.timestamp)
        }
        // Appearance gate (3 frames) then confirmed — no frame dropped.
        #expect(ballCounts == [0, 0, 1, 1, 1])
        #expect(timestamps == (0..<5).map { Double($0) / 30 })
    }

    @Test func returnsNilOnDetectorErrorAndKeepsGoing() async throws {
        struct FlakyDetector: DetectionProviding {
            struct Boom: Error {}
            let good: [Detection2D]
            func prepare() async throws {}
            func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
                if frame.timestamp < 0.05 { throw Boom() }
                return good
            }
        }
        let pipeline = PerceptionPipeline(
            detector: FlakyDetector(good: [cueDetection]),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        #expect(await pipeline.processFrame(makeFrame(0)) == nil)
        #expect(await pipeline.processFrame(makeFrame(1)) == nil)
        for index in 2..<5 {
            #expect(await pipeline.processFrame(makeFrame(index)) != nil)
        }
    }

    @Test func identicalInputsProduceIdenticalOutputs() async throws {
        // Two independent pipelines over the same frames must agree exactly
        // (bit-for-bit positions, same ids, same label order) — the
        // property the replay golden rests on.
        func run() async -> [(TableState, [String], [Vec2]?)] {
            let pipeline = PerceptionPipeline(
                detector: FixtureDetectionProvider(frames: [
                    [cueDetection,
                     Detection2D(classLabel: "color-ball",
                                 boundingBox: NormalizedRect(x: 0.7, y: 0.3, width: 0.05, height: 0.05),
                                 confidence: 0.9),
                     Detection2D(classLabel: "cue",
                                 boundingBox: NormalizedRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1),
                                 confidence: 0.9)],
                    [cueDetection]
                ]),
                calibration: calibration,
                raycaster: LinearFixtureRaycaster(calibration: calibration))
            var outputs: [(TableState, [String], [Vec2]?)] = []
            for index in 0..<8 {
                if let output = await pipeline.processFrame(makeFrame(index)) {
                    outputs.append((output.state, output.detectionLabels, output.stickQuad))
                }
            }
            return outputs
        }
        let first = await run()
        let second = await run()
        #expect(first.count == 8)
        for (a, b) in zip(first, second) {
            #expect(a.0 == b.0)
            #expect(a.1 == b.1)
            #expect(a.2 == b.2)
        }
    }

    @Test func detectionLabelsUseATotalOrderOnTies() async throws {
        // Three detections at the SAME confidence: order must be by label,
        // then detector order — never sort-stability luck.
        let detections = [
            Detection2D(classLabel: "cue",
                        boundingBox: NormalizedRect(x: 0.1, y: 0.4, width: 0.4, height: 0.1),
                        confidence: 0.9),
            Detection2D(classLabel: "white-ball",
                        boundingBox: NormalizedRect(x: 0.475, y: 0.475, width: 0.05, height: 0.05),
                        confidence: 0.9),
            Detection2D(classLabel: "color-ball",
                        boundingBox: NormalizedRect(x: 0.7, y: 0.3, width: 0.05, height: 0.05),
                        confidence: 0.9)
        ]
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: detections),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        let output = try #require(await pipeline.processFrame(makeFrame(0)))
        #expect(output.detectionLabels == ["color-ball 90%", "cue 90%", "white-ball 90%"])
    }

    @Test func inlineProcessingDoesNotFeedTheLiveStream() async throws {
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: [cueDetection]),
            calibration: calibration,
            raycaster: LinearFixtureRaycaster(calibration: calibration))
        _ = await pipeline.processFrame(makeFrame(0))
        // Ingest one frame through the live path; the stream must carry
        // exactly that one output, not the inline frame's.
        await pipeline.ingest(makeFrame(1))
        var iterator = await pipeline.outputs.makeAsyncIterator()
        let streamed = try #require(await iterator.next())
        #expect(streamed.state.timestamp == 1.0 / 30)
    }
}
