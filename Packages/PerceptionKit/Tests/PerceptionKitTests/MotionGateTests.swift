import CueSyncCore
import Foundation
import Testing
@testable import PerceptionKit

@Suite("MotionGate")
struct MotionGateTests {
    private let config = MotionGate.Config(translationThreshold: 0.02,
                                           rotationThreshold: 2.0 * .pi / 180,
                                           staticInterval: 2.0)

    private func pose(x: Double = 0, z: Double = 0, yaw: Double = 0) -> Transform3D {
        let c = Foundation.cos(yaw)
        let s = Foundation.sin(yaw)
        return Transform3D(columns: [
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(x, 0, z, 1)
        ])
    }

    @Test func firstFrameAlwaysRuns() {
        var gate = MotionGate(config: config)
        let ran1 = gate.shouldRunDetection(pose: pose(), timestamp: 0)
        #expect(ran1)
    }

    @Test func staticCameraIsGatedUntilHeartbeat() {
        var gate = MotionGate(config: config)
        _ = gate.shouldRunDetection(pose: pose(), timestamp: 0)
        let ran2 = gate.shouldRunDetection(pose: pose(), timestamp: 0.5)
        #expect(!ran2)
        let ran3 = gate.shouldRunDetection(pose: pose(), timestamp: 1.9)
        #expect(!ran3)
        // Heartbeat: static scenes still get a pass every staticInterval.
        let ran4 = gate.shouldRunDetection(pose: pose(), timestamp: 2.0)
        #expect(ran4)
        // …and the heartbeat clock restarts after that pass.
        let ran5 = gate.shouldRunDetection(pose: pose(), timestamp: 2.5)
        #expect(!ran5)
    }

    @Test func translationBeyondThresholdRuns() {
        var gate = MotionGate(config: config)
        _ = gate.shouldRunDetection(pose: pose(), timestamp: 0)
        let ran6 = gate.shouldRunDetection(pose: pose(x: 0.01), timestamp: 0.5)
        #expect(!ran6)
        let ran7 = gate.shouldRunDetection(pose: pose(x: 0.03), timestamp: 0.6)
        #expect(ran7)
    }

    @Test func rotationBeyondThresholdRuns() {
        var gate = MotionGate(config: config)
        _ = gate.shouldRunDetection(pose: pose(), timestamp: 0)
        let below = 1.0 * .pi / 180
        let above = 3.0 * .pi / 180
        let ran8 = gate.shouldRunDetection(pose: pose(yaw: below), timestamp: 0.5)
        #expect(!ran8)
        let ran9 = gate.shouldRunDetection(pose: pose(yaw: above), timestamp: 0.6)
        #expect(ran9)
    }

    @Test func slowDriftAccumulatesAgainstLastPass() {
        var gate = MotionGate(config: config)
        _ = gate.shouldRunDetection(pose: pose(), timestamp: 0)
        // Each step is below threshold, but total drift since the last
        // accepted pass crosses it on the third step.
        let ran10 = gate.shouldRunDetection(pose: pose(x: 0.008), timestamp: 0.3)
        #expect(!ran10)
        let ran11 = gate.shouldRunDetection(pose: pose(x: 0.016), timestamp: 0.6)
        #expect(!ran11)
        let ran12 = gate.shouldRunDetection(pose: pose(x: 0.024), timestamp: 0.9)
        #expect(ran12)
    }

    @Test func motionThresholdHelperIsSymmetricOnAxes() {
        let a = pose()
        let b = pose(z: 0.05)
        #expect(MotionGate.exceedsMotionThresholds(from: a, to: b, config: config))
        #expect(MotionGate.exceedsMotionThresholds(from: b, to: a, config: config))
    }
}
