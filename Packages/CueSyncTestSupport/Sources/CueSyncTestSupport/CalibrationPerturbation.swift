//
//  CalibrationPerturbation.swift
//  CueSyncTestSupport
//
//  Controlled calibration errors, so tests can attribute overlay error to a
//  named cause: corner taps that landed off, a plane locked on the rail top
//  instead of the cloth, a yawed or tilted fit. Each perturbation takes the
//  TRUE calibration and returns the calibration the app would have ended up
//  with, going through TableCalibration.fromCorners wherever the app would
//  (so size snapping is exercised, not bypassed).
//

import CueSyncCore
import Foundation
import TableSpace

public enum CalibrationPerturbationError: Error, Equatable {
    /// `.railTopTaps` needs the camera above the rail top; a tap ray from
    /// below cannot reach the cloth through the rail corner.
    case cameraBelowTapHeight
    /// `.cornerOffsets` needs exactly four deltas.
    case needFourOffsets
}

public enum CalibrationPerturbation: Sendable, Equatable {
    /// World-space deltas added to the four true field corners (perimeter
    /// order, see `trueCorners`), then re-fit with `fromCorners`.
    case cornerOffsets([Vec3])
    /// The whole calibration plane sits `height` above the cloth (ARKit
    /// locked the rail-top plane rather than the cloth). Extent untouched.
    case planeHeight(Double)
    /// Corner taps landed on the rail top, `height` above the cloth, at the
    /// true corner footprint; the app intersects each tap's ray from
    /// `cameraPosition` with the cloth plane, so every corner slides away
    /// from the camera's foot by height / (cameraHeight − height) times its
    /// horizontal distance from that foot. Re-fit with `fromCorners`.
    case railTopTaps(height: Double, cameraPosition: Vec3)
    /// Axes rotated about the plane normal through the origin (radians).
    case yaw(Double)
    /// Plane tilted about the table x axis (radians): the short axis and
    /// normal rotate, the origin stays.
    case tilt(Double)

    /// The four playing-field corners of a calibration in world space, in
    /// perimeter order (−x−y, +x−y, +x+y, −x+y).
    public static func trueCorners(of calibration: TableCalibration) -> [Vec3] {
        let (w, h) = calibration.size.playField
        let hx = w / 2
        let hy = h / 2
        return [Vec2(-hx, -hy), Vec2(hx, -hy), Vec2(hx, hy), Vec2(-hx, hy)]
            .map(calibration.tableToWorld)
    }

    /// The calibration the app would hold after this error. `sizeTolerance`
    /// is forwarded to `fromCorners` (the app's default is 8 %).
    public func apply(to calibration: TableCalibration,
                      sizeTolerance: Double = 0.08) throws -> TableCalibration {
        switch self {
        case .cornerOffsets(let offsets):
            guard offsets.count == 4 else { throw CalibrationPerturbationError.needFourOffsets }
            let corners = zip(Self.trueCorners(of: calibration), offsets).map { $0 + $1 }
            return try TableCalibration.fromCorners(corners, sizeTolerance: sizeTolerance)

        case .planeHeight(let height):
            var lifted = calibration
            lifted.origin = calibration.origin + calibration.normal * height
            return lifted

        case .railTopTaps(let height, let cameraPosition):
            let normal = calibration.normal
            let cameraHeight = calibration.heightAbovePlane(cameraPosition)
            guard cameraHeight > height + 1e-9 else {
                throw CalibrationPerturbationError.cameraBelowTapHeight
            }
            let corners = Self.trueCorners(of: calibration).map { corner -> Vec3 in
                let tapped = corner + normal * height
                // Ray camera → tapped point, continued to the cloth plane.
                let direction = tapped - cameraPosition
                let t = (calibration.origin - cameraPosition).dot(normal) / direction.dot(normal)
                return cameraPosition + direction * t
            }
            return try TableCalibration.fromCorners(corners, sizeTolerance: sizeTolerance)

        case .yaw(let angle):
            let n = calibration.normal
            return TableCalibration(origin: calibration.origin,
                                    xAxis: Self.rotate(calibration.xAxis, about: n, by: angle),
                                    yAxis: Self.rotate(calibration.yAxis, about: n, by: angle),
                                    size: calibration.size)

        case .tilt(let angle):
            let axis = calibration.xAxis
            return TableCalibration(origin: calibration.origin,
                                    xAxis: axis,
                                    yAxis: Self.rotate(calibration.yAxis, about: axis, by: angle),
                                    size: calibration.size)
        }
    }

    /// Apply several perturbations in order.
    public static func apply(_ perturbations: [CalibrationPerturbation],
                             to calibration: TableCalibration,
                             sizeTolerance: Double = 0.08) throws -> TableCalibration {
        try perturbations.reduce(calibration) { current, perturbation in
            try perturbation.apply(to: current, sizeTolerance: sizeTolerance)
        }
    }

    /// Rodrigues rotation of `v` about unit `axis` by `angle` radians.
    static func rotate(_ v: Vec3, about axis: Vec3, by angle: Double) -> Vec3 {
        let k = axis.normalized
        let c = Foundation.cos(angle)
        let s = Foundation.sin(angle)
        return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))
    }
}
