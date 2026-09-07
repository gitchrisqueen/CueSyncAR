//
//  SyntheticCamera.swift
//  CueSyncTestSupport
//
//  Exact pinhole camera for hardware-free projection tests. The conventions
//  are the app's, deliberately not re-invented (CLAUDE.md "Coordinate flow"):
//  - Camera space is ARKit's: +x right, +y up, looking along -z.
//  - Intrinsics are pixels of the image's NATIVE (landscape) orientation,
//    exactly what ARSessionCoordinator copies out of ARCamera.intrinsics and
//    ARCamera.imageResolution into CameraIntrinsics.
//  - Image space is top-left origin, y growing downward; normalized
//    coordinates divide by the native width/height (the space Detection2D
//    boxes live in once VisionBoxMapping has flipped Vision's bottom-left
//    boxes).
//  Forward projection here is written independently of PerceptionKit's
//  PlaneGeometryRaycaster so the two can be checked against each other.
//

import CueSyncCore
import Foundation

/// How a delivered image is rotated relative to the sensor's native frame.
/// `.up` is native landscape — the orientation the app runs Vision in
/// (`VNImageRequestHandler(orientation: .up)`) and the one intrinsics
/// describe. The others exist to synthesize the orientation-mismatch bug
/// class: boxes produced in a rotated image but unprojected with native
/// intrinsics.
public enum ImageOrientation: String, Sendable, CaseIterable, Codable {
    /// Native landscape (no rotation).
    case up
    /// Native rotated 90° clockwise (portrait).
    case right
    /// Native rotated 180°.
    case down
    /// Native rotated 90° counter-clockwise (portrait).
    case left

    /// Map a native normalized point (top-left origin) into this orientation.
    public func apply(toNativeNormalized p: Vec2) -> Vec2 {
        switch self {
        case .up: p
        case .right: Vec2(1 - p.y, p.x)
        case .down: Vec2(1 - p.x, 1 - p.y)
        case .left: Vec2(p.y, 1 - p.x)
        }
    }

    /// Map a normalized point in this orientation back to native.
    public func toNativeNormalized(_ p: Vec2) -> Vec2 {
        switch self {
        case .up: p
        case .right: Vec2(p.y, 1 - p.x)
        case .down: Vec2(1 - p.x, 1 - p.y)
        case .left: Vec2(1 - p.y, p.x)
        }
    }

    /// Rotate a native normalized rect into this orientation (axis-aligned
    /// boxes stay axis-aligned under quarter turns).
    public func apply(toNativeNormalized rect: NormalizedRect) -> NormalizedRect {
        let corners = [
            Vec2(rect.x, rect.y),
            Vec2(rect.x + rect.width, rect.y),
            Vec2(rect.x, rect.y + rect.height),
            Vec2(rect.x + rect.width, rect.y + rect.height)
        ].map { apply(toNativeNormalized: $0) }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 0
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Pinhole camera: intrinsics + camera-to-world pose + delivered orientation.
public struct SyntheticCamera: Sendable, Equatable {
    /// Pixels of the native image (ARCamera.intrinsics / imageResolution).
    public var intrinsics: CameraIntrinsics
    /// Camera-to-world rigid transform (ARKit convention, see file header).
    public var transform: Transform3D
    /// Orientation the detector sees the image in. Only affects boxes
    /// emitted by SyntheticBallImager / SyntheticDetectionProvider.
    public var orientation: ImageOrientation

    public init(intrinsics: CameraIntrinsics,
                transform: Transform3D,
                orientation: ImageOrientation = .up) {
        self.intrinsics = intrinsics
        self.transform = transform
        self.orientation = orientation
    }

    // MARK: - Presets

    /// iPhone-class wide camera in ARKit's 4:3 1920×1440 video format:
    /// f ≈ 1400 px (≈ 69° horizontal, ≈ 54° vertical field of view).
    public static let iPhoneWideVideo = CameraIntrinsics(
        focalX: 1400, focalY: 1400,
        principalX: 960, principalY: 720,
        imageWidth: 1920, imageHeight: 1440)

    /// Camera-to-world pose at `position` looking at `target`, with the
    /// image's up direction as close to `up` as the sightline allows. When
    /// the sightline is parallel to `up` (straight down) the world +x axis
    /// is used as the up hint instead, so overhead poses stay well-defined.
    public static func pose(at position: Vec3, lookingAt target: Vec3,
                            up: Vec3 = Vec3(0, 1, 0)) -> Transform3D {
        let forward = (target - position).normalized
        var upHint = up
        if forward.cross(upHint).length < 1e-6 {
            upHint = Vec3(1, 0, 0)
        }
        let right = forward.cross(upHint).normalized
        let cameraUp = right.cross(forward)
        let backward = forward * -1  // camera +z points away from the scene
        return Transform3D(columns: [
            SIMD4(right.x, right.y, right.z, 0),
            SIMD4(cameraUp.x, cameraUp.y, cameraUp.z, 0),
            SIMD4(backward.x, backward.y, backward.z, 0),
            SIMD4(position.x, position.y, position.z, 1)
        ])
    }

    // MARK: - Geometry

    /// Camera position in world space.
    public var position: Vec3 { transform.translation }

    /// Unit sightline direction (camera -z) in world space.
    public var forward: Vec3 { transform.axis(2) * -1 }

    /// A world point expressed in camera coordinates (rigid inverse).
    public func cameraSpace(_ world: Vec3) -> Vec3 {
        let offset = world - transform.translation
        return Vec3(offset.dot(transform.axis(0)),
                    offset.dot(transform.axis(1)),
                    offset.dot(transform.axis(2)))
    }

    /// Ideal-ray coordinates (x/-z, y/-z) of a camera-space point, or nil
    /// when the point is not in front of the camera.
    public func normalizedRay(cameraSpace pc: Vec3) -> Vec2? {
        guard pc.z < -1e-9 else { return nil }
        return Vec2(pc.x / -pc.z, pc.y / -pc.z)
    }

    /// Native pixel coordinates (top-left origin, y down) of ideal-ray
    /// coordinates: the intrinsics applied with the image y flip.
    public func pixel(normalizedRay r: Vec2) -> Vec2 {
        Vec2(intrinsics.principalX + intrinsics.focalX * r.x,
             intrinsics.principalY - intrinsics.focalY * r.y)
    }

    /// Ideal-ray coordinates of a native pixel — inverse of `pixel(normalizedRay:)`.
    public func normalizedRay(pixel p: Vec2) -> Vec2 {
        Vec2((p.x - intrinsics.principalX) / intrinsics.focalX,
             -((p.y - intrinsics.principalY) / intrinsics.focalY))
    }

    /// Project a world point to native pixels; nil when behind the camera.
    /// Points outside the sensor rectangle still project (no clipping) —
    /// callers decide what "visible" means.
    public func projectPixel(_ world: Vec3) -> Vec2? {
        normalizedRay(cameraSpace: cameraSpace(world)).map(pixel(normalizedRay:))
    }

    /// Project a world point to native normalized image coordinates.
    public func project(_ world: Vec3) -> Vec2? {
        projectPixel(world).map(normalized(pixel:))
    }

    /// Native pixels → native normalized (0...1).
    public func normalized(pixel p: Vec2) -> Vec2 {
        Vec2(p.x / intrinsics.imageWidth, p.y / intrinsics.imageHeight)
    }

    /// Native normalized → native pixels.
    public func pixel(normalized p: Vec2) -> Vec2 {
        Vec2(p.x * intrinsics.imageWidth, p.y * intrinsics.imageHeight)
    }

    /// Whether a native normalized point lies inside the image.
    public func contains(normalized p: Vec2) -> Bool {
        (0...1).contains(p.x) && (0...1).contains(p.y)
    }

    /// World ray through a native normalized image point — the independent
    /// inverse of `project`, for cross-checking unprojection code.
    public func ray(throughNormalized p: Vec2) -> (origin: Vec3, direction: Vec3) {
        let r = normalizedRay(pixel: pixel(normalized: p))
        let direction = transform.transformDirection(Vec3(r.x, r.y, -1)).normalized
        return (transform.translation, direction)
    }

    /// Angle (radians, 0...π/2) between the sightline to `world` and a plane
    /// with the given normal — the ray "elevation" the raycaster's grazing
    /// gate is measured on.
    public func sightlineElevation(to world: Vec3, planeNormal: Vec3) -> Double {
        let sightline = (world - position).normalized
        return Foundation.asin(Swift.min(1, abs(sightline.dot(planeNormal.normalized))))
    }

    /// Angle (radians) between the sightline to `world` and the optical axis.
    public func offAxisAngle(to world: Vec3) -> Double {
        let sightline = (world - position).normalized
        // atan2 form: well-conditioned near 0, unlike acos(dot).
        return Foundation.atan2(sightline.cross(forward).length, sightline.dot(forward))
    }

    // MARK: - Frames

    /// A CapturedFrame carrying exactly this camera's pose and intrinsics —
    /// what ARSessionCoordinator would hand the pipeline for this view.
    public func frame(timestamp: TimeInterval = 0) -> CapturedFrame {
        CapturedFrame(timestamp: timestamp,
                      cameraTransform: transform,
                      image: FixtureImageBuffer(width: Int(intrinsics.imageWidth),
                                                height: Int(intrinsics.imageHeight)),
                      intrinsics: intrinsics)
    }
}
