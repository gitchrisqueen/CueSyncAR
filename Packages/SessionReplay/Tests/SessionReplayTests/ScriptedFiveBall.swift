import CueSyncCore
import Foundation
import PerceptionKit
import SessionReplay
import TableSpace

// The scripted-5ball bundle generator — the executable derivation of the
// committed fixture under Fixtures/Sessions/scripted-5ball (its README
// restates this in prose). `committedInputsMatchTheGenerator` in
// GoldenReplayTests keeps the two in lockstep; regenerate deliberately with
// CUESYNC_REGENERATE_FIXTURES=1 (see that suite), never by hand.
//
// Scene (all table-space meters, 8-ft table, 2.34 × 1.17 m play field):
//   - Five static balls. The cue ball is a measle/practice ball, so the
//     detector labels it "color-ball" like the others — exactly the
//     on-device case CLAUDE.md describes — and the user designates it by
//     tap at frame 5 (a `designateCueBall` event at (-0.60, 0.06)).
//   - Camera: 1.35 m above the cloth, 1.9 m from the table center on the
//     head-rail side, sweeping a −25°…+25° arc over the 30 frames while
//     looking at table point (0.10, 0) — a slow walk-around.
//   - Detections are EXACT forward projections (PlaneGeometryRaycaster.
//     projectToImage of the sphere center lifted one radius) with ±1.5 px
//     box-center noise and per-box confidence from a seeded SplitMix64.
//   - Ball 3 (0.58, 0.31) drops out of detection on frames 12…16 (must
//     persist: visibility-gated misses, 30-frame disappearance gate).
//   - A cue-stick detection ("cue") addresses the cue ball on frames
//     8…14 (butt (-1.55, -0.07) → tip (-0.72, 0.04): the butt overhangs
//     the head rail, the tip end is on the cloth, which is what
//     StickAim.quadOnTable accepts); the 2.5 s stick hold then keeps the
//     stick aim through frame 39 (10 Hz), after which the device-pose
//     model takes over again for frames 40…44 — hence 45 frames.
//   - Frame 20 carries a spurious 22 %-confidence "color-ball" box in the
//     middle of the table (below the 0.35 floor — must be ignored).
//   - A `callPocket cornerTopRight` event at frame 18 exercises the
//     called-shot flag.
//   - Timestamps run 100.0 s + 0.1 s per frame.
enum ScriptedFiveBall {
    static let sessionID = "scripted-5ball"
    static let recordedAt = "2026-09-07T00:00:00Z"
    static let frameCount = 45
    static let frameRate = 10.0
    static let seed: UInt64 = 20_260_907

    static let calibration = TableCalibration(origin: Vec3(0.3, -0.45, -1.6),
                                              xAxis: Vec3(1, 0, 0),
                                              yAxis: Vec3(0, 0, -1),
                                              size: .eightFoot)

    static let intrinsics = CameraIntrinsics(focalX: 1450, focalY: 1450,
                                             principalX: 960, principalY: 720,
                                             imageWidth: 1920, imageHeight: 1440)
    static let imageSize = (width: 1920, height: 1440)

    /// Truth layout. Order is the truth identity (AccuracyReport).
    static let truthBalls: [(kind: String, position: Vec2)] = [
        ("cue", Vec2(-0.62, 0.05)),
        ("unknown", Vec2(0.15, 0.10)),
        ("unknown", Vec2(0.42, -0.22)),
        ("unknown", Vec2(0.58, 0.31)),
        ("unknown", Vec2(0.05, -0.40))
    ]

    static let dropoutBall = 3
    static let dropoutFrames = 12...16
    static let stickFrames = 8...14
    static let stickButt = Vec2(-1.55, -0.07)
    static let stickTip = Vec2(-0.72, 0.04)
    static let spuriousFrame = 20
    static let designateFrame = 5
    static let designateTap = Vec2(-0.60, 0.06)
    static let callPocketFrame = 18
    static let calledPocket = PocketID.cornerTopRight

    static func timestamp(_ frame: Int) -> TimeInterval {
        // Exact tenths: (1000 + i) / 10 is the nearest double to 100.i,
        // so the in-memory value survives the six-decimal canonical text.
        Double(1000 + frame) / frameRate
    }

    /// Camera-to-world pose for `frame` (camera looks along its −z).
    static func cameraTransform(frame: Int) -> Transform3D {
        let progress = Double(frame) / Double(frameCount - 1)
        let angle = (-25 + 50 * progress) * Double.pi / 180
        let onTable = Vec2(-1.9 * Foundation.cos(angle), 1.9 * Foundation.sin(angle))
        let normal = calibration.normal
        let position = calibration.tableToWorld(onTable) + normal * 1.35
        let target = calibration.tableToWorld(Vec2(0.10, 0))
        let zAxis = (position - target).normalized
        let xAxis = normal.cross(zAxis).normalized
        let yAxis = zAxis.cross(xAxis)
        return Transform3D(columns: [
            SIMD4(xAxis.x, xAxis.y, xAxis.z, 0),
            SIMD4(yAxis.x, yAxis.y, yAxis.z, 0),
            SIMD4(zAxis.x, zAxis.y, zAxis.z, 0),
            SIMD4(position.x, position.y, position.z, 1)
        ])
    }

    static func capturedFrame(_ frame: Int) -> CapturedFrame {
        CapturedFrame(timestamp: timestamp(frame),
                      cameraTransform: cameraTransform(frame: frame),
                      image: RecordedImage(width: imageSize.width, height: imageSize.height),
                      intrinsics: intrinsics)
    }

    static func makeBundle() -> SessionBundle {
        var rng = SplitMix64(seed: seed)
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        let normal = calibration.normal
        let radius = Ball.standardRadius
        var frames: [RecordedFrameMeta] = []
        var detections: [RecordedDetectionFrame] = []

        for index in 0..<frameCount {
            let frame = capturedFrame(index)
            frames.append(RecordedFrameMeta(index: index, frame: frame))
            var boxes: [RecordedDetection] = []
            let cameraPosition = frame.cameraTransform.translation

            for (ballIndex, ball) in truthBalls.enumerated() {
                if ballIndex == dropoutBall, dropoutFrames.contains(index) { continue }
                let center = calibration.tableToWorld(ball.position) + normal * radius
                guard let image = raycaster.projectToImage(worldPoint: center, frame: frame) else {
                    continue
                }
                let depth = center.distance(to: cameraPosition)
                let pixelRadius = intrinsics.focalX * radius / depth
                let width = 2 * pixelRadius / intrinsics.imageWidth
                let height = 2 * pixelRadius / intrinsics.imageHeight
                let dx = rng.uniform(-1.5...1.5) / intrinsics.imageWidth
                let dy = rng.uniform(-1.5...1.5) / intrinsics.imageHeight
                let confidence = (rng.uniform(0.80...0.97) * 100).rounded() / 100
                boxes.append(RecordedDetection(label: "color-ball",
                                               x: image.x + dx - width / 2,
                                               y: image.y + dy - height / 2,
                                               width: width, height: height,
                                               confidence: confidence))
            }

            if stickFrames.contains(index) {
                let ends = [stickButt, stickTip].compactMap { point -> Vec2? in
                    raycaster.projectToImage(
                        worldPoint: calibration.tableToWorld(point) + normal * 0.01,
                        frame: frame)
                }
                if ends.count == 2 {
                    let pad = 6.0
                    let minX = min(ends[0].x, ends[1].x) - pad / intrinsics.imageWidth
                    let maxX = max(ends[0].x, ends[1].x) + pad / intrinsics.imageWidth
                    let minY = min(ends[0].y, ends[1].y) - pad / intrinsics.imageHeight
                    let maxY = max(ends[0].y, ends[1].y) + pad / intrinsics.imageHeight
                    boxes.append(RecordedDetection(label: "cue", x: minX, y: minY,
                                                   width: maxX - minX, height: maxY - minY,
                                                   confidence: 0.7))
                }
            }

            if index == spuriousFrame,
               let image = raycaster.projectToImage(
                worldPoint: calibration.tableToWorld(Vec2(0.30, 0)) + normal * radius,
                frame: frame) {
                boxes.append(RecordedDetection(label: "color-ball",
                                               x: image.x - 0.01, y: image.y - 0.012,
                                               width: 0.02, height: 0.024,
                                               confidence: 0.22))
            }

            detections.append(RecordedDetectionFrame(frame: index,
                                                     timestamp: timestamp(index),
                                                     detections: boxes))
        }

        let events = [
            RecordedEvent(frame: 0, timestamp: timestamp(0), kind: .note,
                          note: "scripted-5ball: measle cue ball, walk-around camera,"
                              + " stick on frames 8-14, ball 3 dropout on 12-16"),
            RecordedEvent(frame: designateFrame, timestamp: timestamp(designateFrame),
                          kind: .designateCueBall,
                          x: designateTap.x, y: designateTap.y),
            RecordedEvent(frame: callPocketFrame, timestamp: timestamp(callPocketFrame),
                          kind: .callPocket, pocket: calledPocket.rawValue)
        ]

        let truth = SessionTruth(
            matchRadius: 0.03,
            balls: truthBalls.map { TruthBall(kind: $0.kind, x: $0.position.x, y: $0.position.y) },
            method: "scripted: detections are exact forward projections of these positions"
                + " plus ±1.5 px box-center noise (SplitMix64 seed \(seed))")

        let manifest = SessionManifest(
            sessionID: sessionID,
            recordedAt: recordedAt,
            source: "scripted",
            description: "Five static balls (measle cue designated by tap at frame 5),"
                + " 45 frames at 10 Hz, camera arc -25..+25 deg, stick aim on frames 8-14"
                + " (held 2.5 s, device pose again from frame 40), ball 3 dropout on"
                + " frames 12-16, spurious low-confidence box on frame 20.",
            frameCount: frameCount)

        return SessionBundle(manifest: manifest,
                             calibration: RecordedCalibration(calibration),
                             frames: frames, detections: detections,
                             events: events, truth: truth)
    }
}

/// Deterministic RNG for reproducible noise (same construction as the
/// PerceptionKit tests use).
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `range`, from the top 53 bits (platform-neutral:
    /// no dependence on `Double.random`'s implementation).
    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
