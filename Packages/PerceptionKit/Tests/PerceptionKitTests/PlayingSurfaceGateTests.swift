import CueSyncCore
import Testing
@testable import PerceptionKit

@Suite("PlayingSurfaceGate")
struct PlayingSurfaceGateTests {
    // Eight-foot field: half-extents (1.17, 0.585); ball radius 0.028575.
    let gate = PlayingSurfaceGate(table: Table(size: .eightFoot))
    var r: Double { Ball.standardRadius }
    var he: Vec2 { Table(size: .eightFoot).halfExtents }

    @Test func feasibleEnvelopeIsOneRadiusInsideTheCushionNose() {
        #expect(abs(gate.feasibleHalfExtents.x - (he.x - r)) < 1e-12)
        #expect(abs(gate.feasibleHalfExtents.y - (he.y - r)) < 1e-12)
    }

    @Test func interiorAndRailContactPointsPassUnchanged() {
        let centre = Vec2(0.1, -0.2)
        #expect(gate.admit(centre) == centre)
        // Frozen to the long cushion, the short cushion, and in the corner.
        let longRail = Vec2(0.3, he.y - r)
        let shortRail = Vec2(-(he.x - r), 0.1)
        let corner = Vec2(he.x - r, -(he.y - r))
        #expect(gate.admit(longRail) == longRail)
        #expect(gate.admit(shortRail) == shortRail)
        #expect(gate.admit(corner) == corner)
        #expect(gate.contains(longRail) && gate.contains(shortRail) && gate.contains(corner))
    }

    @Test func pointsInsideTheSlackBandAreMovedOntoTheEnvelope() throws {
        // 2 cm past the contact line on +x: a rail ball with calibration
        // error. Reported ON the contact line, y untouched.
        let past = Vec2(he.x - r + 0.02, 0.15)
        let admitted = try #require(gate.admit(past))
        #expect(abs(admitted.x - (he.x - r)) < 1e-12)
        #expect(admitted.y == 0.15)
        #expect(gate.contains(admitted))
        // Same on -y.
        let below = Vec2(-0.4, -(he.y - r) - 0.03)
        let admittedBelow = try #require(gate.admit(below))
        #expect(admittedBelow.x == -0.4)
        #expect(abs(admittedBelow.y + (he.y - r)) < 1e-12)
        // Corner: both axes clamp.
        let cornerPast = Vec2(he.x + 0.01, he.y + 0.01)
        let admittedCorner = try #require(gate.admit(cornerPast))
        #expect(abs(admittedCorner.x - (he.x - r)) < 1e-12)
        #expect(abs(admittedCorner.y - (he.y - r)) < 1e-12)
    }

    @Test func slackCoversTheDocumentedErrorBudget() throws {
        // Tripwire: the admit band must stay at least as wide as the
        // worst-case error a real rail ball can carry (~4 cm of the
        // documented 4.5 cm). Tightening it below that clips real balls.
        let worstCase = Vec2(he.x - r + 0.04, 0)
        #expect(gate.admit(worstCase) != nil)
        // ...and the band ends before the rail top: 2 cm past the nose is out.
        #expect(gate.admit(Vec2(he.x + 0.02, 0)) == nil)
    }

    @Test func pointsBeyondTheSlackBandAreRejected() {
        // Just past the admit line on each axis and sign.
        let eps = 1e-6
        #expect(gate.admit(Vec2(he.x - r + gate.slack + eps, 0)) == nil)
        #expect(gate.admit(Vec2(-(he.x - r + gate.slack + eps), 0)) == nil)
        #expect(gate.admit(Vec2(0, he.y - r + gate.slack + eps)) == nil)
        #expect(gate.admit(Vec2(0, -(he.y - r + gate.slack + eps))) == nil)
        // The old margin's worst case: 2 radii past the nose (5.7 cm) —
        // admitted before, rejected now.
        #expect(gate.admit(Vec2(he.x + 2 * r - eps, 0)) == nil)
        // The live phantom at (-4.5, -3.3).
        #expect(gate.admit(Vec2(-4.5, -3.3)) == nil)
    }

    @Test func containsIsTheStrictEnvelopeNotTheAdmitBand() {
        #expect(gate.contains(Vec2(he.x - r, 0)))
        #expect(gate.contains(Vec2(he.x - r + 1e-10, 0)), "ulp noise from smoothing is tolerated")
        #expect(!gate.contains(Vec2(he.x - r + 0.001, 0)), "a millimetre past the contact line is off the surface")
        #expect(!gate.contains(Vec2(he.x, 0)), "the nose line itself is not a feasible centre")
        #expect(!gate.contains(Vec2(0, -(he.y - r) - 0.001)))
    }

    @Test func customTableSizesFlowThroughHalfExtents() {
        let odd = PlayingSurfaceGate(table: Table(size: .custom(width: 2.0, height: 1.0)))
        #expect(odd.admit(Vec2(1.0 - Ball.standardRadius, 0)) != nil)
        #expect(odd.admit(Vec2(1.0 + 0.02, 0)) == nil)
    }
}
