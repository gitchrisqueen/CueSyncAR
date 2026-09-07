//
//  ProjectionRoundTripTests.swift
//  PerceptionKitTests
//
//  Synthetic pinhole harness for the app's projection chain:
//
//      detection box → box CENTRE → PlaneGeometryRaycaster (intrinsics
//      unprojection, plane lifted one ball radius, dropped to cloth)
//      → TableCalibration.worldToTable
//
//  Balls are placed at exact table positions, imaged by SyntheticBallImager
//  into the silhouette boxes a detector would emit, fed through the real
//  DetectionProviding seam, and unprojected by the real raycaster. Every
//  number below is therefore attributable to geometry, not to a detector.
//
//  MEASURED 2026-09-07 (the tests print these; rerun to regenerate):
//
//  Ideal round trip (perfect calibration, box centre + lifted plane), four
//  player poses × 60-ball grid, ranges to 3.3 m: max error 0.34 mm
//  (head rail), 0.31 (side rail), 0.28 (high overhead), 0.29 (low far end).
//  The exact sphere-centre projection closes to < 1e-9 m, so the whole
//  residual is Case 1's bias.
//
//  Case 1 — silhouette-box centre vs projected sphere centre, iPhone wide
//  video intrinsics (f = 1400 px), 57.15 mm ball, ball on the image
//  diagonal. Zero on axis, second-order off it: tan β · sec² β · α² · f,
//  α = asin(r/d), matches to < 5 % at every cell.
//
//      β \ d    0.5 m     1.0 m     1.5 m     2.0 m     3.0 m
//       0°      0.000 px  0.000 px  0.000 px  0.000 px  0.000 px
//      10°      0.834 px  0.208 px  0.092 px  0.052 px  0.023 px
//      20°      1.892 px  0.472 px  0.210 px  0.118 px  0.052 px
//      30°      3.535 px  0.881 px  0.391 px  0.220 px  0.098 px
//      34°      4.509 px  1.123 px  0.499 px  0.281 px  0.125 px
//
//  Carried to the cloth by the app's chain, head-rail pose (camera 1.3 m
//  above the cloth, 0.73 m behind the head cushion), centreline balls;
//  the foot-point method (box bottom → cloth) shown for contrast — it is
//  first-order, r · tan(θ/2) SHORT toward the camera:
//
//      table x  range   off-axis  elevation  bias    chain err  foot err
//      -1.1 m   1.50 m   26.1°     57.8°      0.31 px  0.31 mm   16.1 mm
//      -0.7 m   1.75 m   14.9°     46.7°      0.11 px  0.17 mm   12.6 mm
//      -0.3 m   2.04 m    6.7°     38.5°      0.03 px  0.08 mm   10.2 mm
//       0.1 m   2.37 m    0.7°     32.4°      0.00 px  0.01 mm    8.5 mm
//       0.5 m   2.72 m    3.8°     27.9°      0.01 px  0.04 mm    7.3 mm
//       0.9 m   3.08 m    7.3°     24.4°      0.02 px  0.08 mm    6.3 mm
//       1.1 m   3.26 m    8.8°     23.0°      0.02 px  0.10 mm    5.9 mm
//      (cushion-side balls, y = ±0.55: up to 0.40 px / 0.34 mm / 16.2 mm)
//
//  Case 2 — rail-top taps, +4 cm, refit through fromCorners:
//    overhead 2.4 m: field 2.3797 × 1.1898 (+39.7 / +19.8 mm), every
//      corner 1.695 % further from centre; snaps to eightFoot; origin and
//      axes untouched → ball error 0 (absorbed by the snap).
//    overhead 1.2 m: +80.7 mm (3.45 %); still eightFoot.
//    head rail 1.5 m up / 0.6 m back: field 2.404 × 1.202 (+64 / +32 mm),
//      snaps eightFoot, but the ORIGIN shifts 48.5 mm away from the camera
//      → every ball off by 48.4–48.8 mm (a constant, not a percentage).
//    plane locked at rail height (+4 cm, extent right): balls land short by
//      h/(H−r) − (r/H)² = 1.672 % of distance from centre (2.4 m overhead).
//    snap thresholds: an inflated 8-ft flips to NINE-foot beyond +4.10 %
//      (taps 9.5 cm high at 2.4 m, 4.7 cm at 1.2 m) — long before the 8 %
//      tolerance; `.custom` only beyond +17.2 %. The 8 % edge is intact at
//      the 9-ft's upper side.
//
//  Case 3 — boxes imaged by the true camera, frame claiming other
//  intrinsics (head-rail pose, max / min error, share of balls > 10 cm):
//    focal +15 %: 18.2 / 0.7 cm, 27 %; 16:9 principal row (540 for 720):
//    29.4 / 1.3 cm, 62 %; portrait boxes with native intrinsics: 477 / 6.6
//    cm, 98 %; Vision y-flip forgotten: no hit / 11.0 cm, 100 %.
//
//  Case 4 — raycaster gate sin⁻¹(0.12) = 6.892° on the RAY: 5° and 6.84°
//  → nil; 6.94° and 10° → 0.00 mm. A camera 0.35 m up, 2 m behind the
//  head cushion projects 45 of 60 balls and rejects the 15 farthest.
//
//  FINDING (fixed in this change, guarded by
//  heightAwareRaycastDispatchesThroughTheExistential): the pipeline calls
//  the height-aware raycast through `any PlaneRaycasting`; as an
//  extension-only method it bound statically to the no-lift fallback, so
//  the sphere-centre method never engaged on device and every ball landed
//  r / tan(elevation) LONG — 61.4 mm at 25°, 29 mm at 45°.
//

import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

@Suite("Projection round trip (synthetic pinhole harness)")
struct ProjectionRoundTripTests {
    /// Ground truth: 8-ft table on the world y = 0 plane, table x = world x,
    /// table y = world −z, normal = world +y.
    static let truth = TableCalibration(origin: .zero,
                                        xAxis: Vec3(1, 0, 0),
                                        yAxis: Vec3(0, 0, -1),
                                        size: .eightFoot)

    /// Ball positions across the whole 2.34 × 1.17 m field, cushion to cushion.
    static let grid: [Vec2] = stride(from: -1.1, through: 1.1, by: 0.2).flatMap { x in
        [-0.55, -0.275, 0, 0.275, 0.55].map { y in Vec2(x, y) }
    }

    /// Player poses. Distances to the far cushion reach 3.3–3.7 m.
    enum Pose: String, CaseIterable {
        /// Standing at the head rail, phone at chest height.
        case headRail
        /// Standing at a side rail.
        case sideRail
        /// Phone held high over the head spot.
        case highOverhead
        /// Crouched at the far end: low elevation, long ranges.
        case lowFarEnd

        var camera: SyntheticCamera {
            let (at, target): (Vec3, Vec3) = switch self {
            case .headRail: (Vec3(-1.9, 1.3, 0), Vec3(0.2, 0, 0))
            case .sideRail: (Vec3(0, 1.1, 1.6), Vec3(0, 0, -0.2))
            case .highOverhead: (Vec3(-0.5, 2.0, 0.3), Vec3(0.3, 0, 0))
            case .lowFarEnd: (Vec3(-2.4, 0.9, 0), Vec3(0.4, 0, 0))
            }
            return SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                                   transform: SyntheticCamera.pose(at: at, lookingAt: target))
        }
    }

    /// The app's chain, line for line what PerceptionPipeline.process does
    /// with a detection: box centre → lifted-plane raycast → worldToTable.
    static func appChain(box: NormalizedRect, frame: CapturedFrame,
                         appCalibration: TableCalibration) -> Vec2? {
        let raycaster = PlaneGeometryRaycaster(calibration: appCalibration)
        let center = Vec2(box.x + box.width / 2, box.y + box.height / 2)
        return raycaster.raycastToTablePlane(imagePoint: center, frame: frame,
                                             planeHeightOffset: Ball.standardRadius)
            .map(appCalibration.worldToTable)
    }

    struct ChainSample {
        var ball: Vec2
        var distance: Double
        var offAxisDegrees: Double
        var elevationDegrees: Double
        var biasPixels: Double
        /// App chain (box centre + lifted plane) error on the cloth, metres.
        var chainError: Double
        /// Foot-point-on-cloth error for contrast, metres.
        var footError: Double
        /// Exact sphere-centre projection through the raycaster, metres.
        var exactError: Double
    }

    /// Image a ball with `camera` and run it through the chain with the
    /// calibration the app holds (`appCalibration`, ground truth unless a
    /// perturbation is under test).
    static func sample(camera: SyntheticCamera, ball: Vec2,
                       appCalibration: TableCalibration = truth,
                       frame: CapturedFrame? = nil) -> ChainSample? {
        let imager = SyntheticBallImager(camera: camera, calibration: truth)
        guard let silhouette = imager.silhouette(ballAt: ball),
              camera.contains(normalized: silhouette.box.center) else { return nil }
        let frame = frame ?? camera.frame()
        guard let chain = appChain(box: silhouette.box, frame: frame,
                                   appCalibration: appCalibration) else { return nil }
        let raycaster = PlaneGeometryRaycaster(calibration: appCalibration)
        let footPixel = silhouette.pixelBox.foot
        let foot = raycaster.raycastToTablePlane(
            imagePoint: camera.normalized(pixel: footPixel), frame: frame)
            .map(appCalibration.worldToTable)
        let exact = raycaster.raycastToTablePlane(
            imagePoint: camera.normalized(pixel: silhouette.projectedCenter), frame: frame,
            planeHeightOffset: Ball.standardRadius)
            .map(appCalibration.worldToTable)
        let sphere = silhouette.sphereCenter
        return ChainSample(
            ball: ball,
            distance: camera.position.distance(to: sphere),
            offAxisDegrees: camera.offAxisAngle(to: sphere) * 180 / .pi,
            elevationDegrees: camera.sightlineElevation(to: sphere, planeNormal: truth.normal) * 180 / .pi,
            biasPixels: silhouette.centerBias.length,
            chainError: chain.distance(to: ball),
            footError: foot.map { $0.distance(to: ball) } ?? .nan,
            exactError: exact.map { $0.distance(to: ball) } ?? .nan)
    }

    static func samples(pose: Pose, appCalibration: TableCalibration = truth,
                        frame: CapturedFrame? = nil) -> [ChainSample] {
        grid.compactMap { sample(camera: pose.camera, ball: $0,
                                 appCalibration: appCalibration, frame: frame) }
    }

    private func fmt(_ value: Double, _ digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    // MARK: - Conventions

    @Test func syntheticVisionBoxesFlipExactlyLikeTheApp() throws {
        // The imager emits the bottom-left box Vision would report and the
        // top-left box Detection2D carries; the app's flip must map one to
        // the other for every ball in view (pins the y-flip convention).
        for pose in Pose.allCases {
            let imager = SyntheticBallImager(camera: pose.camera, calibration: Self.truth)
            for ball in Self.grid {
                guard let s = imager.silhouette(ballAt: ball) else { continue }
                let flipped = VisionBoxMapping.topLeftRect(
                    fromVisionX: s.visionBox.x, y: s.visionBox.y,
                    width: s.visionBox.width, height: s.visionBox.height)
                #expect(abs(flipped.y - s.box.y) < 1e-12 && flipped.x == s.box.x)
            }
        }
    }

    @Test func raycasterAgreesWithTheIndependentCameraModel() throws {
        // The exact sphere-centre projection, unprojected by the app's
        // raycaster onto the lifted plane, must land on the ball to
        // floating-point precision: the two pinhole conventions agree.
        for pose in Pose.allCases {
            let samples = Self.samples(pose: pose)
            #expect(samples.count > 20, "\(pose)")
            let worst = samples.map(\.exactError).max() ?? .nan
            #expect(worst < 1e-9, "\(pose): exact-centre error \(worst) m")
            // And the raycaster's own forward projection matches the camera.
            let raycaster = PlaneGeometryRaycaster(calibration: Self.truth)
            for ball in Self.grid {
                let world = Self.truth.tableToWorld(ball)
                guard let expected = pose.camera.project(world) else { continue }
                let projected = try #require(raycaster.projectToImage(worldPoint: world,
                                                                      frame: pose.camera.frame()))
                #expect(projected.distance(to: expected) < 1e-12)
            }
        }
    }

    // MARK: - Ideal round trip

    @Test func idealRoundTripClosesWithinTwoMillimetres() {
        // Perfect calibration, no perturbation: the only error left in the
        // app's chain is the silhouette-centre bias (Case 1). Bar: ≤ 2 mm
        // across the whole field from every pose, ranges out to > 3 m.
        var maxDistance = 0.0
        for pose in Pose.allCases {
            let samples = Self.samples(pose: pose)
            let worst = samples.max { $0.chainError < $1.chainError }
            maxDistance = max(maxDistance, samples.map(\.distance).max() ?? 0)
            let worstError = worst?.chainError ?? .nan
            print("ideal round trip [\(pose.rawValue)]: \(samples.count) balls, "
                  + "max error \(fmt(worstError * 1000, 3)) mm at \(worst?.ball ?? .zero), "
                  + "range \(fmt(worst?.distance ?? 0)) m, "
                  + "elevation \(fmt(worst?.elevationDegrees ?? 0, 1))°")
            #expect(worstError <= 0.002, "\(pose): \(worstError) m")
            #expect(samples.count >= 20)
        }
        #expect(maxDistance >= 3.0, "grid must reach 3 m; reached \(maxDistance)")
    }

    @Test func heightAwareRaycastDispatchesThroughTheExistential() throws {
        // Regression guard for the finding that motivated the fix in
        // PlaneRaycasting: PerceptionPipeline holds `any PlaneRaycasting`,
        // and while the height-aware raycast was an extension-only method
        // the call bound statically to the fallback (no lift) — every ball
        // landed r / tan(elevation) long, 3–7 cm at player elevations.
        let camera = Pose.headRail.camera
        let existential: any PlaneRaycasting = PlaneGeometryRaycaster(calibration: Self.truth)
        let imager = SyntheticBallImager(camera: camera, calibration: Self.truth)
        let ball = Vec2(0.8, 0.4)
        let s = try #require(imager.silhouette(ballAt: ball))
        let liftedWorld = try #require(existential.raycastToTablePlane(
            imagePoint: s.box.center, frame: camera.frame(),
            planeHeightOffset: Ball.standardRadius))
        let flatWorld = try #require(existential.raycastToTablePlane(
            imagePoint: s.box.center, frame: camera.frame()))
        let lifted = Self.truth.worldToTable(liftedWorld)
        let flat = Self.truth.worldToTable(flatWorld)
        let elevation = camera.sightlineElevation(to: s.sphereCenter, planeNormal: Self.truth.normal)
        let flatBias = Ball.standardRadius / tan(elevation)
        print("existential dispatch: lifted error \(fmt(lifted.distance(to: ball) * 1000, 2)) mm, "
              + "flat (fallback) error \(fmt(flat.distance(to: ball) * 1000, 1)) mm "
              + "(r / tan θ = \(fmt(flatBias * 1000, 1)) mm)")
        #expect(lifted.distance(to: ball) < 0.002)
        #expect(abs(flat.distance(to: ball) - flatBias) < 0.001)
        #expect(flat.distance(to: ball) > 0.05)
    }

    @Test func realPipelineReproducesTheGroundTruth() async throws {
        // Same chain, but through the actual PerceptionPipeline actor with
        // the synthetic provider on the real DetectionProviding seam.
        let balls = [SyntheticBall(position: Vec2(-0.6, 0), label: "white-ball"),
                     SyntheticBall(position: Vec2(0.8, 0.4), label: "color-ball"),
                     SyntheticBall(position: Vec2(1.05, -0.5), label: "color-ball")]
        let camera = Pose.headRail.camera
        let pipeline = PerceptionPipeline(
            detector: SyntheticDetectionProvider(calibration: Self.truth, balls: balls),
            calibration: Self.truth,
            raycaster: PlaneGeometryRaycaster(calibration: Self.truth))
        var iterator = await pipeline.outputs.makeAsyncIterator()
        var lastState: TableState?
        for index in 0..<8 {
            await pipeline.ingest(camera.frame(timestamp: Double(index) / 15))
            lastState = await iterator.next()?.state
        }
        let state = try #require(lastState)
        #expect(state.balls.count == 3)
        for ball in balls {
            let tracked = try #require(state.balls.min {
                $0.position.distance(to: ball.position) < $1.position.distance(to: ball.position)
            })
            let error = tracked.position.distance(to: ball.position)
            #expect(error <= 0.002, "\(ball.position): \(error) m")
        }
        #expect(state.cueBall != nil)
    }

    // MARK: - Case 1: silhouette-centre bias across the field of view

    @Test func silhouetteCentreBiasIsQuantifiedAcrossTheFieldOfView() throws {
        // Pixel bias as a function of off-axis angle β and range d, pose-
        // independent (camera-space placement, ball diagonal from the axis).
        let camera = SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                                     transform: .identity)
        let imager = SyntheticBallImager(camera: camera, calibration: Self.truth)
        let angles: [Double] = [0, 10, 20, 30, 34]
        let ranges: [Double] = [0.5, 1.0, 1.5, 2.0, 3.0]
        var rows: [String] = ["    β \\ d     " + ranges.map { "\(fmt($0, 1)) m     " }.joined()]
        var previousRow: [Double]?
        for beta in angles {
            let rad = beta * .pi / 180
            // Off-axis along the image diagonal (x and y share the tilt).
            let direction = Vec3(sin(rad) / 2.0.squareRoot(), -sin(rad) / 2.0.squareRoot(), -cos(rad))
            var biases: [Double] = []
            for d in ranges {
                let s = try #require(imager.silhouette(sphereCenter: direction * d))
                biases.append(s.centerBias.length)
                // Closed form of the second-order term: the radial extremes
                // sit at β ± α, so the box centre overshoots tan β by
                // (tan(β+α) + tan(β−α))/2 − tan β ≈ tan β · sec² β · α².
                let alpha = asin(Ball.standardRadius / d)
                let predicted = 1400 * tan(rad) * alpha * alpha / (cos(rad) * cos(rad))
                if beta > 0 {
                    #expect(abs(s.centerBias.length / predicted - 1) < 0.05,
                            "β=\(beta)° d=\(d): \(s.centerBias.length) px vs \(predicted) px")
                }
            }
            rows.append("    \(fmt(beta, 0).padding(toLength: 3, withPad: " ", startingAt: 0))°      "
                        + biases.map { "\(fmt($0, 3)) px".padding(toLength: 10, withPad: " ", startingAt: 0) }
                            .joined())
            // Zero on axis; monotone in β at every range.
            if beta == 0 {
                #expect(biases.allSatisfy { $0 < 1e-9 })
            } else if let previous = previousRow {
                for (now, before) in zip(biases, previous) {
                    #expect(now > before)
                }
            }
            // Second order in α: doubling the range → a quarter of the bias.
            #expect(abs(biases[1] / biases[3] - 4) < 0.2 || beta == 0)
            previousRow = biases
        }
        print("Case 1 — silhouette-box centre bias (px), off-axis angle β vs range d:")
        rows.forEach { print($0) }
        // Worst case in the whole usable field of view (34° diagonal, 0.5 m)
        // is under 5 px; beyond 1 m it is under 1.2 px everywhere.
        #expect((previousRow?[0] ?? .infinity) < 5)
        #expect((previousRow?[1] ?? .infinity) < 1.2)

        // The same bias carried to the cloth by the app's chain, head-rail
        // pose, plus the foot-point method for contrast.
        let samples = Self.samples(pose: .headRail)
        print("Case 1 — head-rail pose, per ball: table (x,y) | range | off-axis | elevation | "
              + "bias px | chain err mm | foot-point err mm")
        for s in samples where abs(s.ball.y - 0.275) > 1e-9 && abs(s.ball.y + 0.275) > 1e-9 {
            print("    (\(fmt(s.ball.x, 1)),\(fmt(s.ball.y, 2))) | \(fmt(s.distance)) m | "
                  + "\(fmt(s.offAxisDegrees, 1))° | \(fmt(s.elevationDegrees, 1))° | "
                  + "\(fmt(s.biasPixels, 3)) | \(fmt(s.chainError * 1000, 2)) | \(fmt(s.footError * 1000, 1))")
        }
        let worstChain = samples.map(\.chainError).max() ?? .nan
        let worstFoot = samples.map(\.footError).max() ?? .nan
        let bestFoot = samples.map(\.footError).min() ?? .nan
        // Chain error is second-order (sub-mm). The foot point is FIRST
        // order: the box bottom is the lower tangent ray, which meets the
        // cloth r · tan(θ/2) SHORT of the contact point (θ = elevation) —
        // 6–16 mm from this pose before any detector shadow is added. The
        // closed form is exact in the vertical plane through the optical
        // axis (centreline balls); off-axis the image-vertical tangent
        // adds up to ~2 mm of lateral error on top.
        #expect(worstChain < 0.002)
        for s in samples {
            let predicted = Ball.standardRadius * tan(s.elevationDegrees * .pi / 360)
            let tolerance = abs(s.ball.y) < 1e-9 ? 0.0005 : 0.0025
            #expect(abs(s.footError - predicted) < tolerance,
                    "\(s.ball): foot error \(s.footError) vs r·tan(θ/2) = \(predicted)")
        }
        #expect(bestFoot > 0.005, "foot-point error min \(bestFoot) m")
        #expect(worstFoot > 0.015, "foot-point error max \(worstFoot) m")
    }

    // MARK: - Case 2: rail-top corner taps

    @Test func railTopTapsInflateTheFieldAndStillSnap() throws {
        let tapHeight = 0.04
        // (a) Overhead reference pose (camera foot at the field centre,
        // 2.4 m up): every corner slides radially out by
        // h / (H − h) = 0.04 / 2.36 = 1.695 % of its distance from centre.
        let overhead = Vec3(0, 2.4, 0)
        let overheadFit = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: overhead)
            .apply(to: Self.truth, sizeTolerance: 0)  // no snap: measure the raw field
        guard case let .custom(width, height) = overheadFit.size else {
            Issue.record("expected the raw measured size"); return
        }
        let scale = 2.4 / (2.4 - tapHeight)
        print("Case 2 — overhead 2.4 m, taps +4 cm: measured field "
              + "\(fmt(width, 4)) × \(fmt(height, 4)) m (true 2.34 × 1.17), "
              + "scale \(fmt((scale - 1) * 100, 3)) % of distance from centre, "
              + "width +\(fmt((width - 2.34) * 1000, 1)) mm, height +\(fmt((height - 1.17) * 1000, 1)) mm")
        #expect(abs(width / 2.34 - scale) < 1e-9)
        #expect(abs(height / 1.17 - scale) < 1e-9)
        #expect(abs((scale - 1) - 0.017) < 0.0005)
        #expect(abs(width - 2.34 - 0.0397) < 0.0005)
        // With the app's 8 % tolerance the inflated field still snaps to
        // eight-foot, the origin/axes are untouched (symmetric inflation),
        // so ball positions through the chain are exact: this error class
        // is absorbed entirely by the size snap.
        let snapped = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: overhead).apply(to: Self.truth)
        #expect(snapped.size == .eightFoot)
        #expect(snapped.origin.length < 1e-12)
        let overheadCamera = SyntheticCamera(
            intrinsics: SyntheticCamera.iPhoneWideVideo,
            transform: SyntheticCamera.pose(at: overhead, lookingAt: .zero))
        let overheadErrors = Self.grid.compactMap {
            Self.sample(camera: overheadCamera, ball: $0, appCalibration: snapped)?.chainError
        }
        #expect(overheadErrors.count == Self.grid.count)
        #expect((overheadErrors.max() ?? .nan) < 0.002)

        // (b) A lower overhead pose (phone held 1.2 m over the centre):
        // 3.45 % → the field measures ~+8 cm long and STILL snaps to 8-ft.
        let lowFit = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: Vec3(0, 1.2, 0))
            .apply(to: Self.truth, sizeTolerance: 0)
        guard case let .custom(lowWidth, _) = lowFit.size else {
            Issue.record("expected the raw measured size"); return
        }
        print("Case 2 — overhead 1.2 m, taps +4 cm: width +\(fmt((lowWidth - 2.34) * 1000, 1)) mm "
              + "(\(fmt((lowWidth / 2.34 - 1) * 100, 2)) %)")
        #expect(abs(lowWidth - 2.34 - 0.0807) < 0.001)
        #expect(try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: Vec3(0, 1.2, 0))
            .apply(to: Self.truth).size == .eightFoot)

        // (c) Where the snap actually breaks. TableSize.inferred keeps the
        // 8 % tolerance, but between 8-ft and 9-ft (8.5 % apart) the
        // NEAREST standard size wins first: an inflated 8-ft flips to 9-ft
        // long before the 8 % tolerance is reached, and never becomes
        // `.custom` until it is 8 % past the 9-ft (≈ +17 %).
        var flipScale: Double?
        var customScale: Double?
        for step in 1...2000 {
            let s = 1 + Double(step) * 1e-4
            let size = TableSize.inferred(width: 2.34 * s, height: 1.17 * s, tolerance: 0.08)
            if flipScale == nil, size == .nineFoot { flipScale = s }
            if customScale == nil, size == nil { customScale = s }
        }
        let flip = try #require(flipScale)
        let custom = try #require(customScale)
        // Tap height that produces the flip from a given camera height:
        // h = H (1 − 1/s).
        print("Case 2 — 8-ft snaps to 9-ft beyond +\(fmt((flip - 1) * 100, 2)) % "
              + "(tap height \(fmt(2.4 * (1 - 1 / flip) * 100, 1)) cm at 2.4 m, "
              + "\(fmt(1.2 * (1 - 1 / flip) * 100, 1)) cm at 1.2 m); "
              + "no standard size beyond +\(fmt((custom - 1) * 100, 2)) %")
        // Flip where the two relative errors meet: s − 1 = 1 − s·2.34/2.54
        // → s = 1.0410; custom past 1.08 × 2.54 / 2.34 = 1.1723.
        #expect(abs(flip - 1.0410) < 0.0002)
        #expect(abs(custom - 1.1723) < 0.0002)
        // The 8 % tolerance itself is intact — visible at the 9-ft's upper
        // edge, where no larger standard size can take over.
        #expect(TableSize.inferred(width: 2.54 * 1.079, height: 1.27 * 1.079, tolerance: 0.08) == .nineFoot)
        #expect(TableSize.inferred(width: 2.54 * 1.081, height: 1.27 * 1.081, tolerance: 0.08) == nil)

        // (d) The realistic tapping pose — head rail, 1.5 m up, 0.6 m back
        // — is asymmetric: near corners slide a little, far corners a lot.
        // The field inflates AND the origin shifts away from the camera,
        // which then offsets every ball by a constant, not a percentage.
        let headRailCamera = Vec3(-1.77, 1.5, 0)
        let asymmetricFit = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: headRailCamera)
            .apply(to: Self.truth, sizeTolerance: 0)
        guard case let .custom(aWidth, aHeight) = asymmetricFit.size else {
            Issue.record("expected the raw measured size"); return
        }
        let asymmetric = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: headRailCamera).apply(to: Self.truth)
        let shifted = Self.samples(pose: .headRail, appCalibration: asymmetric)
        let shiftedErrors = shifted.map(\.chainError)
        print("Case 2 — head-rail taps (camera 1.5 m up, 0.6 m behind the head cushion): field "
              + "\(fmt(aWidth, 3)) × \(fmt(aHeight, 3)) m (+\(fmt((aWidth - 2.34) * 1000, 0)) mm, "
              + "+\(fmt((aHeight - 1.17) * 1000, 0)) mm), snapped \(asymmetric.size), "
              + "origin shift \(fmt(asymmetric.origin.x * 1000, 1)) mm; ball error "
              + "min \(fmt((shiftedErrors.min() ?? 0) * 1000, 1)) / max \(fmt((shiftedErrors.max() ?? 0) * 1000, 1)) mm")
        #expect(asymmetric.size == .eightFoot)
        #expect(aWidth - 2.34 > 0.06 && aWidth - 2.34 < 0.07)
        #expect(asymmetric.origin.x > 0.045 && asymmetric.origin.x < 0.05)
        #expect((shiftedErrors.min() ?? 0) > 0.045)
        #expect((shiftedErrors.max() ?? 0) < 0.05)

        // (e) Plane locked at rail height (calibration +4 cm, extent right):
        // the sphere-centre ray meets the lifted plane (h + r) early, so
        // every ball lands SHORT of truth, toward the camera foot, by
        // h / (H − r) of its horizontal distance from that foot — 1.69 %
        // from 2.4 m overhead, i.e. "≈ 1.7 % of distance from centre".
        // The box-centre bias (Case 1) takes back (r/H)² = 0.014 %.
        let liftedPlane = try CalibrationPerturbation.planeHeight(tapHeight).apply(to: Self.truth)
        var liftedRatios: [Double] = []
        for ball in Self.grid where ball.length > 0.3 {
            guard let s = Self.sample(camera: overheadCamera, ball: ball, appCalibration: liftedPlane)
            else { continue }
            liftedRatios.append(s.chainError / ball.length)
        }
        let expectedRatio = tapHeight / (2.4 - Ball.standardRadius)
        let biasRatio = (Ball.standardRadius / 2.4) * (Ball.standardRadius / 2.4)
        print("Case 2 — plane at rail height, 2.4 m overhead: ball error / distance from centre = "
              + "\(fmt((liftedRatios.min() ?? 0) * 100, 3))–\(fmt((liftedRatios.max() ?? 0) * 100, 3)) % "
              + "(closed form h/(H−r) = \(fmt(expectedRatio * 100, 3)) % minus (r/H)² = \(fmt(biasRatio * 100, 3)) %)")
        #expect(liftedRatios.count > 40)
        for ratio in liftedRatios {
            #expect(abs(ratio - (expectedRatio - biasRatio)) < 2e-5)
        }
    }

    // MARK: - Case 3: intrinsics / resolution / orientation mismatch

    /// Worst-case chain error when the frame CLAIMS `claimed` intrinsics
    /// (and orientation) but the boxes were imaged by the true head-rail
    /// camera — the bug class where a wrong camera format, a stale
    /// resolution or a rotated image silently ruins every overlay.
    struct MismatchResult {
        var max: Double
        var min: Double
        /// Share of imaged balls landing > 10 cm off (or not landing at all).
        var fractionOverTenCentimetres: Double
    }

    private func mismatchError(claimed: CameraIntrinsics,
                               orientation: ImageOrientation = .up,
                               flipMissing: Bool = false) async throws -> MismatchResult {
        let camera = Pose.headRail.camera
        var trueCamera = camera
        trueCamera.orientation = orientation
        let provider = SyntheticDetectionProvider(
            calibration: Self.truth,
            balls: Self.grid.map { SyntheticBall(position: $0) },
            imaging: .fixed(trueCamera))
        let claimedFrame = CapturedFrame(timestamp: 0, cameraTransform: camera.transform,
                                         image: FixtureImageBuffer(), intrinsics: claimed)
        let detections = try await provider.detect(in: claimedFrame)
        var errors: [Double] = []
        for (detection, ball) in zip(detections, Self.grid.filter { ball in
            SyntheticBallImager(camera: trueCamera, calibration: Self.truth)
                .silhouette(ballAt: ball).map { trueCamera.contains(normalized: $0.box.center) } ?? false
        }) {
            var box = detection.boundingBox
            if flipMissing {
                // A Vision box used as-is (bottom-left origin never flipped).
                box = NormalizedRect(x: box.x, y: 1 - box.y - box.height,
                                     width: box.width, height: box.height)
            }
            guard let position = Self.appChain(box: box, frame: claimedFrame,
                                               appCalibration: Self.truth) else {
                errors.append(.infinity)
                continue
            }
            errors.append(position.distance(to: ball))
        }
        #expect(errors.count >= 20)
        let over = errors.filter { $0 > 0.10 }.count
        return MismatchResult(max: errors.max() ?? .nan, min: errors.min() ?? .nan,
                              fractionOverTenCentimetres: Double(over) / Double(errors.count))
    }

    @Test func intrinsicsResolutionOrientationMismatchIsCaught() async throws {
        let native = SyntheticCamera.iPhoneWideVideo
        // Control: consistent intrinsics pass the 2 mm bar.
        let control = try await mismatchError(claimed: native)
        #expect(control.max < 0.002)

        // Focal length from a different format (+15 %).
        var focal = native
        focal.focalX *= 1.15
        focal.focalY *= 1.15
        let focalError = try await mismatchError(claimed: focal)
        // Resolution: intrinsics believed to be for 1920×1080 16:9 (same
        // focal, principal point at 540) while the frame is 4:3 1920×1440.
        let sixteenNine = CameraIntrinsics(focalX: 1400, focalY: 1400,
                                           principalX: 960, principalY: 540,
                                           imageWidth: 1920, imageHeight: 1080)
        let resolutionError = try await mismatchError(claimed: sixteenNine)
        // Orientation: boxes from a portrait (rotated) image, native intrinsics.
        let orientationError = try await mismatchError(claimed: native, orientation: .right)
        // The Vision y-flip forgotten.
        let flipError = try await mismatchError(claimed: native, flipMissing: true)

        func describe(_ name: String, _ r: MismatchResult) -> String {
            "\(name) max \(fmt(r.max * 100, 1)) / min \(fmt(r.min * 100, 1)) cm, "
                + "\(fmt(r.fractionOverTenCentimetres * 100, 0)) % of balls > 10 cm"
        }
        print("Case 3 — mismatch, chain error over the field (head-rail pose): "
              + "control max \(fmt(control.max * 1000, 2)) mm; "
              + describe("focal +15 %:", focalError) + "; "
              + describe("16:9 resolution:", resolutionError) + "; "
              + describe("portrait orientation:", orientationError) + "; "
              + describe("missing y-flip:", flipError))
        // Every mismatch exceeds 10 cm — the bar the 2 mm round-trip test
        // fails on, so the harness catches the whole class.
        #expect(focalError.max > 0.10)
        #expect(resolutionError.max > 0.10)
        #expect(orientationError.max > 0.10)
        #expect(flipError.max > 0.10)
        // Not an edge effect: a quarter of the field for a 15 % focal
        // error, most of it for the wrong principal row, and the
        // flip/rotation cases leave no ball right.
        #expect(focalError.fractionOverTenCentimetres > 0.2)
        #expect(resolutionError.fractionOverTenCentimetres > 0.5)
        #expect(orientationError.fractionOverTenCentimetres > 0.9)
        #expect(flipError.fractionOverTenCentimetres > 0.9)
        #expect(orientationError.min > 0.05)
        #expect(flipError.min > 0.10)
    }

    // MARK: - Case 4: grazing rays

    @Test func camerasBelowSevenDegreesReturnNil() throws {
        // A phone resting on the rail: camera low, ball 2 m away. Aim the
        // camera at the ball so the ray elevation IS the sightline
        // elevation, then sweep it through the raycaster's 7° gate.
        let ball = Vec2(0.5, 0)
        let sphere = Self.truth.tableToWorld(ball) + Self.truth.normal * Ball.standardRadius
        let horizontal = 2.0
        func result(elevationDegrees: Double) -> (position: Vec2?, elevation: Double)? {
            let height = sphere.y + horizontal * tan(elevationDegrees * .pi / 180)
            let camera = SyntheticCamera(
                intrinsics: SyntheticCamera.iPhoneWideVideo,
                transform: SyntheticCamera.pose(at: Vec3(sphere.x - horizontal, height, 0),
                                                lookingAt: sphere))
            let imager = SyntheticBallImager(camera: camera, calibration: Self.truth)
            guard let s = imager.silhouette(ballAt: ball) else { return nil }
            let elevation = camera.sightlineElevation(to: sphere, planeNormal: Self.truth.normal)
            return (Self.appChain(box: s.box, frame: camera.frame(), appCalibration: Self.truth),
                    elevation * 180 / .pi)
        }
        let gateDegrees = asin(PlaneGeometryRaycaster.minimumIncidenceSine) * 180 / .pi
        let below = try #require(result(elevationDegrees: 5))
        let justBelow = try #require(result(elevationDegrees: gateDegrees - 0.05))
        let justAbove = try #require(result(elevationDegrees: gateDegrees + 0.05))
        let above = try #require(result(elevationDegrees: 10))
        print("Case 4 — gate sin⁻¹(0.12) = \(fmt(gateDegrees, 3))°: 5° → \(String(describing: below.position)); "
              + "\(fmt(justBelow.elevation, 2))° → \(String(describing: justBelow.position)); "
              + "\(fmt(justAbove.elevation, 2))° → error "
              + "\(fmt((justAbove.position?.distance(to: ball) ?? .nan) * 1000, 2)) mm; "
              + "10° → error \(fmt((above.position?.distance(to: ball) ?? .nan) * 1000, 2)) mm")
        #expect(abs(gateDegrees - 6.892) < 0.001)
        #expect(below.position == nil)
        #expect(justBelow.position == nil)
        #expect(justAbove.position != nil)
        #expect((justAbove.position?.distance(to: ball) ?? .infinity) < 0.002)
        #expect((above.position?.distance(to: ball) ?? .infinity) < 0.002)
        // The gate is on the RAY, not the camera: a camera at 10° whose
        // far-field pixels dip under 7° returns nil for those pixels only.
        let lowCamera = SyntheticCamera(
            intrinsics: SyntheticCamera.iPhoneWideVideo,
            transform: SyntheticCamera.pose(at: Vec3(-2.0, 0.35, 0), lookingAt: Vec3(0.5, 0, 0)))
        var rejected = 0
        var accepted = 0
        for target in Self.grid {
            guard let s = Self.sample(camera: lowCamera, ball: target) else {
                let world = Self.truth.tableToWorld(target) + Self.truth.normal * Ball.standardRadius
                if lowCamera.sightlineElevation(to: world, planeNormal: Self.truth.normal) < gateDegrees * .pi / 180 {
                    rejected += 1
                }
                continue
            }
            accepted += 1
            #expect(s.elevationDegrees >= gateDegrees - 0.05)
            #expect(s.chainError < 0.002)
        }
        print("Case 4 — camera 0.35 m up, 2 m behind the head cushion: \(accepted) balls projected, "
              + "\(rejected) rejected as grazing")
        #expect(rejected > 0 && accepted > 0)
    }
}
