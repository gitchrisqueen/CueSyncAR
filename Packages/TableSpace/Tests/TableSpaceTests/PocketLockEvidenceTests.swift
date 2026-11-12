//
//  PocketLockEvidenceTests.swift
//  CueSync AR
//
//  The lock's evidence must be JSON-safe and complete enough to rebuild the
//  pocket rays offline: snapped pixel + camera pose + intrinsics -> the ray
//  the fit used.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Pocket lock evidence")
struct PocketLockEvidenceTests {
    /// A camera at `TiltedPocketFitTests.camera` looking down the table
    /// (-z), pitched 16 degrees down, as on the stand at the head rail.
    static let pose: Transform3D = {
        let pitch = -16.0 * .pi / 180
        let x = Vec3(1, 0, 0)
        let y = Vec3(0, cos(pitch), -sin(pitch))
        let z = Vec3(0, sin(pitch), cos(pitch))   // camera looks along -z
        let c = TiltedPocketFitTests.camera
        return Transform3D(columns: [SIMD4(x.x, x.y, x.z, 0), SIMD4(y.x, y.y, y.z, 0),
                                     SIMD4(z.x, z.y, z.z, 0), SIMD4(c.x, c.y, c.z, 1)])
    }()
    static let intrinsics = CameraIntrinsics(focalX: 1301.7, focalY: 1301.7, principalX: 719.5,
                                             principalY: 539.5, imageWidth: 1440, imageHeight: 1080)

    static func pixel(of direction: Vec3) -> Vec2 {
        let k = intrinsics
        let cam = Vec3(pose.axis(0).dot(direction), pose.axis(1).dot(direction), pose.axis(2).dot(direction))
        return Vec2(k.principalX + k.focalX * cam.x / -cam.z, k.principalY - k.focalY * cam.y / -cam.z)
    }

    static func evidence() throws -> (PocketLockEvidence, PocketCalibration.TiltedFit,
                                      [(pocket: PocketID, ray: TapRay)]) {
        let table = TiltedPocketFitTests.truth(slopeX: 0.008, slopeZ: 0.014)
        let rays = TiltedPocketFitTests.rays(table, noise: 0.0005)
        let fit = try PocketCalibration.solveTilted(rays: rays, size: .eightFoot)
        var pockets: [PocketID: PocketLockEvidence.Pocket] = [:]
        for (pocket, ray) in rays {
            let p = pixel(of: ray.direction)
            pockets[pocket] = .init(tap: p + Vec2(3, -2), snapped: p, method: "noseCorner")
        }
        let line = PocketSnap.Line(point: Vec2(300, 590), direction: Vec2(0.703, -0.711), rms: 0.67, inliers: 71)
        var evidence = PocketLockEvidence(pockets: pockets, lines: [(line, line), (nil, nil), (line, nil), (nil, nil)],
                                          cameraPose: pose, intrinsics: intrinsics, normal: Vec3(0, 1, 0),
                                          tiltDegrees: 0, residual: 0, dropped: nil, size: .eightFoot)
        evidence.apply(fit)
        return (evidence, fit, rays)
    }

    /// Every leaf is a number or a string.
    static func leavesAreNumbersOrStrings(_ value: Any) -> Bool {
        switch value {
        case let dict as [String: Any]: return dict.values.allSatisfy(leavesAreNumbersOrStrings)
        case let array as [Any]: return array.allSatisfy(leavesAreNumbersOrStrings)
        case is String, is Double, is Int: return true
        default: return false
        }
    }

    @Test func mirrorStateIsJSONSafe() throws {
        let state = try Self.evidence().0.mirrorState
        #expect(JSONSerialization.isValidJSONObject(state))
        #expect(Self.leavesAreNumbersOrStrings(state))
        let data = try JSONSerialization.data(withJSONObject: state)
        #expect(!data.isEmpty)
        #expect(Set(state.keys).isSuperset(of: ["pockets", "lines", "cameraTransform", "intrinsics",
                                                "planeNormal", "tiltDeg", "fitMm", "sizeM"]))
    }

    @Test func recordsEachPocketsResidualsFromTheFit() throws {
        let (evidence, fit, _) = try Self.evidence()
        let pockets = try #require(evidence.mirrorState["pockets"] as? [String: Any])
        #expect(pockets.count == 6)
        for pocket in PocketID.allCases {
            let item = try #require(pockets[pocket.rawValue] as? [String: Any])
            let error = try #require(item["errorMm"] as? Double)
            #expect(abs(error - (fit.errors[pocket] ?? -1) * 1000) <= 0.05)
            #expect(item["leaveOneOutMm"] is Double)
            #expect(item["method"] as? String == "noseCorner")
        }
        #expect(abs(evidence.tiltDegrees - fit.tiltDegrees) < 1e-12)
        let lines = try #require(evidence.mirrorState["lines"] as? [String: Any])
        let first = try #require(lines["TL-TR"] as? [String: Any])
        #expect((first["nose"] as? [String: Any])?["inliers"] as? Int == 71)
        #expect((lines["TR-BR"] as? [String: Any])?["nose"] as? String == "none")
    }

    /// The recorded pixel, pose and intrinsics rebuild the ray the fit used
    /// to within the rounding (0.1 px is about 0.08 mrad).
    @Test func recordedPixelsRebuildTheFitRays() throws {
        let (evidence, _, rays) = try Self.evidence()
        let state = evidence.mirrorState
        let m = try #require(state["cameraTransform"] as? [Double])
        let k = try #require(state["intrinsics"] as? [String: Double])
        let pockets = try #require(state["pockets"] as? [String: Any])
        #expect(m.count == 16)
        for (pocket, ray) in rays {
            let item = try #require(pockets[pocket.rawValue] as? [String: Any])
            let p = try #require(item["snappedPx"] as? [Double])
            let cam = Vec3((p[0] - k["principalX"]!) / k["focalX"]!, -(p[1] - k["principalY"]!) / k["focalY"]!, -1)
            let world = Vec3(m[0], m[1], m[2]) * cam.x + Vec3(m[4], m[5], m[6]) * cam.y + Vec3(m[8], m[9], m[10]) * cam.z
            let angle = acos(min(1, world.normalized.dot(ray.direction)))
            #expect(angle < 2e-4, "\(pocket.rawValue) off by \(angle) rad")
        }
    }
}
