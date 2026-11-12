//
//  FarTileModeTests.swift
//  PerceptionKitTests
//
//  The far-tile wrapper's modes (off / on / automatic), its period and
//  detect-time budget, and the window placed from the locked table. Helpers
//  (`TileScriptedDetector`, `fakeCropper`, ...) are shared with FarTileTests.
//

import CueSyncCore
import Foundation
import Synchronization
import TableSpace
import Testing
@testable import PerceptionKit

// MARK: - Modes, period and placement from the locked table

private final class EventLog: @unchecked Sendable {
    private let box = Mutex<[FarTileEvent]>([])
    func append(_ event: FarTileEvent) { box.withLock { $0.append(event) } }
    var all: [FarTileEvent] { box.withLock { $0 } }
}

@Suite("FarTileDetector: modes and placement")
struct FarTileModeTests {
    private let table = placementCalibration
    private let farView = placementFrame(camera: Vec3(-2.3, 1.1, 0), target: Vec3(0.3, 0, 0))
    private let closeView = placementFrame(camera: Vec3(0, 0.5, 0.4), target: Vec3(0.1, 0, 0))

    private func scripted() -> TileScriptedDetector {
        TileScriptedDetector(fullWidth: 1440, full: [detection(x: 0.3, y: 0.5)],
                         tile: [detection(x: 0.5, y: 0.4)])
    }

    private func events(of wrapped: FarTileDetector) -> EventLog {
        let log = EventLog()
        wrapped.setEventHandler { event in log.append(event) }
        return log
    }

    @Test func theDefaultIsOffAndEveryFrame() {
        let wrapped = FarTileDetector(inner: scripted(), cropper: fakeCropper)
        #expect(wrapped.mode == .off && !wrapped.isEnabled)
        #expect(wrapped.period == 1)
    }

    @Test func periodOneRunsOnEveryFrameAndSetPeriodThinsItOut() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .on, cropper: fakeCropper)
        for _ in 0..<3 { _ = try await wrapped.detect(in: fakeFrame()) }
        #expect(inner.seenWidths == [1440, 720, 1440, 720, 1440, 720])
        wrapped.setPeriod(3)
        #expect(wrapped.period == 3)
        let before = inner.seenWidths.count
        for _ in 0..<3 { _ = try await wrapped.detect(in: fakeFrame()) }
        // Frame indexes 3, 4, 5 with period 3: only index 3 runs a tile.
        #expect(inner.seenWidths.count - before == 4)
    }

    @Test func automaticDoesNothingBeforeATableIsLocked() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .automatic, tableSource: { nil },
                                      cropper: { _, _ in
            Issue.record("no tile pass without a locked table")
            return nil
        })
        for _ in 0..<4 { #expect(try await wrapped.detect(in: farView) == inner.full) }
        #expect(inner.seenWidths == Array(repeating: 1440, count: 4))
    }

    @Test func automaticRunsOnceATableIsLockedWithTheWindowPlacedFromIt() async throws {
        let inner = scripted()
        let locked = Mutex<TableCalibration?>(nil)
        let wrapped = FarTileDetector(inner: inner, mode: .automatic, tableSource: { locked.withLock { $0 } },
                                      cropper: fakeCropper)
        let log = events(of: wrapped)
        _ = try await wrapped.detect(in: farView)
        #expect(inner.seenWidths == [1440])
        locked.withLock { $0 = table }
        _ = try await wrapped.detect(in: farView)
        let plan = try #require(FarTilePlacement.plan(calibration: table, frame: farView))
        let crop = try #require(plan.region.pixelCrop(frameWidth: 1440, frameHeight: 1080))
        #expect(inner.seenWidths == [1440, 1440, crop.width])
        let event = try #require(log.all.first)
        #expect(event.placedFromTable && event.region == plan.region)
    }

    @Test func automaticSkipsTheTileWhenNoBallIsNarrowEnoughToNeedIt() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .automatic, tableSource: { [table] in table },
                                      cropper: fakeCropper)
        #expect(try await wrapped.detect(in: closeView) == inner.full)
        #expect(inner.seenWidths == [1440])
    }

    @Test func onWithoutATableUsesTheFixedRegion() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .on, cropper: fakeCropper)
        let log = events(of: wrapped)
        _ = try await wrapped.detect(in: farView)
        #expect(inner.seenWidths == [1440, 720])
        let event = try #require(log.all.first)
        #expect(!event.placedFromTable && event.region == .default)
    }

    @Test func onWithATableButNothingNarrowFallsBackToTheFixedRegion() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .on, tableSource: { [table] in table },
                                      cropper: fakeCropper)
        _ = try await wrapped.detect(in: closeView)
        #expect(inner.seenWidths == [1440, 720])
    }

    @Test func offAfterAutomaticStopsTheTileAndSwitchingBackStartsIt() async throws {
        let inner = scripted()
        let wrapped = FarTileDetector(inner: inner, mode: .automatic, tableSource: { [table] in table },
                                      cropper: fakeCropper)
        _ = try await wrapped.detect(in: farView)
        #expect(inner.seenWidths.count == 2)
        wrapped.setMode(.off)
        #expect(try await wrapped.detect(in: farView) == inner.full)
        #expect(inner.seenWidths.count == 3)
        wrapped.setMode(.automatic)
        _ = try await wrapped.detect(in: farView)
        #expect(inner.seenWidths.count == 5)
    }

    @Test func theWindowKeepsTheFrameAspectRatioForAnySize() throws {
        for size in [0.4, 0.4713, 0.5, 0.6, 0.7499] {
            let region = try #require(FarTileRegion(x: 0.1, y: 0.1, size: size))
            let crop = try #require(region.pixelCrop(frameWidth: 1440, frameHeight: 1080))
            #expect(crop.width * 1080 == crop.height * 1440, "size \(size): \(crop.width) x \(crop.height)")
            #expect(crop.width % 2 == 0 && crop.height % 2 == 0 && crop.x % 2 == 0 && crop.y % 2 == 0)
        }
    }
}

// MARK: - Detect-time budget

@Suite("FarTileBudget")
struct FarTileBudgetTests {
    private func settled(full: Double, tile: Double, budget: Double = 45) -> FarTileBudget {
        var b = FarTileBudget(budgetMilliseconds: budget)
        for _ in 0..<(FarTileBudget.warmupSamples + 30) {
            b.noteFullPass(milliseconds: full)
            b.noteTilePass(milliseconds: tile)
        }
        return b
    }

    @Test func theIPadNumbersGivePeriodFourAndAboutFortyOneMilliseconds() throws {
        // Measured on the iPad: full pass 27 ms, tile pass 57 ms.
        let b = settled(full: 27, tile: 57)
        #expect(b.period == 4)
        let expected = try #require(b.expectedMilliseconds)
        #expect(expected <= 45 && expected > 40)
    }

    @Test func aCheaperTileGetsMoreTilePasses() {
        #expect(settled(full: 27, tile: 15).period == 1)
        #expect(settled(full: 27, tile: 30).period == 2)
        #expect(settled(full: 27, tile: 36).period == 2)
        #expect(settled(full: 27, tile: 40).period == 3)
    }

    @Test func noRoomInTheBudgetMeansTheSlowestAllowedPeriod() {
        #expect(settled(full: 50, tile: 20).period == 8)
        #expect(settled(full: 44, tile: 200).period == 8) // ceil(200 / 1) capped
    }

    @Test func untilBothPassesAreMeasuredItRunsEveryOtherFrame() {
        var b = FarTileBudget()
        #expect(b.period == FarTileBudget.startingPeriod)
        for _ in 0..<10 { b.noteFullPass(milliseconds: 27) }
        #expect(b.period == FarTileBudget.startingPeriod && b.expectedMilliseconds == nil)
    }

    @Test func theWarmUpSamplesAreIgnored() {
        var b = FarTileBudget()
        // First inference includes model specialization: seconds.
        b.noteFullPass(milliseconds: 4000)
        b.noteFullPass(milliseconds: 900)
        b.noteTilePass(milliseconds: 3000)
        b.noteTilePass(milliseconds: 800)
        #expect(b.fullMilliseconds == nil && b.tileMilliseconds == nil)
        b.noteFullPass(milliseconds: 27)
        b.noteTilePass(milliseconds: 57)
        #expect(b.fullMilliseconds == 27 && b.tileMilliseconds == 57)
    }

    @Test func garbageSamplesAreIgnored() {
        var b = FarTileBudget()
        for _ in 0..<5 { b.noteFullPass(milliseconds: .nan); b.noteFullPass(milliseconds: -1) }
        #expect(b.fullMilliseconds == nil)
    }
}

/// A clock the scripted detector advances by a set amount per inference.
private final class FakeClock: @unchecked Sendable {
    private let nanos = Mutex<UInt64>(0)
    func advance(milliseconds: Double) { nanos.withLock { $0 += UInt64(milliseconds * 1e6) } }
    func read() -> UInt64 { nanos.withLock { $0 } }
}

private final class TimedDetector: DetectionProviding, @unchecked Sendable {
    let clock: FakeClock
    let fullMilliseconds: Double
    let tileMilliseconds: Double
    private let counts = Mutex<(full: Int, tile: Int)>((0, 0))
    init(clock: FakeClock, full: Double, tile: Double) {
        self.clock = clock
        fullMilliseconds = full
        tileMilliseconds = tile
    }
    var passes: (full: Int, tile: Int) { counts.withLock { $0 } }
    func prepare() async throws {}
    func detect(in frame: CapturedFrame) async throws -> [Detection2D] {
        if frame.image?.width == 1440 {
            counts.withLock { $0.full += 1 }
            clock.advance(milliseconds: fullMilliseconds)
        } else {
            counts.withLock { $0.tile += 1 }
            clock.advance(milliseconds: tileMilliseconds)
        }
        return [detection(x: 0.3, y: 0.5)]
    }
}

@Suite("FarTileDetector: budget mode")
struct FarTileBudgetDetectorTests {
    @Test func theAverageDetectTimeSettlesInsideTheBudget() async throws {
        let clock = FakeClock()
        let inner = TimedDetector(clock: clock, full: 27, tile: 57)
        let wrapped = FarTileDetector(inner: inner, budgetMilliseconds: 45, mode: .on,
                                      now: { clock.read() }, cropper: fakeCropper)
        // Warm up, then measure 80 frames.
        for _ in 0..<20 { _ = try await wrapped.detect(in: fakeFrame()) }
        let before = clock.read()
        for _ in 0..<80 { _ = try await wrapped.detect(in: fakeFrame()) }
        let average = Double(clock.read() - before) / 1e6 / 80
        #expect(average <= 45, "average detect \(average) ms, period \(wrapped.period)")
        #expect(wrapped.period == 4)
        #expect(wrapped.budget?.period == 4)
        // And the tile still runs: one frame in four.
        #expect(inner.passes.tile > 15)
    }

    @Test func aFastDeviceKeepsTheTileOnEveryFrame() async throws {
        let clock = FakeClock()
        let inner = TimedDetector(clock: clock, full: 10, tile: 12)
        let wrapped = FarTileDetector(inner: inner, budgetMilliseconds: 45, mode: .on,
                                      now: { clock.read() }, cropper: fakeCropper)
        for _ in 0..<40 { _ = try await wrapped.detect(in: fakeFrame()) }
        #expect(wrapped.period == 1)
    }

    @Test func pinningThePeriodLeavesBudgetMode() async throws {
        let clock = FakeClock()
        let inner = TimedDetector(clock: clock, full: 27, tile: 57)
        let wrapped = FarTileDetector(inner: inner, budgetMilliseconds: 45, mode: .on,
                                      now: { clock.read() }, cropper: fakeCropper)
        for _ in 0..<20 { _ = try await wrapped.detect(in: fakeFrame()) }
        wrapped.setPeriod(1)
        #expect(wrapped.budget == nil && wrapped.period == 1)
        for _ in 0..<20 { _ = try await wrapped.detect(in: fakeFrame()) }
        #expect(wrapped.period == 1)
        wrapped.setBudget(milliseconds: 45)
        #expect(wrapped.budget != nil)
    }

    @Test func withTheTileOffNothingIsMeasuredOrChanged() async throws {
        let clock = FakeClock()
        let inner = TimedDetector(clock: clock, full: 27, tile: 57)
        let wrapped = FarTileDetector(inner: inner, budgetMilliseconds: 45, mode: .off,
                                      now: { clock.read() }, cropper: fakeCropper)
        for _ in 0..<10 { _ = try await wrapped.detect(in: fakeFrame()) }
        #expect(wrapped.budget?.fullMilliseconds == nil)
        #expect(inner.passes.tile == 0)
    }
}
