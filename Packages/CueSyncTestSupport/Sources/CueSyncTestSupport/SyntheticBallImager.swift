//
//  SyntheticBallImager.swift
//  CueSyncTestSupport
//
//  Projects a sphere of known radius at a known table position into the
//  axis-aligned silhouette bounding box a detector would emit — geometry
//  only, no pixels. The silhouette of a sphere is the conic where the
//  tangent cone from the camera meets the image plane; off-axis it is an
//  ellipse whose centre is NOT the projected sphere centre, and whose
//  bottom edge is NOT the contact point. Both biases are exact here, so
//  tests can quantify them instead of asserting them away.
//
//  The bounding box is computed in closed form from the dual conic: a line
//  l is tangent to conic C iff lᵀ·adj(C)·l = 0, so the vertical/horizontal
//  tangent lines fall out of one quadratic each.
//

import CueSyncCore
import Foundation
import TableSpace

/// Axis-aligned pixel rectangle in the native image (top-left origin).
public struct PixelRect: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    /// Bottom-centre — the "foot point" of the box.
    public var foot: Vec2 { Vec2((minX + maxX) / 2, maxY) }
}

/// A normalized box as Vision reports it: BOTTOM-left origin, y up. This is
/// the form PerceptionKit's VisionBoxMapping flips into `NormalizedRect`.
public struct VisionStyleBox: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Everything known about one imaged ball.
public struct BallSilhouette: Sendable, Equatable {
    /// Sphere centre in world space (one radius above the cloth).
    public var sphereCenter: Vec3
    /// Native pixel projection of the true sphere centre.
    public var projectedCenter: Vec2
    /// Exact silhouette bounding box in native pixels.
    public var pixelBox: PixelRect
    /// The box a Detection2D would carry: normalized, top-left origin, in
    /// the camera's delivered orientation.
    public var box: NormalizedRect
    /// The same box as Vision would report it (bottom-left origin), before
    /// VisionBoxMapping.topLeftRect flips it into `box`.
    public var visionBox: VisionStyleBox

    /// Silhouette-box centre minus projected sphere centre, native pixels.
    /// Zero on the optical axis, second-order off it.
    public var centerBias: Vec2 { pixelBox.center - projectedCenter }
}

/// Images balls on a calibrated table through a SyntheticCamera.
public struct SyntheticBallImager: Sendable {
    public var camera: SyntheticCamera
    /// The TRUE table geometry the balls sit on (tests may hand the app a
    /// perturbed copy; this one is ground truth).
    public var calibration: TableCalibration
    public var ballRadius: Double

    public init(camera: SyntheticCamera,
                calibration: TableCalibration,
                ballRadius: Double = Ball.standardRadius) {
        self.camera = camera
        self.calibration = calibration
        self.ballRadius = ballRadius
    }

    /// World position of a ball's sphere centre resting at `table`.
    public func sphereCenter(ballAt table: Vec2) -> Vec3 {
        calibration.tableToWorld(table) + calibration.normal * ballRadius
    }

    /// Silhouette of a ball resting on the cloth at `table`. Nil when the
    /// silhouette is not a bounded ellipse in front of the camera (sphere
    /// behind/around the camera, or the tangent cone reaching the horizon).
    public func silhouette(ballAt table: Vec2) -> BallSilhouette? {
        silhouette(sphereCenter: sphereCenter(ballAt: table))
    }

    /// Silhouette of a sphere of `ballRadius` centred at a world point.
    public func silhouette(sphereCenter: Vec3) -> BallSilhouette? {
        let c = camera.cameraSpace(sphereCenter)
        let distance = c.length
        guard distance > ballRadius else { return nil }
        let sinAlpha = ballRadius / distance
        let alpha = Foundation.asin(sinAlpha)
        // Off-axis angle of the centre; the cone must stay in front of the
        // image plane for the silhouette to be a bounded ellipse.
        let u = c / distance
        let beta = Foundation.acos(Swift.max(-1, Swift.min(1, -u.z)))
        guard beta + alpha < .pi / 2 - 1e-9 else { return nil }
        guard let projected = camera.normalizedRay(cameraSpace: c) else { return nil }

        // Tangent cone in camera space: wᵀ Q w = 0 with Q = u uᵀ − cos²α I.
        // Image rays are w = (xn, yn, −1) = S·(xn, yn, 1), S = diag(1,1,−1),
        // so the conic in homogeneous ray coordinates is C = S Q S.
        let cos2 = 1 - sinAlpha * sinAlpha
        let sign = [1.0, 1.0, -1.0]
        let uv = [u.x, u.y, u.z]
        var conic = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                let q = uv[i] * uv[j] - (i == j ? cos2 : 0)
                conic[i][j] = sign[i] * sign[j] * q
            }
        }
        let dual = Self.adjugate(conic)
        guard let xRange = Self.tangentRange(a: dual[0][0], b: dual[0][2], c: dual[2][2]),
              let yRange = Self.tangentRange(a: dual[1][1], b: dual[1][2], c: dual[2][2])
        else { return nil }

        let left = camera.pixel(normalizedRay: Vec2(xRange.lowerBound, 0)).x
        let right = camera.pixel(normalizedRay: Vec2(xRange.upperBound, 0)).x
        // Image y is flipped: the largest ray y is the TOP pixel row.
        let top = camera.pixel(normalizedRay: Vec2(0, yRange.upperBound)).y
        let bottom = camera.pixel(normalizedRay: Vec2(0, yRange.lowerBound)).y
        let pixelBox = PixelRect(minX: left, minY: top, maxX: right, maxY: bottom)

        let k = camera.intrinsics
        let native = NormalizedRect(x: pixelBox.minX / k.imageWidth,
                                    y: pixelBox.minY / k.imageHeight,
                                    width: pixelBox.width / k.imageWidth,
                                    height: pixelBox.height / k.imageHeight)
        let box = camera.orientation.apply(toNativeNormalized: native)
        // Inverse of VisionBoxMapping.topLeftRect: y_top = 1 − y_vision − h.
        let visionBox = VisionStyleBox(x: box.x, y: 1 - box.y - box.height,
                                       width: box.width, height: box.height)
        return BallSilhouette(sphereCenter: sphereCenter,
                              projectedCenter: camera.pixel(normalizedRay: projected),
                              pixelBox: pixelBox,
                              box: box,
                              visionBox: visionBox)
    }

    /// The Detection2D a detector would emit for a ball at `table`, or nil
    /// when the ball has no bounded silhouette.
    public func detection(ballAt table: Vec2, label: String,
                          confidence: Double = 0.95) -> Detection2D? {
        silhouette(ballAt: table).map {
            Detection2D(classLabel: label, boundingBox: $0.box, confidence: confidence)
        }
    }

    // MARK: - Conic helpers

    /// Solve c·k² − 2b·k + a = 0 for the two tangent-line offsets; nil when
    /// the conic has no real axis-aligned tangents (not an ellipse).
    static func tangentRange(a: Double, b: Double, c: Double) -> ClosedRange<Double>? {
        guard abs(c) > 1e-15 else { return nil }
        let discriminant = b * b - a * c
        guard discriminant >= 0 else { return nil }
        let root = discriminant.squareRoot()
        let k1 = (b - root) / c
        let k2 = (b + root) / c
        return Swift.min(k1, k2)...Swift.max(k1, k2)
    }

    /// Adjugate (transposed cofactor matrix) of a 3×3 matrix.
    static func adjugate(_ m: [[Double]]) -> [[Double]] {
        var out = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                let rows = (0..<3).filter { $0 != i }
                let cols = (0..<3).filter { $0 != j }
                let minor = m[rows[0]][cols[0]] * m[rows[1]][cols[1]]
                    - m[rows[0]][cols[1]] * m[rows[1]][cols[0]]
                let cofactor = ((i + j) % 2 == 0 ? 1.0 : -1.0) * minor
                out[j][i] = cofactor
            }
        }
        return out
    }
}
