import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

@Suite("ClothPlaneEstimator")
struct ClothPlaneEstimatorTests {
    /// A table lying in the world xz-plane with its cloth at y = -0.55 —
    /// the height ARKit reports when the device is set down on a rail
    /// rather than at the world origin.
    private let clothHeight = -0.55
    private var calibration: TableCalibration {
        TableCalibration(origin: Vec3(0, clothHeight, 0),
                         xAxis: Vec3(1, 0, 0),
                         yAxis: Vec3(0, 0, -1),
                         size: .eightFoot)
    }

    private func camera(at position: Vec3, lookingAt target: Vec3) -> SyntheticCamera {
        SyntheticCamera(intrinsics: SyntheticCamera.iPhoneWideVideo,
                        transform: SyntheticCamera.pose(at: position, lookingAt: target))
    }

    /// Image `positions` and hand back what the pipeline would receive.
    private func observed(_ positions: [Vec2], from camera: SyntheticCamera,
                          confidence: Double = 0.8)
        -> (detections: [Detection2D], frame: CapturedFrame) {
        let imager = SyntheticBallImager(camera: camera, calibration: calibration)
        let detections = positions.compactMap { position -> Detection2D? in
            guard let silhouette = imager.silhouette(ballAt: position) else { return nil }
            return Detection2D(classLabel: "color-ball",
                               boundingBox: silhouette.box,
                               confidence: confidence)
        }
        let frame = CapturedFrame(timestamp: 0,
                                  cameraTransform: camera.transform,
                                  intrinsics: camera.intrinsics)
        return (detections, frame)
    }

    private let spread: [Vec2] = [
        Vec2(-0.9, -0.4), Vec2(-0.3, 0.35), Vec2(0.1, -0.1),
        Vec2(0.55, 0.4), Vec2(0.95, -0.3), Vec2(-0.6, 0.1), Vec2(0.35, -0.45)
    ]

    // MARK: - The claim

    @Test("Seven balls recover the cloth height they are resting on")
    func recoversTheClothHeight() throws {
        let shot = observed(spread, from: camera(at: Vec3(-1.9, 0.75, 0.2),
                                                 lookingAt: Vec3(0.2, clothHeight, 0)))
        #expect(shot.detections.count == spread.count)
        let estimate = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        #expect(abs(estimate.height - clothHeight) < 0.005,
                "recovered \(estimate.height) against a true \(clothHeight)")
        #expect(estimate.sampleCount == spread.count)
        #expect(estimate.spread < 0.005)
    }

    @Test("It works from four very different viewpoints")
    func viewpointIndependent() throws {
        let poses: [(String, Vec3, Vec3)] = [
            ("head rail", Vec3(-1.9, 0.75, 0), Vec3(0.2, clothHeight, 0)),
            ("side rail", Vec3(0, 0.55, 1.6), Vec3(0, clothHeight, -0.2)),
            ("high overhead", Vec3(-0.5, 1.45, 0.3), Vec3(0.3, clothHeight, 0)),
            ("low far end", Vec3(-2.4, 0.35, 0), Vec3(0.4, clothHeight, 0))
        ]
        for (name, at, target) in poses {
            let shot = observed(spread, from: camera(at: at, lookingAt: target))
            let estimate = try #require(ClothPlaneEstimator.estimate(frames: [shot]),
                                        "\(name) produced nothing")
            #expect(abs(estimate.height - clothHeight) < 0.01,
                    "\(name): recovered \(estimate.height)")
        }
    }

    /// The failure this replaces: a tap a few pixels inside the cushion
    /// nose put the solved plane 13 cm out and a third of the balls
    /// outside the playing-surface envelope. The balls carry no such error
    /// because nothing is being tapped.
    @Test("The estimate beats a tap-derived plane that is 13 cm wrong")
    func beatsAMistappedPlane() throws {
        let shot = observed(spread, from: camera(at: Vec3(-1.9, 0.75, 0),
                                                 lookingAt: Vec3(0.2, clothHeight, 0)))
        let estimate = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        let mistapped = clothHeight - 0.13
        #expect(abs(estimate.height - clothHeight) < abs(mistapped - clothHeight) / 10)
    }

    // MARK: - Robustness

    @Test("A stray detection off the table cannot move the median")
    func outliersAreRejected() throws {
        var shot = observed(spread, from: camera(at: Vec3(-1.9, 0.75, 0),
                                                 lookingAt: Vec3(0.2, clothHeight, 0)))
        // Something on the floor, imaged much larger than a ball: a
        // near-field false positive of the kind the detector produces on
        // pocket mouths and tiles.
        shot.detections.append(Detection2D(
            classLabel: "color-ball",
            boundingBox: NormalizedRect(x: 0.05, y: 0.80, width: 0.09, height: 0.09),
            confidence: 0.6))
        let estimate = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        #expect(abs(estimate.height - clothHeight) < 0.01)
        #expect(estimate.sampleCount == spread.count, "the outlier is dropped, not averaged in")
    }

    @Test("The cue stick and low-confidence boxes are never used")
    func filtersNonBalls() throws {
        var shot = observed(spread, from: camera(at: Vec3(-1.9, 0.75, 0),
                                                 lookingAt: Vec3(0.2, clothHeight, 0)))
        let baseline = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        shot.detections.append(Detection2D(
            classLabel: "cue",
            boundingBox: NormalizedRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
            confidence: 0.95))
        shot.detections.append(Detection2D(
            classLabel: "color-ball",
            boundingBox: NormalizedRect(x: 0.7, y: 0.7, width: 0.05, height: 0.05),
            confidence: 0.1))
        let after = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        #expect(after.sampleCount == baseline.sampleCount)
        #expect(abs(after.height - baseline.height) < 1e-9)
    }

    @Test("A box that is not round is not a ball's silhouette")
    func rejectsNonSquareBoxes() throws {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        var shot = observed(spread, from: camera)
        let baseline = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        // Two balls merged into one box: twice as wide as it is tall.
        shot.detections.append(Detection2D(
            classLabel: "color-ball",
            boundingBox: NormalizedRect(x: 0.4, y: 0.4, width: 0.08, height: 0.02),
            confidence: 0.9))
        let after = try #require(ClothPlaneEstimator.estimate(frames: [shot]))
        #expect(after.sampleCount == baseline.sampleCount)
    }

    @Test("Too few balls yields nothing rather than a guess")
    func refusesToGuess() {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        let two = observed(Array(spread.prefix(2)), from: camera)
        #expect(ClothPlaneEstimator.estimate(frames: [two]) == nil)
        #expect(ClothPlaneEstimator.estimate(frames: []) == nil)
        let noIntrinsics = (detections: two.detections,
                            frame: CapturedFrame(timestamp: 0,
                                                 cameraTransform: camera.transform))
        #expect(ClothPlaneEstimator.estimate(frames: [noIntrinsics]) == nil)
    }

    @Test("Frames accumulate: three balls a frame over three frames is nine samples")
    func framesAccumulate() throws {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        let one = observed(Array(spread.prefix(3)), from: camera)
        let estimate = try #require(ClothPlaneEstimator.estimate(frames: [one, one, one]))
        #expect(estimate.sampleCount == 9)
        #expect(abs(estimate.height - clothHeight) < 0.005)
    }

    // MARK: - The range formula

    @Test("Range inverts the silhouette across the whole frame, not just the axis")
    func rangeIsTheSilhouetteInverse() throws {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        let imager = SyntheticBallImager(camera: camera, calibration: calibration)
        var worst = 0.0
        for position in spread {
            let silhouette = try #require(imager.silhouette(ballAt: position))
            let truth = camera.position.distance(to: silhouette.sphereCenter)
            let alpha = try #require(ClothPlaneEstimator.angularRadius(
                of: silhouette.box, intrinsics: camera.intrinsics))
            let measured = try #require(ClothPlaneEstimator.range(angularRadius: alpha))
            let error = abs(measured - truth) / truth
            worst = max(worst, error)
            #expect(error < 0.02, "at \(position): \(measured) vs \(truth)")
        }
        // The pixel formula this replaced was 13 % out in the corner of
        // the frame; measuring the angle keeps every ball inside 2 %.
        #expect(worst < 0.02)
    }

    /// Why the angle and not the pixel count: a sphere images as an
    /// ellipse that grows the further off axis it sits, so `f · r / d`
    /// under-reads range badly at the edge of the frame and not at all in
    /// the middle. The angle between two rays does not care where they
    /// fall.
    @Test("Off-axis balls are measured as accurately as centred ones")
    func offAxisIsNotPenalised() throws {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        let imager = SyntheticBallImager(camera: camera, calibration: calibration)
        func error(at position: Vec2) throws -> Double {
            let silhouette = try #require(imager.silhouette(ballAt: position))
            let truth = camera.position.distance(to: silhouette.sphereCenter)
            let alpha = try #require(ClothPlaneEstimator.angularRadius(
                of: silhouette.box, intrinsics: camera.intrinsics))
            let measured = try #require(ClothPlaneEstimator.range(angularRadius: alpha))
            return abs(measured - truth) / truth
        }
        let centred = try error(at: Vec2(0.1, -0.1))
        let corner = try error(at: Vec2(-0.9, -0.4))
        #expect(corner < 0.02, "corner ball off by \(corner * 100) %")
        #expect(centred < 0.01)
    }

    @Test("Range is monotonic in the angle and refuses impossible input")
    func rangeBehaves() {
        let near = ClothPlaneEstimator.range(angularRadius: 0.04)!
        let far = ClothPlaneEstimator.range(angularRadius: 0.01)!
        #expect(far > near, "a smaller silhouette must be further away")
        #expect(abs(far / near - 4) < 0.01, "range is inversely proportional to apparent size")
        #expect(ClothPlaneEstimator.range(angularRadius: 0) == nil)
        #expect(ClothPlaneEstimator.range(angularRadius: -0.01) == nil)
        let flat = NormalizedRect(x: 0.4, y: 0.4, width: 0, height: 0.02)
        #expect(ClothPlaneEstimator.angularRadius(
            of: flat, intrinsics: SyntheticCamera.iPhoneWideVideo) == nil)
    }

    @Test("Spread reports disagreement rather than hiding it")
    func spreadReportsDisagreement() throws {
        let camera = camera(at: Vec3(-1.9, 0.75, 0), lookingAt: Vec3(0.2, clothHeight, 0))
        let clean = try #require(ClothPlaneEstimator.estimate(frames: [observed(spread, from: camera)]))
        // Balls resting at different heights — a rack on the rail, or the
        // wrong ball radius entirely.
        let imager = SyntheticBallImager(camera: camera, calibration: calibration)
        var mixed: [Detection2D] = []
        for (index, position) in spread.enumerated() {
            let lift = Double(index) * 0.01
            let centre = imager.sphereCenter(ballAt: position) + Vec3(0, lift, 0)
            if let silhouette = imager.silhouette(sphereCenter: centre) {
                mixed.append(Detection2D(classLabel: "color-ball",
                                         boundingBox: silhouette.box, confidence: 0.8))
            }
        }
        let frame = CapturedFrame(timestamp: 0, cameraTransform: camera.transform,
                                  intrinsics: camera.intrinsics)
        let noisy = try #require(ClothPlaneEstimator.estimate(
            frames: [(detections: mixed, frame: frame)],
            config: .init(outlierMetres: 1.0)))
        #expect(noisy.spread > clean.spread * 3)
    }
}
