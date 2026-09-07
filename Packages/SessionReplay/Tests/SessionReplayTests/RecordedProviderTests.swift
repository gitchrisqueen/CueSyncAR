import CueSyncCore
import CueSyncTestSupport
import Foundation
import Testing
@testable import SessionReplay

@Suite("RecordedDetectionProvider")
struct RecordedDetectionProviderTests {
    @Test func satisfiesTheDetectionProviderContract() async {
        // The contract's sample frame has timestamp 0 — record one for it.
        let provider = RecordedDetectionProvider(detections: [
            RecordedDetectionFrame(frame: 0, timestamp: 0, detections: [
                RecordedDetection(label: "white-ball", x: 0.4, y: 0.4, width: 0.05, height: 0.05,
                                  confidence: 0.9)
            ])
        ])
        let failures = await ProviderContracts.checkDetectionProvider(provider)
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func returnsTheRecordedDetectionsForAFrameByTimestamp() async throws {
        let bundle = ScriptedFiveBall.makeBundle()
        let provider = RecordedDetectionProvider(bundle: bundle)
        let frame = try bundle.frames[9].capturedFrame()
        let detections = try await provider.detect(in: frame)
        #expect(detections == bundle.detections[9].detections.map(\.detection2D))
        // Frame 9 is inside the stick window: five balls + the stick.
        #expect(detections.count == 6)
        #expect(detections.contains { $0.isCueStick })
    }

    @Test func throwsForAFrameWithNoRecordedDetections() async {
        let provider = RecordedDetectionProvider(detections: [])
        let frame = CapturedFrame(timestamp: 42, cameraTransform: .identity)
        await #expect(throws: RecordedDetectionProvider.MissingFrame(timestamp: 42)) {
            try await provider.detect(in: frame)
        }
    }
}

@Suite("RecordedFrameSource")
struct RecordedFrameSourceTests {
    @Test func handsOutFramesInIndexOrderThenNil() async throws {
        let bundle = ScriptedFiveBall.makeBundle()
        let source = RecordedFrameSource(frames: bundle.frames.reversed())
        #expect(await source.remaining == ScriptedFiveBall.frameCount)
        var timestamps: [TimeInterval] = []
        while let frame = await source.nextFrame() {
            timestamps.append(frame.timestamp)
        }
        #expect(timestamps == bundle.frames.map(\.timestamp))
        #expect(await source.nextFrame() == nil)
        #expect(await source.remaining == 0)
        await source.rewind()
        #expect(await source.nextFrame()?.timestamp == bundle.frames[0].timestamp)
    }
}
