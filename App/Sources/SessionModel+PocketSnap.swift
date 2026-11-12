//
//  SessionModel+PocketSnap.swift
//  CueSync AR
//
//  The accurate pocket calibration: snap the taps to the cushion-nose lines
//  in the camera image, fit the table with the plane's height and tilt
//  free, and measure the size with the balls laid across the table.
//  See docs/plans/2026-11-11-calibration-accuracy.md.
//
//  The image work is pure (TableSpace.PocketSnap, TiltedPocketFit,
//  TableSizeFromImage). What is here is the plumbing: the latest camera
//  frame, view points to image pixels and back to world rays, and the
//  messages.
//

import ARExperience
import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

extension SessionModel {

    /// The pocket sightings as world rays, refined in the camera image.
    struct SnappedPockets {
        var rays: [(pocket: PocketID, ray: TapRay)]
        /// Image-pixel taps, for naming pockets the way the user sees them.
        var imageTaps: [PocketID: Vec2]
        var methods: [PocketID: PocketSnap.Method]
        var size: TableSizeFromImage.Estimate?
        /// What the lock is built from, for `/state.json` (the per-pocket
        /// errors are filled in once the fit has run).
        var evidence: PocketLockEvidence
        /// How many taps actually moved onto a feature.
        var snappedCount: Int { methods.values.filter { $0 != .raw }.count }
    }

    /// Pull one camera frame and detect its balls, for snapping and the size
    /// check. The live pipeline's frames carry no pixels (nothing may hold
    /// ARKit's buffers), and it owns `nextFrame()` while it runs, so a
    /// running pipeline is stopped first: the calibration that follows
    /// restarts it (`startLiveTrackingIfReady`), and so does cancelling.
    func prefetchSnapFrame() async {
        if isLiveTracking { stopLiveTracking() }
        guard let coordinator = arCoordinator, let frame = await coordinator.nextFrame() else { return }
        var detections: [Detection2D] = []
        if let provider = onDeviceProvider {
            detections = (try? await provider.detect(in: frame)) ?? []
        }
        recordClothPlaneSample(detections: detections, frame: frame)
    }

    /// Refine view-point sightings against the latest camera frame. Nil
    /// when there is no frame with pixels and intrinsics to refine against;
    /// the caller then uses the raw taps.
    func snapPockets(_ sightings: [(PocketID, CGPoint)],
                     coordinator: ARSessionCoordinator) -> SnappedPockets? {
        guard let sample = clothPlaneSamples.last(where: { $0.frame.image is PixelBufferImage }),
              let k = sample.frame.intrinsics,
              let pixels = sample.frame.image as? PixelBufferImage,
              let image = pixels.lumaImage() else {
            placement.noteProbe("snap: no camera frame yet, using the taps as given")
            return nil
        }
        let pose = sample.frame.cameraTransform
        var taps: [PocketID: Vec2] = [:]
        for (pocket, point) in sightings {
            guard let ray = coordinator.worldRay(through: point),
                  let pixel = Self.imagePixel(of: ray.direction, pose: pose, intrinsics: k) else { continue }
            taps[pocket] = pixel
        }
        guard taps.count == sightings.count else { return nil }
        let refined = PocketSnap.refine(image, taps: taps)
        var rays: [(pocket: PocketID, ray: TapRay)] = []
        var methods: [PocketID: PocketSnap.Method] = [:]
        var recorded: [PocketID: PocketLockEvidence.Pocket] = [:]
        for (pocket, _) in sightings {
            guard let result = refined[pocket] else { continue }
            methods[pocket] = result.method
            recorded[pocket] = .init(tap: result.tap, snapped: result.point, method: result.method.rawValue)
            rays.append((pocket, Self.worldRay(throughPixel: result.point, pose: pose, intrinsics: k)))
        }
        // The size, with the balls in the SAME frame as the ruler.
        let lines = PocketSnap.sideLines(image, taps: taps)
        var size: TableSizeFromImage.Estimate?
        if let left = lines[0].nose, let right = lines[2].nose {
            let across = lines[1].nose?.direction ?? lines[3].rail?.direction ?? Vec2(1, 0)
            let balls = sample.detections.filter { !$0.isCueStick && $0.confidence >= 0.35 }.map { detection in
                let box = detection.boundingBox
                let centre = Vec2(box.center.x * k.imageWidth, box.center.y * k.imageHeight)
                let radius = max(box.width * k.imageWidth, box.height * k.imageHeight) / 2
                return TableSizeFromImage.Ball(
                    centre: centre, radius: radius,
                    noseRangeRatio: Self.noseRangeRatio(centre: centre, radius: radius, pose: pose, intrinsics: k))
            }
            size = TableSizeFromImage.estimate(image, leftNose: left, rightNose: right,
                                               across: across, balls: balls)
        }
        placement.pocketSnap = Dictionary(uniqueKeysWithValues: refined.map { pocket, result in
            (pocket.rawValue, String(format: "%@ %.1f px", result.method.rawValue, result.shift))
        })
        let evidence = PocketLockEvidence(pockets: recorded, lines: lines, cameraPose: pose, intrinsics: k,
                                          normal: Vec3(0, 1, 0), tiltDegrees: 0, residual: 0,
                                          dropped: nil, size: .eightFoot)
        return SnappedPockets(rays: rays, imageTaps: taps, methods: methods, size: size, evidence: evidence)
    }

    /// Where a world direction lands in the camera image, pixels (top-left
    /// origin), or nil when it points behind the camera. The inverse of
    /// `worldRay(throughPixel:)`; same convention as ClothPlaneEstimator.
    static func imagePixel(of direction: Vec3, pose: Transform3D, intrinsics k: CameraIntrinsics) -> Vec2? {
        let camera = Vec3(pose.axis(0).dot(direction), pose.axis(1).dot(direction), pose.axis(2).dot(direction))
        guard camera.z < -1e-6 else { return nil }
        return Vec2(k.principalX + k.focalX * (camera.x / -camera.z),
                    k.principalY - k.focalY * (camera.y / -camera.z))
    }

    static func worldRay(throughPixel p: Vec2, pose: Transform3D, intrinsics k: CameraIntrinsics) -> TapRay {
        let camera = Vec3((p.x - k.principalX) / k.focalX, -((p.y - k.principalY) / k.focalY), -1)
        return TapRay(origin: pose.translation, direction: pose.transformDirection(camera).normalized)
    }

    /// Range to the nose-height point on a ball's sightline over range to
    /// the ball: the nose is 7.7 mm above a ball's centre, so on a sightline
    /// descending at angle a it is 7.7 mm / sin(a) nearer.
    static func noseRangeRatio(centre: Vec2, radius: Double, pose: Transform3D,
                               intrinsics k: CameraIntrinsics) -> Double {
        let ray = worldRay(throughPixel: centre, pose: pose, intrinsics: k)
        let descent = -ray.direction.y
        guard descent > 0.02, radius > 0 else { return 1 }
        let range = k.focalX * TableSizeFromImage.Ball.diameter / (2 * radius)
        let rise = PocketSnap.noseHeight - Ball.standardRadius
        return max(0.9, 1 - rise / descent / range)
    }

    /// Calibrate from pocket rays at cushion-nose height: the size from
    /// the image when it is decisive, the plane's height and tilt from the
    /// pockets, the table lowered to the cloth. Returns false with the
    /// reason shown when it refuses.
    func calibrateFromPocketRays(_ sightings: [(PocketID, CGPoint)],
                                 size chosen: TableSize,
                                 coordinator: ARSessionCoordinator,
                                 lockAfterProposing: Bool) -> Bool {
        let snapped = snapPockets(sightings, coordinator: coordinator)
        let rays = snapped?.rays ?? sightings.compactMap { pocket, point in
            coordinator.worldRay(through: point).map { (pocket: pocket, ray: $0) }
        }
        guard rays.count == sightings.count else {
            showRemoteFeedback("A pocket tap did not reach the camera; tap it again")
            return false
        }
        var names: [PocketID: Vec2] = [:]
        for (pocket, point) in sightings { names[pocket] = Vec2(point.x, point.y) }
        func name(_ pocket: PocketID) -> String { PocketSnap.viewName(pocket, taps: names) }

        // SIZE FIRST: the pockets cannot tell 7, 8 and 9 ft apart (all
        // 2:1), the image can. Applied only when decisive.
        let size: TableSize
        placement.sizeFromImage = snapped?.size
        if let measured = snapped?.size, measured.verdict.isDecisive {
            size = measured.verdict.nearest
            placement.sizeStatus = size == chosen
                ? "\(Self.sizeName(size)) (measured)"
                : "\(Self.sizeName(size)) (measured; setting was \(Self.sizeName(chosen)))"
        } else {
            size = chosen
            placement.sizeStatus = "\(Self.sizeName(chosen)) (size unverified)"
        }

        let fit: PocketCalibration.TiltedFit
        do {
            // A corner snapped onto one nose line is known across the
            // table, not along it (the near end's nose is not visible).
            let alongFree = Set((snapped?.methods ?? [:]).filter {
                $0.value == .ontoNose && $0.key != .sideTop && $0.key != .sideBottom
            }.keys)
            fit = try PocketCalibration.solveTilted(rays: rays, size: size, alongFree: alongFree)
        } catch {
            showRemoteFeedback("Pocket calibration refused: \(error)")
            return false
        }
        // Refuse a bad fit and say which tap to redo.
        guard fit.residual <= Self.pocketFitLimit else {
            let worst = fit.worst.map { name($0.pocket) } ?? "worst"
            let text = String(format: "Fit is %.0f cm out. Re-tap the %@ (%.0f cm off), "
                              + "on the corner where the cushion edges meet.",
                              fit.residual * 100, worst, (fit.worst?.error ?? 0) * 100)
            showRemoteFeedback(text)
            notePocketFit(text)
            return false
        }
        placement.pocketFitDetail = fit.summary
        placement.lockEvidence = snapped.map { snapped in
            var evidence = snapped.evidence
            evidence.size = size
            evidence.apply(fit)
            return evidence
        }
        let table = fit.lowered(by: PocketSnap.noseHeight)
        let height = table.origin.y
        guard commitPocketTable(table.worldCorners, size: size, height: height,
                                source: .pocketGeometry(spans: rays.count * (rays.count - 1) / 2,
                                                        residualMillimetres: Int((fit.residual * 1000).rounded())),
                                lockAfterProposing: lockAfterProposing) else { return false }
        placement.sizeCheckRays = rays
        noteSizeFromBalls(rays: rays, sightingsAboveCloth: PocketSnap.noseHeight)

        var line = String(format: "Pockets: %d sighted (%d snapped), cloth y=%.3f, fit %.1f mm rms",
                          rays.count, snapped?.snappedCount ?? 0, height, fit.residual * 1000)
        if let worst = fit.worst {
            line += String(format: ", worst %@ %.0f mm", worst.pocket.rawValue, worst.error * 1000)
        }
        line += String(format: ", tilt %.2f deg; size %@", fit.tiltDegrees, placement.sizeStatus ?? "?")
        if let dropped = fit.dropped {
            // Never silent: the table is built on the other five, and the
            // user is told which pocket to redo to get all six back.
            let tip = String(format: " Left out the %@: %.0f cm off the others. Re-tap it to use all six.",
                             name(dropped), (fit.droppedError ?? 0) * 100)
            line += "." + tip
        } else if rays.count < 6 {
            line += ". Tap the side pockets too for a checked fit."
        }
        showRemoteFeedback(line)
        Self.log.notice("\(line, privacy: .public) [\(fit.summary, privacy: .public)]")
        notePocketFit(line)
        return true
    }
}
