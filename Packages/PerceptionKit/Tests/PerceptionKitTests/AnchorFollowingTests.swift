import CueSyncCore
import CueSyncTestSupport
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

/// B3 regression guard: the physical ball never moves, but ARKit refines
/// the world frame (table anchor AND camera poses shift together). A
/// calibration frozen at lock time then reports the ball drifting in
/// table space by the refinement; a calibration re-derived from the
/// anchor's current transform must keep reporting the same spot.
@Suite("PerceptionPipeline anchor following")
struct AnchorFollowingTests {
    /// Table on the world y=0 plane, +x along world x, +y along world -z
    /// (normal = up). Locked with an identity anchor at the table origin.
    private let lockCalibration = TableCalibration(origin: .zero,
                                                   xAxis: Vec3(1, 0, 0),
                                                   yAxis: Vec3(0, 0, -1),
                                                   size: .nineFoot)
    private let lockAnchor = Transform3D.identity
    /// Where the ball really sits (table space) throughout the clip.
    private let truth = Vec2(0.30, -0.20)
    private let intrinsics = CameraIntrinsics(focalX: 1400, focalY: 1400,
                                              principalX: 960, principalY: 720,
                                              imageWidth: 1920, imageHeight: 1440)
    private static let frameCount = 30
    private static let rampFrames = 20

    // MARK: - Helpers

    /// Right-handed camera pose at `position` looking at `target` (ARKit
    /// convention: camera looks along its -z, +y up).
    private func lookAt(from position: Vec3, to target: Vec3) -> Transform3D {
        let z = (position - target).normalized
        let x = Vec3(0, 1, 0).cross(z).normalized
        let y = z.cross(x)
        return Transform3D(columns: [
            SIMD4(x.x, x.y, x.z, 0),
            SIMD4(y.x, y.y, y.z, 0),
            SIMD4(z.x, z.y, z.z, 0),
            SIMD4(position.x, position.y, position.z, 1)
        ])
    }

    /// Rigid refinement ARKit applies to its world frame at `frame`: ramps
    /// linearly to `finalDrift` (+ `finalYaw` about the anchor origin) over
    /// the first `rampFrames`, then holds so the tracker can settle.
    private func refinement(at frame: Int, finalDrift: Vec3, finalYaw: Double) -> Transform3D {
        let t = min(Double(frame) / Double(Self.rampFrames), 1)
        let yaw = finalYaw * t
        let d = finalDrift * t
        let c = Foundation.cos(yaw)
        let s = Foundation.sin(yaw)
        return Transform3D(columns: [
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(d.x, d.y, d.z, 1)
        ])
    }

    /// The detector sees a fixed 5 cm box centred on the image of `point`
    /// as seen by the PHYSICAL camera — the pixels don't change when ARKit
    /// renumbers the world.
    private func detection(of point: Vec3, physicalCamera: Transform3D) throws -> Detection2D {
        let projector = PlaneGeometryRaycaster(calibration: lockCalibration)
        let frame = CapturedFrame(timestamp: 0, cameraTransform: physicalCamera,
                                  image: nil, intrinsics: intrinsics)
        let image = try #require(projector.projectToImage(worldPoint: point, frame: frame))
        return Detection2D(classLabel: "white-ball",
                           boundingBox: NormalizedRect(x: image.x - 0.025, y: image.y - 0.025,
                                                       width: 0.05, height: 0.05),
                           confidence: 0.95)
    }

    /// A physically fixed camera watching the ball, and the detection it
    /// produces of the ball's sphere centre.
    private func scene(cameraOffset: Vec3) throws -> (camera: Transform3D, detection: Detection2D) {
        let ballWorld = lockCalibration.tableToWorld(truth)
        let camera = lookAt(from: ballWorld + cameraOffset, to: ballWorld)
        let detection = try detection(of: ballWorld + Vec3(0, Ball.standardRadius, 0),
                                      physicalCamera: camera)
        return (camera, detection)
    }

    /// Run the clip and return the tracked cue-ball position after the
    /// last frame. Camera poses and the anchor transform both carry the
    /// per-frame refinement; the detection is constant.
    private func finalEstimate(physicalCamera: Transform3D,
                               detection: Detection2D,
                               finalDrift: Vec3, finalYaw: Double,
                               followsTableAnchor: Bool,
                               lockAnchorTransform: Transform3D? = .identity,
                               config: PerceptionConfig? = nil) async throws -> Vec2 {
        let pipeline = PerceptionPipeline(
            detector: FixtureDetectionProvider(constant: [detection]),
            calibration: lockCalibration,
            raycaster: PlaneGeometryRaycaster(calibration: lockCalibration),
            config: config ?? PerceptionConfig(followsTableAnchor: followsTableAnchor),
            tableAnchorTransform: lockAnchorTransform)
        var iterator = await pipeline.outputs.makeAsyncIterator()
        var last: Vec2?
        for index in 0..<Self.frameCount {
            let refine = refinement(at: index, finalDrift: finalDrift, finalYaw: finalYaw)
            let frame = CapturedFrame(timestamp: Double(index) / 30,
                                      cameraTransform: refine * physicalCamera,
                                      image: nil, intrinsics: intrinsics)
            await pipeline.ingest(frame, tableAnchorTransform: refine * lockAnchor)
            if let cue = await iterator.next()?.state.cueBall {
                last = cue.position
            }
        }
        return try #require(last, "no cue ball tracked")
    }

    // MARK: - Tests

    /// Top-down camera: the sphere-centre lift has no lateral effect, so
    /// the tracked position can be checked against the true table point
    /// directly. Horizontal drift of 2 cm plus a 0.6° yaw.
    @Test func topDownDriftFrozenDivergesFollowedHolds() async throws {
        let (camera, detection) = try scene(cameraOffset: Vec3(0, 1.4, 0.001))
        let drift = Vec3(0.012, 0, 0.016) // |horizontal| = 20 mm
        let yaw = 0.01 // ≈0.57°, ~3.6 mm at the ball's 0.36 m radius

        let frozen = try await finalEstimate(physicalCamera: camera, detection: detection,
                                             finalDrift: drift, finalYaw: yaw,
                                             followsTableAnchor: false)
        let followed = try await finalEstimate(physicalCamera: camera, detection: detection,
                                               finalDrift: drift, finalYaw: yaw,
                                               followsTableAnchor: true)
        let frozenError = frozen.distance(to: truth) * 1000
        let followedError = followed.distance(to: truth) * 1000
        #expect(frozenError > 15,
                "frozen calibration should drift with the anchor: \(frozenError) mm")
        #expect(followedError < 2,
                "followed calibration should hold: \(followedError) mm (frozen \(frozenError) mm)")
    }

    /// Oblique camera (≈35° elevation, the realistic hand-held case): the
    /// refinement also lowers the anchor 5 mm, which a frozen plane turns
    /// into an along-view error of 5/tan(35°) ≈ 7 mm that adds to the 2 cm
    /// horizontal drift in this geometry. Truth here is the pipeline's own
    /// zero-drift estimate — the ball did not move, so neither may the
    /// estimate.
    @Test func obliqueDriftFrozenDivergesFollowedHolds() async throws {
        let (camera, detection) = try scene(cameraOffset: Vec3(0.3, 1.0, 1.4))
        let drift = Vec3(0.012, -0.005, 0.016)

        let reference = try await finalEstimate(physicalCamera: camera, detection: detection,
                                                finalDrift: .zero, finalYaw: 0,
                                                followsTableAnchor: true)
        let frozen = try await finalEstimate(physicalCamera: camera, detection: detection,
                                             finalDrift: drift, finalYaw: 0.005,
                                             followsTableAnchor: false)
        let followed = try await finalEstimate(physicalCamera: camera, detection: detection,
                                               finalDrift: drift, finalYaw: 0.005,
                                               followsTableAnchor: true)
        let frozenError = frozen.distance(to: reference) * 1000
        let followedError = followed.distance(to: reference) * 1000
        #expect(frozenError > 15,
                "frozen calibration should drift with the anchor: \(frozenError) mm")
        #expect(followedError < 2,
                "followed calibration should hold: \(followedError) mm (frozen \(frozenError) mm)")
    }

    /// The flag defaults ON: a pipeline built with `.default` and a
    /// lock-time anchor transform follows without opting in.
    @Test func followingIsOnByDefault() async throws {
        #expect(PerceptionConfig.default.followsTableAnchor)
        let (camera, detection) = try scene(cameraOffset: Vec3(0, 1.4, 0.001))
        let followed = try await finalEstimate(physicalCamera: camera, detection: detection,
                                               finalDrift: Vec3(0.02, 0, 0), finalYaw: 0,
                                               followsTableAnchor: true, config: .default)
        let error = followed.distance(to: truth) * 1000
        #expect(error < 2, "default config must follow the anchor: \(error) mm off")
    }

    /// No anchor transform at init ⇒ the calibration stays pinned even
    /// when frames carry one (nothing to express it relative to).
    @Test func withoutLockAnchorTheCalibrationStaysPinned() async throws {
        let (camera, detection) = try scene(cameraOffset: Vec3(0, 1.4, 0.001))
        let pinned = try await finalEstimate(physicalCamera: camera, detection: detection,
                                             finalDrift: Vec3(0.02, 0, 0), finalYaw: 0,
                                             followsTableAnchor: true,
                                             lockAnchorTransform: nil)
        let error = pinned.distance(to: truth) * 1000
        #expect(error > 15, "pinned calibration should show the 20 mm shift: \(error) mm")
    }

    @Test func geometryRaycasterFollowsANewPlane() throws {
        let lifted = TableCalibration(origin: Vec3(0, 0.25, 0),
                                      xAxis: Vec3(1, 0, 0), yAxis: Vec3(0, 0, -1),
                                      size: .nineFoot)
        let raycaster: any PlaneRaycasting = PlaneGeometryRaycaster(calibration: lockCalibration)
        let following = try #require(raycaster as? any CalibrationFollowingRaycaster)
        let camera = lookAt(from: Vec3(0, 1.5, 0.001), to: .zero)
        let frame = CapturedFrame(timestamp: 0, cameraTransform: camera,
                                  image: nil, intrinsics: intrinsics)
        let hit = try #require(following.following(lifted)
            .raycastToTablePlane(imagePoint: Vec2(0.5, 0.5), frame: frame))
        #expect(abs(hit.y - 0.25) < 1e-9)
    }
}
