import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

// MARK: - Helpers

/// Rigid transform: rotation by `angle` about the y axis, then translation.
private func rigid(yaw: Double, translation: Vec3) -> Transform3D {
    let c = Foundation.cos(yaw)
    let s = Foundation.sin(yaw)
    return Transform3D(columns: [
        SIMD4(c, 0, -s, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(s, 0, c, 0),
        SIMD4(translation.x, translation.y, translation.z, 1)
    ])
}

private func expectClose(_ a: Vec3, _ b: Vec3,
                         tolerance: Double = 1e-9,
                         _ comment: Comment? = nil) {
    #expect(a.distance(to: b) < tolerance, comment)
}

@Suite("CornerOrdering")
struct CornerOrderingTests {
    /// A 2.54×1.27 m rectangle on the y=0 plane, perimeter order.
    private let rect: [Vec3] = [
        Vec3(-1.27, 0, -0.635),
        Vec3(1.27, 0, -0.635),
        Vec3(1.27, 0, 0.635),
        Vec3(-1.27, 0, 0.635)
    ]
    private let up = Vec3(0, 1, 0)

    @Test func shuffledCornersComeBackInPerimeterOrder() throws {
        // Diagonal-neighbor swap: the classic "hourglass" input that breaks
        // fromCorners if passed through unordered.
        let shuffled = [rect[0], rect[2], rect[1], rect[3]]
        let ordered = CornerOrdering.orderedAroundCentroid(shuffled, planeNormal: up)
        // Perimeter order means every consecutive pair is a rectangle edge
        // (length 2.54 or 1.27), never a diagonal (~2.84).
        for i in 0..<4 {
            let d = ordered[i].distance(to: ordered[(i + 1) % 4])
            #expect(abs(d - 2.54) < 1e-9 || abs(d - 1.27) < 1e-9,
                    "consecutive corners must be edge neighbors, got \(d)")
        }
        // And the result must still build a valid nine-foot calibration.
        let calibration = try TableCalibration.fromCorners(ordered)
        #expect(calibration.size == .nineFoot)
    }

    @Test func everyPermutationYieldsAValidCalibration() throws {
        func permutations<T>(_ items: [T]) -> [[T]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { i -> [[T]] in
                var rest = items
                let head = rest.remove(at: i)
                return permutations(rest).map { [head] + $0 }
            }
        }
        for permutation in permutations(rect) {
            let ordered = CornerOrdering.orderedAroundCentroid(permutation, planeNormal: up)
            let calibration = try TableCalibration.fromCorners(ordered)
            #expect(calibration.size == .nineFoot)
        }
    }

    @Test func nonFourInputsPassThroughUnchanged() {
        let three = Array(rect.prefix(3))
        #expect(CornerOrdering.orderedAroundCentroid(three, planeNormal: up) == three)
    }
}

@Suite("AnchoredCalibration")
struct AnchoredCalibrationTests {
    private func makeCalibration() -> TableCalibration {
        TableCalibration(origin: Vec3(0.4, 0.8, -1.2),
                         xAxis: Vec3(1, 0, 0),
                         yAxis: Vec3(0, 0, 1),
                         size: .nineFoot)
    }

    @Test func roundTripsThroughTheSameAnchor() {
        let calibration = makeCalibration()
        let anchor = rigid(yaw: 0.7, translation: Vec3(2, -0.5, 3))
        let anchored = AnchoredCalibration(calibration: calibration, anchorTransform: anchor)
        let restored = anchored.worldCalibration(anchorTransform: anchor)
        expectClose(restored.origin, calibration.origin)
        expectClose(restored.xAxis, calibration.xAxis)
        expectClose(restored.yAxis, calibration.yAxis)
        #expect(restored.size == calibration.size)
    }

    @Test func followsTheAnchorAfterRelocalization() {
        // Save against anchor A; the next session relocalizes the same
        // physical anchor at a different world transform B = D * A. The
        // restored calibration must be the original moved by the same D.
        let calibration = makeCalibration()
        let anchorA = rigid(yaw: 0.3, translation: Vec3(1, 0, -2))
        let drift = rigid(yaw: -1.1, translation: Vec3(-4, 0.2, 0.5))
        let anchorB = drift * anchorA

        let anchored = AnchoredCalibration(calibration: calibration, anchorTransform: anchorA)
        let restored = anchored.worldCalibration(anchorTransform: anchorB)

        expectClose(restored.origin, drift.transformPoint(calibration.origin), tolerance: 1e-9)
        expectClose(restored.xAxis, drift.transformDirection(calibration.xAxis), tolerance: 1e-9)
        expectClose(restored.yAxis, drift.transformDirection(calibration.yAxis), tolerance: 1e-9)
        #expect(restored.size == calibration.size)
    }

    @Test func restoredAxesStayOrthonormal() {
        let calibration = makeCalibration()
        let anchor = rigid(yaw: 2.2, translation: Vec3(0.1, 1.5, -0.7))
        let restored = AnchoredCalibration(calibration: calibration, anchorTransform: anchor)
            .worldCalibration(anchorTransform: rigid(yaw: -0.4, translation: Vec3(5, 0, 5)))
        #expect(abs(restored.xAxis.length - 1) < 1e-9)
        #expect(abs(restored.yAxis.length - 1) < 1e-9)
        #expect(abs(restored.xAxis.dot(restored.yAxis)) < 1e-9)
    }

    @Test func invertRigidIsATrueInverse() {
        let transform = rigid(yaw: 1.9, translation: Vec3(-3, 2, 7))
        let inverse = AnchoredCalibration.invertRigid(transform)
        let p = Vec3(0.3, -1.1, 4.2)
        expectClose(inverse.transformPoint(transform.transformPoint(p)), p)
        expectClose(transform.transformPoint(inverse.transformPoint(p)), p)
    }

    @Test func survivesCodableRoundTrip() throws {
        let calibration = makeCalibration()
        let anchor = rigid(yaw: 0.5, translation: Vec3(1, 1, 1))
        let anchored = AnchoredCalibration(calibration: calibration, anchorTransform: anchor)
        let data = try JSONEncoder().encode(anchored)
        let decoded = try JSONDecoder().decode(AnchoredCalibration.self, from: data)
        #expect(decoded == anchored)
    }
}
