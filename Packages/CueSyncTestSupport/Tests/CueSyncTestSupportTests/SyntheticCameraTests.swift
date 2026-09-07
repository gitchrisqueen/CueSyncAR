import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import CueSyncTestSupport

/// Table on the world y = 0 plane: table x = world x, table y = world −z,
/// normal = world +y (the convention the PerceptionKit tests use).
private let clothCalibration = TableCalibration(origin: .zero,
                                                xAxis: Vec3(1, 0, 0),
                                                yAxis: Vec3(0, 0, -1),
                                                size: .eightFoot)

@Suite("SyntheticCamera")
struct SyntheticCameraTests {
    private let camera = SyntheticCamera(
        intrinsics: SyntheticCamera.iPhoneWideVideo,
        transform: SyntheticCamera.pose(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0)))

    @Test func lookAtPutsTheTargetOnThePrincipalPoint() throws {
        let pixel = try #require(camera.projectPixel(Vec3(0.2, 0, 0)))
        #expect(abs(pixel.x - 960) < 1e-9)
        #expect(abs(pixel.y - 720) < 1e-9)
        // Pose is rigid: orthonormal columns, unit forward.
        for i in 0..<3 {
            #expect(abs(camera.transform.axis(i).length - 1) < 1e-12)
            for j in (i + 1)..<3 {
                #expect(abs(camera.transform.axis(i).dot(camera.transform.axis(j))) < 1e-12)
            }
        }
        #expect(abs(camera.forward.dot((Vec3(0.2, 0, 0) - camera.position).normalized) - 1) < 1e-12)
    }

    @Test func imageYGrowsDownwardAndXGrowsRight() throws {
        // A point nearer the camera on the cloth is LOWER in the image.
        let far = try #require(camera.projectPixel(Vec3(1.0, 0, 0)))
        let near = try #require(camera.projectPixel(Vec3(-1.0, 0, 0)))
        #expect(near.y > far.y)
        // Camera right = forward × up = (+x) × (+y) = world +z, which is
        // table −y: the table's +y side appears on the LEFT of the image.
        let right = try #require(camera.projectPixel(Vec3(0.2, 0, 0.5)))
        #expect(right.x > 960)
        let tableLeft = try #require(camera.projectPixel(clothCalibration.tableToWorld(Vec2(0.2, 0.5))))
        #expect(tableLeft.x < 960)
    }

    @Test func rayThroughProjectionReturnsToThePoint() throws {
        let points = [Vec3(0.3, 0, 0.4), Vec3(-1.1, 0.0286, -0.5), Vec3(1.17, 0.2, 0.585)]
        for world in points {
            let normalized = try #require(camera.project(world))
            let ray = camera.ray(throughNormalized: normalized)
            let t = (world - ray.origin).dot(ray.direction)
            let recovered = ray.origin + ray.direction * t
            #expect(recovered.distance(to: world) < 1e-9)
        }
    }

    @Test func pointsBehindTheCameraDoNotProject() {
        #expect(camera.project(camera.position - camera.forward) == nil)
    }

    @Test func overheadPoseIsWellDefined() throws {
        let overhead = SyntheticCamera(
            intrinsics: SyntheticCamera.iPhoneWideVideo,
            transform: SyntheticCamera.pose(at: Vec3(0, 2, 0), lookingAt: .zero))
        let pixel = try #require(overhead.projectPixel(.zero))
        #expect(abs(pixel.x - 960) < 1e-9 && abs(pixel.y - 720) < 1e-9)
        #expect(overhead.forward.distance(to: Vec3(0, -1, 0)) < 1e-12)
    }

    @Test func elevationAndOffAxisAngles() {
        let cameraAtHeight = SyntheticCamera(
            intrinsics: SyntheticCamera.iPhoneWideVideo,
            transform: SyntheticCamera.pose(at: Vec3(0, 1, 0), lookingAt: Vec3(1, 0, 0)))
        // 1 m up, 1 m across → 45° to the plane, on the optical axis.
        #expect(abs(cameraAtHeight.sightlineElevation(to: Vec3(1, 0, 0), planeNormal: Vec3(0, 1, 0))
                    - .pi / 4) < 1e-12)
        #expect(cameraAtHeight.offAxisAngle(to: Vec3(1, 0, 0)) < 1e-12)
    }

    @Test func frameCarriesPoseIntrinsicsAndResolution() {
        let frame = camera.frame(timestamp: 3)
        #expect(frame.intrinsics == SyntheticCamera.iPhoneWideVideo)
        #expect(frame.cameraTransform == camera.transform)
        #expect(frame.image?.width == 1920 && frame.image?.height == 1440)
        #expect(frame.timestamp == 3)
    }

    @Test func orientationMappingsRoundTrip() {
        let p = Vec2(0.2, 0.7)
        for orientation in ImageOrientation.allCases {
            let back = orientation.toNativeNormalized(orientation.apply(toNativeNormalized: p))
            #expect(back.distance(to: p) < 1e-12, "\(orientation)")
        }
        // Native top-left corner region rotates to the top-right under a
        // clockwise quarter turn.
        let rotated = ImageOrientation.right.apply(
            toNativeNormalized: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.2))
        #expect(abs(rotated.x - 0.8) < 1e-12 && abs(rotated.y) < 1e-12)
        #expect(abs(rotated.width - 0.2) < 1e-12 && abs(rotated.height - 0.1) < 1e-12)
    }
}

@Suite("SyntheticBallImager")
struct SyntheticBallImagerTests {
    private func imager(at position: Vec3, lookingAt target: Vec3,
                        orientation: ImageOrientation = .up) -> SyntheticBallImager {
        SyntheticBallImager(
            camera: SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                                    transform: SyntheticCamera.pose(at: position, lookingAt: target),
                                    orientation: orientation),
            calibration: clothCalibration)
    }

    @Test func onAxisSphereIsACircleWithZeroBias() throws {
        let r = Ball.standardRadius
        // Camera 1.5 m from the sphere centre, aimed exactly at it.
        let sphere = Vec3(0.4, r, 0)
        let imager = imager(at: sphere + Vec3(-0.9, 1.2, 0), lookingAt: sphere)
        let silhouette = try #require(imager.silhouette(ballAt: Vec2(0.4, 0)))
        let distance = imager.camera.position.distance(to: sphere)
        let expectedRadiusPx = 1400 * tan(asin(r / distance))
        #expect(abs(silhouette.pixelBox.width / 2 - expectedRadiusPx) < 1e-9)
        #expect(abs(silhouette.pixelBox.height / 2 - expectedRadiusPx) < 1e-9)
        #expect(silhouette.centerBias.length < 1e-9)
        #expect(silhouette.projectedCenter.distance(to: Vec2(960, 720)) < 1e-9)
    }

    /// Brute force: sample the tangent cone densely and take the extremes.
    private func sampledBox(camera: SyntheticCamera, sphere: Vec3, radius: Double) -> PixelRect {
        let c = camera.cameraSpace(sphere)
        let d = c.length
        let u = c / d
        let alpha = asin(radius / d)
        let seed = abs(u.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        let e1 = u.cross(seed).normalized
        let e2 = u.cross(e1)
        var box = PixelRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        let samples = 20_000
        for i in 0..<samples {
            let phi = Double(i) / Double(samples) * 2 * .pi
            let w = u * cos(alpha) + (e1 * cos(phi) + e2 * sin(phi)) * sin(alpha)
            let p = camera.pixel(normalizedRay: Vec2(w.x / -w.z, w.y / -w.z))
            box.minX = min(box.minX, p.x)
            box.maxX = max(box.maxX, p.x)
            box.minY = min(box.minY, p.y)
            box.maxY = max(box.maxY, p.y)
        }
        return box
    }

    @Test func closedFormBoxMatchesSampledTangentCone() throws {
        let poses: [(Vec3, Vec3)] = [
            (Vec3(-1.9, 1.3, 0), Vec3(0.2, 0, 0)),
            (Vec3(0.3, 0.9, 1.4), Vec3(-0.2, 0, -0.3)),
            (Vec3(-0.4, 2.0, 0.2), Vec3(0.3, 0, 0))
        ]
        let balls = [Vec2(-1.1, -0.55), Vec2(0, 0), Vec2(1.1, 0.5), Vec2(0.6, -0.3), Vec2(-0.5, 0.4)]
        for (position, target) in poses {
            let imager = imager(at: position, lookingAt: target)
            for ball in balls {
                let silhouette = try #require(imager.silhouette(ballAt: ball))
                let sampled = sampledBox(camera: imager.camera,
                                         sphere: silhouette.sphereCenter,
                                         radius: Ball.standardRadius)
                // Sampling every 0.018° under-estimates each extreme by a
                // second-order sliver; the closed form must sit just outside.
                #expect(abs(silhouette.pixelBox.minX - sampled.minX) < 1e-4)
                #expect(abs(silhouette.pixelBox.maxX - sampled.maxX) < 1e-4)
                #expect(abs(silhouette.pixelBox.minY - sampled.minY) < 1e-4)
                #expect(abs(silhouette.pixelBox.maxY - sampled.maxY) < 1e-4)
                #expect(silhouette.pixelBox.minX <= sampled.minX + 1e-9)
                #expect(silhouette.pixelBox.maxX >= sampled.maxX - 1e-9)
            }
        }
    }

    @Test func biasIsSecondOrderInAngularRadius() throws {
        // Same direction, doubled distance → quarter the bias (α ∝ 1/d).
        let camera = SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                                     transform: .identity)
        let imager = SyntheticBallImager(camera: camera, calibration: clothCalibration)
        let direction = Vec3(0.5, -0.3, -1).normalized  // ~30° off axis
        let near = try #require(imager.silhouette(sphereCenter: direction * 0.8))
        let far = try #require(imager.silhouette(sphereCenter: direction * 1.6))
        #expect(near.centerBias.length > 0.5)
        let ratio = near.centerBias.length / far.centerBias.length
        #expect(abs(ratio - 4) < 0.1, "ratio \(ratio)")
        // Bias points AWAY from the principal point (tan is convex).
        let outward = (near.projectedCenter - Vec2(960, 720)).normalized
        #expect(near.centerBias.normalized.dot(outward) > 0.99)
    }

    @Test func unboundedOrHiddenSilhouettesAreNil() {
        let camera = SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                                     transform: .identity)
        let imager = SyntheticBallImager(camera: camera, calibration: clothCalibration)
        // Behind the camera.
        #expect(imager.silhouette(sphereCenter: Vec3(0, 0, 1)) == nil)
        // Camera inside the sphere.
        #expect(imager.silhouette(sphereCenter: Vec3(0, 0, -0.01)) == nil)
        // Tangent cone reaches the image plane (89.5° off axis).
        #expect(imager.silhouette(sphereCenter: Vec3(2, 0, -0.0175)) == nil)
    }

    @Test func visionBoxIsTheBottomLeftFormOfTheDetectionBox() throws {
        let imager = imager(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0))
        let s = try #require(imager.silhouette(ballAt: Vec2(0.5, 0.3)))
        // Vision: y measured from the bottom edge, so y_vision + h + y_top = 1.
        #expect(abs(s.visionBox.y + s.visionBox.height + s.box.y - 1) < 1e-12)
        #expect(s.visionBox.x == s.box.x && s.visionBox.width == s.box.width)
        // Native normalization is the pixel box over the sensor size.
        #expect(abs(s.box.x * 1920 - s.pixelBox.minX) < 1e-9)
        #expect(abs(s.box.y * 1440 - s.pixelBox.minY) < 1e-9)
        #expect(abs(s.box.center.x * 1920 - s.pixelBox.center.x) < 1e-9)
    }

    @Test func orientationRotatesTheDeliveredBoxOnly() throws {
        let native = try #require(
            imager(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0)).silhouette(ballAt: Vec2(0.5, 0.3)))
        let portrait = try #require(
            imager(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0), orientation: .right)
                .silhouette(ballAt: Vec2(0.5, 0.3)))
        #expect(portrait.pixelBox == native.pixelBox)
        #expect(portrait.box == ImageOrientation.right.apply(toNativeNormalized: native.box))
        #expect(portrait.box != native.box)
    }

    @Test func detectionCarriesLabelAndBox() throws {
        let imager = imager(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0))
        let detection = try #require(imager.detection(ballAt: Vec2(0.5, 0.3), label: "white-ball"))
        #expect(detection.classLabel == "white-ball")
        #expect(detection.ballKind == .cue)
        #expect(detection.boundingBox == imager.silhouette(ballAt: Vec2(0.5, 0.3))?.box)
    }
}

@Suite("SyntheticDetectionProvider")
struct SyntheticDetectionProviderTests {
    private let camera = SyntheticCamera(
        intrinsics: SyntheticCamera.iPhoneWideVideo,
        transform: SyntheticCamera.pose(at: Vec3(-1.9, 1.3, 0), lookingAt: Vec3(0.2, 0, 0)))

    @Test func meetsTheProviderContract() async {
        let provider = SyntheticDetectionProvider(
            calibration: clothCalibration,
            balls: [SyntheticBall(position: .zero, label: "white-ball")])
        let failures = await ProviderContracts.checkDetectionProvider(
            provider, sampleFrame: camera.frame())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test func imagesWithTheFrameCameraByDefault() async throws {
        let balls = [SyntheticBall(position: Vec2(-0.6, 0), label: "white-ball"),
                     SyntheticBall(position: Vec2(0.8, 0.4), label: "color-ball", confidence: 0.7)]
        let provider = SyntheticDetectionProvider(calibration: clothCalibration, balls: balls)
        let detections = try await provider.detect(in: camera.frame())
        let imager = SyntheticBallImager(camera: camera, calibration: clothCalibration)
        #expect(detections.count == 2)
        #expect(detections[0].boundingBox == imager.silhouette(ballAt: Vec2(-0.6, 0))?.box)
        #expect(detections[1].confidence == 0.7)
        #expect(detections[1].classLabel == "color-ball")
    }

    @Test func framesWithoutIntrinsicsYieldNothing() async throws {
        let provider = SyntheticDetectionProvider(
            calibration: clothCalibration,
            balls: [SyntheticBall(position: .zero)])
        let frame = CapturedFrame(timestamp: 0, cameraTransform: camera.transform)
        #expect(try await provider.detect(in: frame).isEmpty)
    }

    @Test func fixedCameraIgnoresTheFramePose() async throws {
        let provider = SyntheticDetectionProvider(
            calibration: clothCalibration,
            balls: [SyntheticBall(position: .zero)],
            imaging: .fixed(camera))
        let elsewhere = CapturedFrame(timestamp: 0, cameraTransform: .identity,
                                      intrinsics: SyntheticCamera.iPhoneWideVideo)
        let fromElsewhere = try await provider.detect(in: elsewhere)
        let fromCamera = try await provider.detect(in: camera.frame())
        #expect(fromElsewhere == fromCamera)
        #expect(fromCamera.count == 1)
    }

    @Test func ballsOutsideTheImageAreOmitted() async throws {
        // Ball behind the camera and one way off to the side: neither
        // lands in the frame.
        let provider = SyntheticDetectionProvider(
            calibration: clothCalibration,
            balls: [SyntheticBall(position: Vec2(-3, 0)), SyntheticBall(position: Vec2(0, 6))])
        #expect(try await provider.detect(in: camera.frame()).isEmpty)
    }
}

@Suite("CalibrationPerturbation")
struct CalibrationPerturbationTests {
    @Test func trueCornersRefitReproduceTheCalibration() throws {
        let corners = CalibrationPerturbation.trueCorners(of: clothCalibration)
        let refit = try TableCalibration.fromCorners(corners)
        #expect(refit.origin.distance(to: clothCalibration.origin) < 1e-12)
        #expect(refit.xAxis.distance(to: clothCalibration.xAxis) < 1e-12)
        #expect(refit.yAxis.distance(to: clothCalibration.yAxis) < 1e-12)
        #expect(refit.size == .eightFoot)
        let zero = try CalibrationPerturbation.cornerOffsets([.zero, .zero, .zero, .zero])
            .apply(to: clothCalibration)
        #expect(zero == refit)
    }

    @Test func cornerOffsetsShiftTheFit() throws {
        let shifted = try CalibrationPerturbation
            .cornerOffsets(Array(repeating: Vec3(0.05, 0, 0), count: 4))
            .apply(to: clothCalibration)
        #expect(abs(shifted.origin.x - 0.05) < 1e-12)
        #expect(shifted.size == .eightFoot)
        #expect(throws: CalibrationPerturbationError.needFourOffsets) {
            try CalibrationPerturbation.cornerOffsets([.zero]).apply(to: clothCalibration)
        }
    }

    @Test func planeHeightLiftsTheOriginOnly() throws {
        let lifted = try CalibrationPerturbation.planeHeight(0.04).apply(to: clothCalibration)
        #expect(lifted.origin.distance(to: Vec3(0, 0.04, 0)) < 1e-12)
        #expect(lifted.xAxis == clothCalibration.xAxis && lifted.yAxis == clothCalibration.yAxis)
        #expect(lifted.size == .eightFoot)
    }

    @Test func railTopTapsFromOverheadScaleTheFieldExactly() throws {
        let cameraHeight = 2.4
        let tapHeight = 0.04
        let perturbed = try CalibrationPerturbation
            .railTopTaps(height: tapHeight, cameraPosition: Vec3(0, cameraHeight, 0))
            .apply(to: clothCalibration)
        let corners = CalibrationPerturbation.trueCorners(of: clothCalibration)
        let expectedScale = cameraHeight / (cameraHeight - tapHeight)
        // Every corner slid radially out from the camera foot (the centre).
        for corner in corners {
            let tapped = corner + Vec3(0, tapHeight, 0)
            let direction = tapped - Vec3(0, cameraHeight, 0)
            let landed = Vec3(0, cameraHeight, 0) + direction * (cameraHeight / (cameraHeight - tapHeight))
            #expect(abs(landed.length / corner.length - expectedScale) < 1e-12)
        }
        #expect(perturbed.origin.length < 1e-12)
        #expect(perturbed.xAxis == clothCalibration.xAxis)
        // fromCorners snapped the inflated (2.74 %) measurement back.
        #expect(perturbed.size == .eightFoot)
        #expect(throws: CalibrationPerturbationError.cameraBelowTapHeight) {
            try CalibrationPerturbation.railTopTaps(height: 0.04, cameraPosition: Vec3(0, 0.03, 0))
                .apply(to: clothCalibration)
        }
    }

    @Test func yawAndTiltRotateTheAxes() throws {
        let yawed = try CalibrationPerturbation.yaw(.pi / 2).apply(to: clothCalibration)
        #expect(yawed.xAxis.distance(to: clothCalibration.yAxis) < 1e-12)
        #expect(yawed.normal.distance(to: clothCalibration.normal) < 1e-12)
        let tilted = try CalibrationPerturbation.tilt(0.1).apply(to: clothCalibration)
        #expect(tilted.xAxis == clothCalibration.xAxis)
        #expect(abs(tilted.normal.dot(clothCalibration.normal) - cos(0.1)) < 1e-12)
        #expect(tilted.origin == clothCalibration.origin)
    }

    @Test func sequencesApplyInOrder() throws {
        let both = try CalibrationPerturbation.apply(
            [.planeHeight(0.04), .yaw(0.2)], to: clothCalibration)
        #expect(abs(both.origin.y - 0.04) < 1e-12)
        #expect(abs(both.xAxis.dot(clothCalibration.xAxis) - cos(0.2)) < 1e-12)
    }
}
