//
//  FarTileTests.swift
//  PerceptionKitTests
//
//  Far-tile pass: tile geometry and box mapping, merge, schedule, and the
//  wrapper provider (tile off == inner provider, byte for byte).
//

import CueSyncCore
import Foundation
import Synchronization
import Testing
@testable import PerceptionKit

private func detection(_ label: String = "color-ball", x: Double, y: Double,
                       w: Double = 0.02, h: Double = 0.03,
                       confidence: Double = 0.6) -> Detection2D {
    Detection2D(classLabel: label,
                boundingBox: NormalizedRect(x: x, y: y, width: w, height: h),
                confidence: confidence)
}

@Suite("FarTileRegion and mapping")
struct FarTileGeometryTests {
    @Test func defaultCropKeepsTheFrameAspectRatio() throws {
        let crop = try #require(FarTileRegion.default.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        #expect(crop == FarTilePixelCrop(x: 360, y: 216, width: 720, height: 540,
                                         frameWidth: 1440, frameHeight: 1080))
        // 720 / 540 == 1440 / 1080: the stretch to 640 x 640 distorts the
        // tile exactly as it distorts the full frame.
        #expect(Double(crop.width) / Double(crop.height) == 1440.0 / 1080.0)
    }

    @Test func cropStaysEvenAndInsideForOddFrameSizes() throws {
        let region = try #require(FarTileRegion(x: 0.7, y: 0.7, size: 0.3))
        let crop = try #require(region.pixelCrop(frameWidth: 1001, frameHeight: 777))
        #expect(crop.x % 2 == 0 && crop.y % 2 == 0 && crop.width % 2 == 0 && crop.height % 2 == 0)
        #expect(crop.x + crop.width <= 1001 && crop.y + crop.height <= 777)
    }

    @Test func regionOutsideTheFrameOrTooSmallIsRejected() {
        #expect(FarTileRegion(x: 0.6, y: 0.1, size: 0.5) == nil)
        #expect(FarTileRegion(x: -0.1, y: 0.1, size: 0.5) == nil)
        #expect(FarTileRegion(x: 0, y: 0, size: 0.05) == nil)
        #expect(FarTileRegion(x: 0, y: 0, size: 1) != nil)
    }

    @Test func tileCornersMapToTheCropCornersInTheFrame() throws {
        let crop = try #require(FarTileRegion.default.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        let whole = crop.frameBox(fromTileBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(whole.x - 0.25) < 1e-12 && abs(whole.y - 0.2) < 1e-12)
        #expect(abs(whole.width - 0.5) < 1e-12 && abs(whole.height - 0.5) < 1e-12)
    }

    @Test func aBoxMapsBackToTheFramePixelsItCameFrom() throws {
        let crop = try #require(FarTileRegion.default.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        // A 22 x 30 px ball at frame pixel (700, 420) ...
        let framePixels = (x: 700.0, y: 420.0, w: 22.0, h: 30.0)
        // ... as the model sees it in the tile: shifted by the crop origin,
        // normalized by the crop size.
        let tileBox = NormalizedRect(x: (framePixels.x - 360) / 720, y: (framePixels.y - 216) / 540,
                                     width: framePixels.w / 720, height: framePixels.h / 540)
        let back = crop.frameBox(fromTileBox: tileBox)
        #expect(abs(back.x * 1440 - 700) < 1e-9)
        #expect(abs(back.y * 1080 - 420) < 1e-9)
        #expect(abs(back.width * 1440 - 22) < 1e-9)
        #expect(abs(back.height * 1080 - 30) < 1e-9)
    }
}

@Suite("FarTileMerge")
struct FarTileMergeTests {
    private let crop = FarTileRegion.default.pixelCrop(frameWidth: 1440, frameHeight: 1080)!

    @Test func tileBoxesClippedByTheTileEdgeAreDropped() {
        let raw = [
            detection(x: 0.0, y: 0.4),            // touches the left edge
            detection(x: 0.5, y: 0.0),            // touches the top edge
            detection(x: 0.985, y: 0.4),          // touches the right edge
            detection(x: 0.5, y: 0.975, h: 0.03), // touches the bottom edge
            detection(x: 0.5, y: 0.4),            // interior
        ]
        let mapped = FarTileMerge.frameDetections(fromTile: raw, crop: crop)
        #expect(mapped.count == 1)
    }

    @Test func tileStickBoxesAreDropped() {
        let raw = [detection("cue", x: 0.3, y: 0.3, w: 0.4, h: 0.1),
                   detection("white-ball", x: 0.5, y: 0.5)]
        let mapped = FarTileMerge.frameDetections(fromTile: raw, crop: crop)
        #expect(mapped.map(\.classLabel) == ["white-ball"])
    }

    @Test func mappedBoxesLandInFrameSpace() throws {
        let raw = [detection(x: 0.5, y: 0.5, w: 0.1, h: 0.1)]
        let mapped = try #require(FarTileMerge.frameDetections(fromTile: raw, crop: crop).first)
        #expect(abs(mapped.boundingBox.x - (0.25 + 0.5 * 0.5)) < 1e-12)
        #expect(abs(mapped.boundingBox.width - 0.05) < 1e-12)
    }

    @Test func trustedConfidenceIsThePipelineFloor() {
        #expect(FarTileMerge.trustedConfidence == PerceptionConfig().confidenceFloor)
    }

    @Test func aBallSeenInBothPassesKeepsOneBoxAndTheTrustedFullFrameBox() {
        let full = [detection(x: 0.500, y: 0.400, confidence: 0.45)]
        // Same ball, a box shifted by a dozen pixels, higher confidence.
        let tile = [detection(x: 0.5005, y: 0.3925, w: 0.019, h: 0.029, confidence: 0.8)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == full)
    }

    @Test func aSubFloorFullBoxIsReplacedByAMoreConfidentTileBox() {
        // The borderline cue ball: full frame 0.30, zoomed pass 0.60.
        let full = [detection("white-ball", x: 0.500, y: 0.500, confidence: 0.30)]
        let tile = [detection("white-ball", x: 0.5005, y: 0.5005, w: 0.019, h: 0.029, confidence: 0.6)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == tile)
    }

    @Test func aSubFloorFullBoxSurvivesALessConfidentTileBox() {
        let full = [detection(x: 0.5, y: 0.4, confidence: 0.30)]
        let tile = [detection(x: 0.5, y: 0.4, confidence: 0.2)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == full)
    }

    @Test func subFloorJunkFromALoweredThresholdCannotSwallowATileBall() {
        // At a 0.05 model threshold the full pass emits faint boxes. One of
        // them overlaps the real far ball the tile found at 0.5; the tile
        // box must come through rather than be dropped as "already seen".
        let junk = detection("white-ball", x: 0.499, y: 0.392, w: 0.02, h: 0.04, confidence: 0.06)
        let tile = [detection(x: 0.4995, y: 0.390, confidence: 0.5)]
        let merged = FarTileMerge.merge(full: [junk], tile: tile)
        #expect(merged == tile)
    }

    @Test func aLowerConfidenceTileBoxChangesNothing() {
        let full = [detection(x: 0.5, y: 0.4, confidence: 0.9)]
        let tile = [detection(x: 0.5, y: 0.4, confidence: 0.5)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == full)
    }

    @Test func aTileBoxWithAnotherLabelDoesNotRelabelATrustedFullBox() {
        let full = [detection("white-ball", x: 0.5, y: 0.4, confidence: 0.38)]
        let tile = [detection("color-ball", x: 0.5, y: 0.4, confidence: 0.8)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == full)
    }

    @Test func aSmallTileBoxInsideALargerFullBoxIsTheSameBall() {
        // The zoomed pass sometimes boxes half of a large near ball.
        let full = [detection(x: 0.50, y: 0.40, w: 0.03, h: 0.04, confidence: 0.7)]
        let tile = [detection(x: 0.505, y: 0.40, w: 0.02, h: 0.02, confidence: 0.6)]
        #expect(FarTileMerge.merge(full: full, tile: tile) == full)
    }

    @Test func aBallOnlyTheTileSawIsAdded() {
        let full = [detection(x: 0.3, y: 0.5)]
        let tile = [detection(x: 0.5, y: 0.389, confidence: 0.4)]
        let merged = FarTileMerge.merge(full: full, tile: tile)
        #expect(merged.count == 2)
        #expect(merged.contains(tile[0]))
    }

    @Test func neighbouringBallsAreNotMerged() {
        // Tangent balls, one diameter apart: boxes touch, they do not overlap.
        let full = [detection(x: 0.50, y: 0.40)]
        let tile = [detection(x: 0.52, y: 0.40, confidence: 0.7)]
        #expect(FarTileMerge.merge(full: full, tile: tile).count == 2)
    }

    @Test func aFullFrameStickBoxNeverAbsorbsATileBall() {
        let stick = detection("cue", x: 0.3, y: 0.3, w: 0.4, h: 0.2, confidence: 0.9)
        let ball = detection(x: 0.5, y: 0.35, confidence: 0.5)
        let merged = FarTileMerge.merge(full: [stick], tile: [ball])
        #expect(merged == [stick, ball])
    }

    @Test func anEmptyTileLeavesTheFullResultUnchangedInOrder() {
        let full = [detection(x: 0.1, y: 0.1), detection("cue", x: 0.2, y: 0.2, w: 0.3),
                    detection(x: 0.6, y: 0.6)]
        #expect(FarTileMerge.merge(full: full, tile: []) == full)
    }

    @Test func twoTileBoxesOnOneBallAddItOnce() {
        let tile = [detection(x: 0.5, y: 0.4, confidence: 0.5),
                    detection(x: 0.5, y: 0.4, confidence: 0.6)]
        let merged = FarTileMerge.merge(full: [], tile: tile)
        #expect(merged.count == 1)
        #expect(merged[0].confidence == 0.6)
    }
}

@Suite("FarTileSchedule")
struct FarTileScheduleTests {
    @Test func periodTwoRunsOnEverySecondFrame() {
        var schedule = FarTileSchedule(period: 2)
        let runs = (0..<6).map { _ in schedule.advance(enabled: true) }
        #expect(runs == [true, false, true, false, true, false])
    }

    @Test func periodThreeRunsOnEveryThirdFrame() {
        var schedule = FarTileSchedule(period: 3)
        let runs = (0..<7).map { _ in schedule.advance(enabled: true) }
        #expect(runs == [true, false, false, true, false, false, true])
    }

    @Test func disabledNeverRunsButTheRhythmKeepsCounting() {
        var schedule = FarTileSchedule(period: 2)
        let whileOff = (0..<4).map { _ in schedule.advance(enabled: false) }
        #expect(whileOff == [false, false, false, false])
        // Frame index 4 is a tile frame: switching on does not shift the phase.
        let first = schedule.advance(enabled: true)
        let second = schedule.advance(enabled: true)
        #expect(first && !second)
    }

    @Test func aPeriodBelowOneMeansEveryFrame() {
        var schedule = FarTileSchedule(period: 0)
        let runs = (0..<3).map { _ in schedule.advance(enabled: true) }
        #expect(runs == [true, true, true])
    }
}

// MARK: - Wrapper provider

private struct FakeImage: ImageBufferProviding {
    let width: Int
    let height: Int
}

/// Answers by image size: the full frame and the tile get different canned
/// results, and every call is recorded.
private final class ScriptedDetector: DetectionProviding, @unchecked Sendable {
    let fullWidth: Int
    var full: [Detection2D]
    var tile: [Detection2D]
    var tileError: (any Error)?
    private let widths = Mutex<[Int]>([])

    init(fullWidth: Int, full: [Detection2D], tile: [Detection2D] = []) {
        self.fullWidth = fullWidth
        self.full = full
        self.tile = tile
    }

    var seenWidths: [Int] { widths.withLock { $0 } }

    func prepare() async throws {}

    func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        let width = frame.image?.width ?? 0
        widths.withLock { $0.append(width) }
        if width == fullWidth { return full }
        if let tileError { throw tileError }
        return tile
    }
}

private struct CropFailure: Error {}

private func fakeFrame() -> CapturedFrame {
    CapturedFrame(timestamp: 1, cameraTransform: .identity,
                  image: FakeImage(width: 1440, height: 1080))
}

private let fakeCropper: FarTileDetector.Cropper = { frame, crop in
    CapturedFrame(timestamp: frame.timestamp, cameraTransform: frame.cameraTransform,
                  image: FakeImage(width: crop.width, height: crop.height))
}

@Suite("FarTileDetector")
struct FarTileDetectorTests {
    @Test func withTheTileOffTheResultIsExactlyTheInnerResult() async throws {
        let inner = ScriptedDetector(
            fullWidth: 1440,
            full: [detection(x: 0.1, y: 0.2, confidence: 0.31), detection("cue", x: 0.7, y: 0.5, w: 0.2)],
            tile: [detection(x: 0.5, y: 0.5)])
        let wrapped = FarTileDetector(inner: inner, cropper: { _, _ in
            Issue.record("cropper must not run while the tile is off")
            return nil
        })
        #expect(!wrapped.isEnabled)
        for _ in 0..<6 {
            let result = try await wrapped.detect(in: fakeFrame())
            #expect(result == inner.full)
        }
        // One inference per frame: nothing but the full-frame pass ran.
        #expect(inner.seenWidths == Array(repeating: 1440, count: 6))
    }

    @Test func withTheTileOnItRunsEverySecondFrameAndMerges() async throws {
        let inner = ScriptedDetector(fullWidth: 1440,
                                     full: [detection(x: 0.3, y: 0.5)],
                                     tile: [detection(x: 0.5, y: 0.4)])
        let wrapped = FarTileDetector(inner: inner, period: 2, enabled: true, cropper: fakeCropper)
        var counts = [Int]()
        for _ in 0..<4 { counts.append(try await wrapped.detect(in: fakeFrame()).count) }
        #expect(counts == [2, 1, 2, 1])
        // Tile frames: full pass then the 720-wide tile; others: full only.
        #expect(inner.seenWidths == [1440, 720, 1440, 1440, 720, 1440])
    }

    @Test func switchingOnAndOffTakesEffectOnTheNextFrame() async throws {
        let inner = ScriptedDetector(fullWidth: 1440, full: [], tile: [detection(x: 0.5, y: 0.4)])
        let wrapped = FarTileDetector(inner: inner, period: 1, cropper: fakeCropper)
        #expect(try await wrapped.detect(in: fakeFrame()).isEmpty)
        wrapped.setEnabled(true)
        #expect(try await wrapped.detect(in: fakeFrame()).count == 1)
        wrapped.setEnabled(false)
        #expect(try await wrapped.detect(in: fakeFrame()).isEmpty)
    }

    @Test func aFailingTilePassStillReturnsTheFullFrameResult() async throws {
        let inner = ScriptedDetector(fullWidth: 1440, full: [detection(x: 0.3, y: 0.5)])
        inner.tileError = CropFailure()
        let wrapped = FarTileDetector(inner: inner, period: 1, enabled: true, cropper: fakeCropper)
        let events = Mutex<[FarTileEvent]>([])
        wrapped.setEventHandler { event in events.withLock { $0.append(event) } }
        let result = try await wrapped.detect(in: fakeFrame())
        #expect(result == inner.full)
        let recorded = events.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded[0].failure != nil)
    }

    @Test func aCropperThatCannotCropMeansNoTilePass() async throws {
        let inner = ScriptedDetector(fullWidth: 1440, full: [detection(x: 0.3, y: 0.5)],
                                     tile: [detection(x: 0.5, y: 0.4)])
        let wrapped = FarTileDetector(inner: inner, period: 1, enabled: true, cropper: { _, _ in nil })
        #expect(try await wrapped.detect(in: fakeFrame()) == inner.full)
        #expect(inner.seenWidths == [1440])
    }

    @Test func theEventReportsWhatTheTileAdded() async throws {
        let inner = ScriptedDetector(
            fullWidth: 1440,
            full: [detection(x: 0.3, y: 0.5)],
            tile: [detection(x: 0.5, y: 0.4), detection(x: 0.2, y: 0.2)])
        let wrapped = FarTileDetector(inner: inner, period: 1, enabled: true, cropper: fakeCropper)
        let events = Mutex<[FarTileEvent]>([])
        wrapped.setEventHandler { event in events.withLock { $0.append(event) } }
        _ = try await wrapped.detect(in: fakeFrame())
        let event = try #require(events.withLock { $0 }.first)
        #expect(event.frameIndex == 0 && event.tileDetections == 2 && event.added == 2)
        #expect(event.failure == nil)
    }
}
