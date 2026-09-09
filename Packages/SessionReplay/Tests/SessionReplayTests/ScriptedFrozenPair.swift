import CueSyncCore
import Foundation
import PerceptionKit
import SessionReplay
import TableSpace

// The scripted-frozen-pair bundle generator — the executable derivation of
// the committed fixture under Fixtures/Sessions/scripted-frozen-pair. Same
// contract as `ScriptedFiveBall`: `committedInputsMatchTheGenerator` in
// GoldenReplayTests keeps the two in lockstep, and it is regenerated
// deliberately with CUESYNC_REGENERATE_FIXTURES=1, never by hand.
//
// Why this scene exists. Two stationary balls FROZEN (in contact, centres
// exactly one diameter apart) are the classic association-swap failure in
// multi-object tracking: the gating distance is 8 cm and the pair is 5.7 cm
// apart, so each ball's observation falls inside the OTHER's gate every
// frame, and the only thing keeping them apart is that association runs
// closest-pair-first. Nothing tested that. They are also the case that can
// break re-identification: when one of the pair is retired and re-acquired,
// the identity it reclaims has to be its own and not its neighbour's.
//
// Scene (table-space metres, 8-ft table, 2.34 × 1.17 m play field):
//   - Ball A at (0.30, 0.10) and ball B at (0.30 + 2r, 0.10): touching,
//     centres one diameter (5.715 cm) apart, both stationary throughout.
//   - A cue ball at (-0.62, 0.05), labelled "white-ball" so it classifies
//     as the cue without a designation tap.
//   - Camera 1.35 m above the cloth, 1.9 m out, sweeping a −20°…+20° arc
//     across the 90 frames — so the pair's image-space separation and
//     orientation change while their table-space positions do not.
//   - Detections are EXACT forward projections of the sphere centres with
//     ±1.5 px box-centre noise from a seeded SplitMix64, as in
//     ScriptedFiveBall.
//   - Ball B drops out of detection on frames 25…55 — 3.1 s, deliberately
//     LONGER than the 2.5 s `visibleMissGrace`, so its track really is
//     retired and its re-acquisition at frame 56 exercises
//     re-identification rather than the grace period.
//   - Timestamps run 200.0 s + 0.1 s per frame.
//
// The bar, asserted in GoldenReplayTests: exactly three ids for the whole
// clip, zero churn, and ball B carrying the SAME id before and after its
// dropout.
enum ScriptedFrozenPair {
    static let sessionID = "scripted-frozen-pair"
    static let recordedAt = "2026-09-09T00:00:00Z"
    static let frameCount = 90
    static let frameRate = 10.0
    static let seed: UInt64 = 20_260_909

    static let calibration = ScriptedFiveBall.calibration
    static let intrinsics = ScriptedFiveBall.intrinsics
    static let imageSize = ScriptedFiveBall.imageSize

    /// Centre-to-centre separation of a frozen pair: one ball diameter.
    static let pairSeparation = Ball.standardRadius * 2

    static let cuePosition = Vec2(-0.62, 0.05)
    static let frozenA = Vec2(0.30, 0.10)
    static let frozenB = Vec2(0.30 + pairSeparation, 0.10)

    /// Truth layout. Order is the truth identity (AccuracyReport).
    static let truthBalls: [(kind: String, label: String, position: Vec2)] = [
        ("cue", "white-ball", cuePosition),
        ("unknown", "color-ball", frozenA),
        ("unknown", "color-ball", frozenB)
    ]

    static let dropoutBall = 2
    static let dropoutFrames = 25...55

    static func timestamp(_ frame: Int) -> TimeInterval {
        // Exact tenths, as in ScriptedFiveBall: (2000 + i) / 10 is the
        // nearest double to 200.i, so the value survives canonical text.
        Double(2000 + frame) / frameRate
    }

    /// Camera-to-world pose for `frame` (camera looks along its −z).
    static func cameraTransform(frame: Int) -> Transform3D {
        let progress = Double(frame) / Double(frameCount - 1)
        let angle = (-20 + 40 * progress) * Double.pi / 180
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
                boxes.append(RecordedDetection(label: ball.label,
                                               x: image.x + dx - width / 2,
                                               y: image.y + dy - height / 2,
                                               width: width, height: height,
                                               confidence: confidence))
            }

            detections.append(RecordedDetectionFrame(frame: index,
                                                     timestamp: timestamp(index),
                                                     detections: boxes))
        }

        let events = [
            RecordedEvent(frame: 0, timestamp: timestamp(0), kind: .note,
                          note: "scripted-frozen-pair: two balls in contact at"
                              + " (0.30,0.10) and (0.357,0.10), cue ball at (-0.62,0.05),"
                              + " ball B dropout on frames 25-55 (3.1 s > the 2.5 s grace)")
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
            description: "Frozen pair: two stationary balls one diameter apart (inside the"
                + " 8 cm association gate) plus a white cue ball, 90 frames at 10 Hz,"
                + " camera arc -20..+20 deg, ball B dropped from detection on frames"
                + " 25-55 so its track is retired and must reclaim its own id.",
            frameCount: frameCount)

        return SessionBundle(manifest: manifest,
                             calibration: RecordedCalibration(calibration),
                             frames: frames, detections: detections,
                             events: events, truth: truth)
    }
}
