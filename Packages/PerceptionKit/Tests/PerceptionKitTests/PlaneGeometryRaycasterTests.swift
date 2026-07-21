import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import PerceptionKit

@Suite("PlaneGeometryRaycaster")
struct PlaneGeometryRaycasterTests {
    /// Table on the world y=0 plane, x along world x.
    private let calibration = TableCalibration(origin: .zero,
                                               xAxis: Vec3(1, 0, 0),
                                               yAxis: Vec3(0, 0, 1),
                                               size: .nineFoot)

    private let intrinsics = CameraIntrinsics(focalX: 1000, focalY: 1000,
                                              principalX: 960, principalY: 720,
                                              imageWidth: 1920, imageHeight: 1440)

    /// Camera 1.5 m above the origin, looking straight down: camera -z maps
    /// to world -y; camera +x stays world +x; camera +y maps to world -z.
    private var downwardCamera: Transform3D {
        Transform3D(columns: [
            SIMD4(1, 0, 0, 0),   // camera x → world x
            SIMD4(0, 0, -1, 0),  // camera y → world -z
            SIMD4(0, 1, 0, 0),   // camera z → world y (so -z looks down)
            SIMD4(0, 1.5, 0, 1)
        ])
    }

    private func frame(_ transform: Transform3D,
                       intrinsics: CameraIntrinsics?) -> CapturedFrame {
        CapturedFrame(timestamp: 0, cameraTransform: transform,
                      image: nil, intrinsics: intrinsics)
    }

    @Test func centerPixelHitsDirectlyBelowTheCamera() throws {
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        let hit = try #require(raycaster.raycastToTablePlane(
            imagePoint: Vec2(0.5, 0.5), frame: frame(downwardCamera, intrinsics: intrinsics)))
        #expect(abs(hit.x) < 1e-9)
        #expect(abs(hit.y) < 1e-9)
        #expect(abs(hit.z) < 1e-9)
    }

    @Test func offCenterPixelLandsWhereThePinholeModelSays() throws {
        // 100 px right of center at focal 1000 → tan = 0.1 → at 1.5 m
        // height the hit is 0.15 m along camera +x (world +x).
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        let u = (960.0 + 100.0) / 1920.0
        let hit = try #require(raycaster.raycastToTablePlane(
            imagePoint: Vec2(u, 0.5), frame: frame(downwardCamera, intrinsics: intrinsics)))
        #expect(abs(hit.x - 0.15) < 1e-9)
        #expect(abs(hit.y) < 1e-9)
    }

    @Test func imageYDownMapsToCameraYUp() throws {
        // 100 px BELOW center in the image → camera -y → world +z at 0.15 m.
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        let v = (720.0 + 100.0) / 1440.0
        let hit = try #require(raycaster.raycastToTablePlane(
            imagePoint: Vec2(0.5, v), frame: frame(downwardCamera, intrinsics: intrinsics)))
        #expect(abs(hit.z - 0.15) < 1e-9)
        #expect(abs(hit.x) < 1e-9)
    }

    @Test func missingIntrinsicsReturnsNil() {
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        #expect(raycaster.raycastToTablePlane(
            imagePoint: Vec2(0.5, 0.5), frame: frame(downwardCamera, intrinsics: nil)) == nil)
    }

    @Test func rayAwayFromPlaneReturnsNil() {
        // Camera looking straight UP never hits the table below.
        let upwardCamera = Transform3D(columns: [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, -1, 0, 0),
            SIMD4(0, 1.5, 0, 1)
        ])
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        #expect(raycaster.raycastToTablePlane(
            imagePoint: Vec2(0.5, 0.5), frame: frame(upwardCamera, intrinsics: intrinsics)) == nil)
    }
}
