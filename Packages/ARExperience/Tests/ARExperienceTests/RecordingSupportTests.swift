import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import ARExperience

// The pure halves of the session-recording support in ARExperience: the
// delivered-frame side channel, the metric overlay palette and the
// rendered-marker enumeration a projection snapshot is built from. The
// ARKit-gated halves (delegate stamping, arView.project) are device-only.

private let calibration = TableCalibration(origin: Vec3(0.3, -0.45, -1.6),
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .eightFoot)

private func meta(_ timestamp: TimeInterval) -> DeliveredFrameMeta {
    DeliveredFrameMeta(timestamp: timestamp,
                       tableAnchorTransform: .identity,
                       displayTransform: [0, 1, -1, 0, 1, 0],
                       viewport: ViewportInfo(width: 390, height: 844, displayScale: 3,
                                              interfaceOrientation: "portrait"))
}

@Suite("FrameMetaRing — delivered-frame side channel")
struct FrameMetaRingTests {
    @Test func looksUpByExactTimestampAndKeepsTheNewest() {
        var ring = FrameMetaRing(capacity: 3)
        for t in [1.0, 2.0, 3.0] { ring.record(meta(t)) }
        #expect(ring.count == 3)
        #expect(ring.meta(at: 2.0)?.timestamp == 2.0)
        #expect(ring.meta(at: 2.5) == nil)
        #expect(ring.latest?.timestamp == 3.0)

        ring.record(meta(4.0))
        #expect(ring.count == 3)
        #expect(ring.meta(at: 1.0) == nil, "oldest entry is evicted at capacity")
        #expect(ring.meta(at: 4.0) != nil)
    }

    @Test func boxIsSafeAcrossQueues() async {
        let box = FrameMetaRingBox(capacity: 8)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<64 {
                group.addTask { box.record(meta(Double(t))) }
            }
        }
        // Concurrent writers land in no particular order; what must hold
        // is that the box survived them and still serves lookups.
        #expect(box.latest != nil)
        box.record(meta(1000))
        #expect(box.meta(at: 1000)?.timestamp == 1000)
        #expect(box.latest?.timestamp == 1000)
    }

    @Test func viewportBoxRoundTrips() {
        let box = ViewportInfoBox()
        #expect(box.current == .unknown)
        let viewport = ViewportInfo(width: 1024, height: 768, displayScale: 2,
                                    interfaceOrientation: "landscapeRight")
        box.current = viewport
        #expect(box.current == viewport)
    }
}

@Suite("MetricPalette")
struct MetricPaletteTests {
    @Test func everyMarkerIsColourKeyable() {
        let markers = MetricPalette.Marker.allCases
        for (i, a) in markers.enumerated() {
            for b in markers[(i + 1)...] {
                let separation = MetricPalette.channelSeparation(
                    MetricPalette.color(for: a), MetricPalette.color(for: b))
                #expect(separation >= MetricPalette.minimumChannelSeparation,
                        "\(a) vs \(b): separation \(separation)")
            }
        }
    }

    @Test func designStripTokensMapToDistinctMetricMarkers() {
        let tokens: [UInt32] = [0xF5A623, 0x2FA36B, 0x4A90D9, 0xE8604C]
        let mapped = Set(tokens.map(MetricPalette.stripMarker(forDesignColor:)))
        #expect(mapped.count == 4)
        #expect(MetricPalette.stripMarker(forDesignColor: 0x123456) == .stripAim)
    }

    @Test func channelSeparationIsChebyshev() {
        #expect(MetricPalette.channelSeparation(0xFF00FF, 0x00FFFF) == 255)
        #expect(MetricPalette.channelSeparation(0x00FF00, 0x00FF80) == 128)
        #expect(MetricPalette.channelSeparation(0x101010, 0x101010) == 0)
    }
}

@Suite("Rendered markers and projection snapshots")
struct ProjectionSnapshotTests {
    private func layoutWithEverything() -> OverlayLayout {
        var state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: BallID(0), kind: .cue, position: Vec2(-0.6, 0.05), confidence: 0.9),
            Ball(id: BallID(1), kind: .unknown, position: Vec2(0.4, -0.2), confidence: 0.8)
        ], timestamp: 1)
        state.balls.sort { $0.id.rawValue < $1.id.rawValue }
        let cue = state.balls[0], object = state.balls[1]
        let prediction = ShotPrediction(
            segments: [TrajectorySegment(ballID: cue.id, start: cue.position,
                                         end: object.position, kind: .roll, entrySpeed: 3),
                       TrajectorySegment(ballID: object.id, start: object.position,
                                         end: Vec2(1.17, -0.585), kind: .roll, entrySpeed: 2)],
            events: [.ballBall(moving: cue.id, struck: object.id, contact: object.position),
                     .pocket(ball: object.id, pocket: .cornerBottomRight)],
            pocketedBalls: [object.id])
        return OverlayLayout.compose(state: state, prediction: prediction,
                                     calibration: calibration,
                                     calledPocket: .cornerBottomRight)
    }

    @Test func enumeratesEveryPlacedEntityInPlacementOrder() {
        let layout = layoutWithEverything()
        let markers = layout.renderedMarkers
        let kinds = markers.map(\.kind)
        #expect(kinds.prefix(2) == [.cueBall, .ball])
        #expect(kinds.filter { $0 == .strip }.count == layout.strips.count)
        #expect(kinds.contains(.ghostBall))
        #expect(kinds.filter { $0 == .pocket }.count == layout.highlightedPockets.count)
        #expect(kinds.last == .calledPocket)
        // Strips carry the ball id they belong to; balls carry their index.
        #expect(markers.first { $0.kind == .strip }?.id == 0)
        #expect(markers[1].id == 1)
        // World positions are the ones the renderer places.
        #expect(markers[0].world == layout.balls[0].position)
        #expect(markers.count == 2 + layout.strips.count + 1 + layout.highlightedPockets.count + 1)
    }

    @Test func ballsOnlyLayoutHasOnlyBallMarkers() {
        let state = TableState(table: Table(size: .eightFoot), balls: [
            Ball(id: BallID(3), kind: .unknown, position: Vec2(0, 0), confidence: 0.5)
        ], timestamp: 1)
        let markers = OverlayLayout.ballsOnly(state: state, calibration: calibration).renderedMarkers
        #expect(markers == [RenderedMarker(kind: .ball, id: 0,
                                           world: calibration.tableToWorld(Vec2(0, 0)))])
    }

    @Test func snapshotIsStableOnlyWhenBothPosesAgree() {
        let pose = PoseSample(frameTimestamp: 10, cameraTransform: .identity,
                              tableAnchorTransform: .identity)
        var moved = pose
        moved.cameraTransform.columns[3] = SIMD4(0.01, 0, 0, 1)
        let viewport = ViewportInfo(width: 390, height: 844, displayScale: 3,
                                    interfaceOrientation: "portrait")
        let markers = [ProjectedMarker(marker: RenderedMarker(kind: .ball, id: 0, world: .zero),
                                       screen: Vec2(100, 200))]
        let stable = ProjectionSnapshot(before: pose, after: pose, markers: markers,
                                        viewport: viewport, paletteMode: .metric)
        let unstable = ProjectionSnapshot(before: pose, after: moved, markers: markers,
                                          viewport: viewport, paletteMode: .design)
        #expect(stable.poseStable)
        #expect(!unstable.poseStable)
    }
}
