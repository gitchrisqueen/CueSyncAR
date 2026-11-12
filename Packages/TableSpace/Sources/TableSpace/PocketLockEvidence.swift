//
//  PocketLockEvidence.swift
//  TableSpace
//
//  What a pocket lock was built from, kept so the lock can be re-run and
//  judged offline.
//
//  The 2026-11-12 map-error diagnosis (docs/research) could not test the
//  pocket fit against its own inputs: `/state.json` reported only how far
//  each tap moved, never where the snapped pocket landed in the image, the
//  cushion-nose lines, the camera that cast the rays, or each pocket's
//  error. Those had to be rebuilt from the finished lock, which loses
//  exactly the residual pattern a diagnosis needs. This records them.
//
//  Numbers and strings only (plus arrays and dictionaries of them), so it
//  can go straight into JSONSerialization: a typed value such as a
//  `PocketID` there aborts the app.
//

import CueSyncCore
import Foundation

public struct PocketLockEvidence: Sendable, Equatable {
    /// One pocket as the lock used it, in image pixels (top-left origin).
    public struct Pocket: Sendable, Equatable {
        public var tap: Vec2
        public var snapped: Vec2
        public var method: String
        /// In-plane error of the fitted table at this pocket, metres.
        public var error: Double?
        /// Error when the pocket is left out of the fit, metres.
        public var leaveOneOut: Double?

        public init(tap: Vec2, snapped: Vec2, method: String,
                    error: Double? = nil, leaveOneOut: Double? = nil) {
            self.tap = tap
            self.snapped = snapped
            self.method = method
            self.error = error
            self.leaveOneOut = leaveOneOut
        }
    }

    public var pockets: [PocketID: Pocket]
    /// Rail-edge and cushion-nose line of each side, in `PocketSnap.sides`
    /// order (TL-TR, TR-BR, BR-BL, BL-TL); nil where none was found.
    public var lines: [(rail: PocketSnap.Line?, nose: PocketSnap.Line?)]
    /// The pose the snapped pixels were cast from.
    public var cameraPose: Transform3D
    public var intrinsics: CameraIntrinsics
    /// The fitted plane (at the sightings' height) and the fit's summary.
    public var normal: Vec3
    public var tiltDegrees: Double
    public var residual: Double
    public var dropped: PocketID?
    public var size: TableSize

    public init(pockets: [PocketID: Pocket],
                lines: [(rail: PocketSnap.Line?, nose: PocketSnap.Line?)],
                cameraPose: Transform3D, intrinsics: CameraIntrinsics,
                normal: Vec3, tiltDegrees: Double, residual: Double,
                dropped: PocketID?, size: TableSize) {
        self.pockets = pockets
        self.lines = lines
        self.cameraPose = cameraPose
        self.intrinsics = intrinsics
        self.normal = normal
        self.tiltDegrees = tiltDegrees
        self.residual = residual
        self.dropped = dropped
        self.size = size
    }

    /// Fill in the per-pocket errors from a tilted fit.
    public mutating func apply(_ fit: PocketCalibration.TiltedFit) {
        for (pocket, var entry) in pockets {
            entry.error = fit.errors[pocket]
            entry.leaveOneOut = fit.leaveOneOut[pocket]
            pockets[pocket] = entry
        }
        normal = fit.normal
        tiltDegrees = fit.tiltDegrees
        residual = fit.residual
        dropped = fit.dropped
    }

    public static func == (lhs: PocketLockEvidence, rhs: PocketLockEvidence) -> Bool {
        lhs.pockets == rhs.pockets && lhs.cameraPose == rhs.cameraPose && lhs.intrinsics == rhs.intrinsics
            && lhs.normal == rhs.normal && lhs.tiltDegrees == rhs.tiltDegrees && lhs.residual == rhs.residual
            && lhs.dropped == rhs.dropped && lhs.size == rhs.size && lhs.lines.count == rhs.lines.count
            && zip(lhs.lines, rhs.lines).allSatisfy { $0.rail == $1.rail && $0.nose == $1.nose }
    }

    /// The `/state.json` form: pixels to 0.1 px, millimetres to 0.1 mm,
    /// directions and the pose to 1e-6.
    public var mirrorState: [String: Any] {
        func r(_ v: Double, _ digits: Double) -> Double { (v * digits).rounded() / digits }
        func px(_ p: Vec2) -> [Double] { [r(p.x, 10), r(p.y, 10)] }
        func line(_ l: PocketSnap.Line?) -> Any {
            guard let l else { return "none" }
            return ["point": px(l.point), "direction": [r(l.direction.x, 1e6), r(l.direction.y, 1e6)],
                    "rmsPx": r(l.rms, 100), "inliers": l.inliers] as [String: Any]
        }
        var pocketState: [String: Any] = [:]
        for (pocket, entry) in pockets {
            var item: [String: Any] = ["tapPx": px(entry.tap), "snappedPx": px(entry.snapped), "method": entry.method]
            if let error = entry.error { item["errorMm"] = r(error * 1000, 10) }
            if let loo = entry.leaveOneOut { item["leaveOneOutMm"] = r(loo * 1000, 10) }
            pocketState[pocket.rawValue] = item
        }
        let sideNames = ["TL-TR", "TR-BR", "BR-BL", "BL-TL"]
        var lineState: [String: Any] = [:]
        for (index, pair) in lines.enumerated() where index < sideNames.count {
            lineState[sideNames[index]] = ["rail": line(pair.rail), "nose": line(pair.nose)] as [String: Any]
        }
        let k = intrinsics
        var state: [String: Any] = [
            "pockets": pocketState,
            "lines": lineState,
            // Column-major, the same layout as a recording's frames.jsonl.
            "cameraTransform": cameraPose.columns.flatMap { [r($0.x, 1e6), r($0.y, 1e6), r($0.z, 1e6), r($0.w, 1e6)] },
            "intrinsics": ["focalX": r(k.focalX, 1000), "focalY": r(k.focalY, 1000),
                           "principalX": r(k.principalX, 1000), "principalY": r(k.principalY, 1000),
                           "imageWidth": k.imageWidth, "imageHeight": k.imageHeight],
            "planeNormal": [r(normal.x, 1e6), r(normal.y, 1e6), r(normal.z, 1e6)],
            "tiltDeg": r(tiltDegrees, 1000),
            "fitMm": r(residual * 1000, 10),
            "sizeM": [size.playField.width, size.playField.height],
            "noseHeightMm": PocketSnap.noseHeight * 1000
        ]
        if let dropped { state["dropped"] = dropped.rawValue }
        return state
    }
}
