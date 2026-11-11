import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("ShotAvailability")
struct ShotAvailabilityTests {
    private let table = Table(size: .nineFoot)

    private func ball(_ id: Int, _ kind: Ball.Kind, _ x: Double, _ y: Double) -> Ball {
        Ball(id: BallID(id), kind: kind, position: Vec2(x, y))
    }

    /// A standard triangle of fifteen balls at the foot spot, plus the cue.
    private func rackState() -> TableState {
        let radius = Ball.standardRadius
        var balls = [ball(0, .cue, -0.635, 0)]
        let dx = radius * 3.0.squareRoot() + 1e-4
        var id = 1
        for row in 0..<5 {
            for slot in 0...row {
                let y = (Double(slot) - Double(row) / 2) * 2 * (radius + 5e-5)
                balls.append(ball(id, .solid(1), 0.635 + Double(row) * dx, y))
                id += 1
            }
        }
        return TableState(table: table, balls: balls)
    }

    private func someShot() -> ShotRating {
        ShotRating(ball: BallID(3), pocket: .sideTop, probability: 0.6, difficulty: .medium,
                   cutAngleDegrees: 10, cueTravel: 1, objectTravel: 1, aimTolerance: 0.01,
                   ghostBall: Vec2(0, 0))
    }

    @Test("A full rack is a break, even if the ranking rated something into it")
    func fullRack() {
        #expect(ShotAvailability.classify(state: rackState(), active: nil) == .breakRack)
        #expect(ShotAvailability.classify(state: rackState(), active: someShot()) == .breakRack)
    }

    @Test("A scatter with no offer is a safety, with an offer it is a shot")
    func scatter() {
        let state = TableState(table: table, balls: [
            ball(0, .cue, -0.9, 0), ball(4, .solid(4), 0.2, 0.1), ball(9, .stripe(9), 0.8, -0.3)
        ])
        #expect(ShotAvailability.classify(state: state, active: nil) == .noCleanShot)
        #expect(ShotAvailability.classify(state: state, active: someShot()) == .shot)
    }

    @Test("A tight cluster smaller than a rack is not a break")
    func partialClusterIsNotARack() {
        var balls = [ball(0, .cue, -0.9, 0)]
        for id in 1...6 { balls.append(ball(id, .solid(id), 0.6 + Double(id) * 0.05, 0)) }
        let state = TableState(table: table, balls: balls)
        #expect(ShotAvailability.classify(state: state, active: nil) == .noCleanShot)
    }

    @Test("Ten balls spread over the table are not a rack")
    func spreadBallsAreNotARack() {
        var balls = [ball(0, .cue, -1.0, 0)]
        for id in 1...12 {
            balls.append(ball(id, .solid(1), -0.8 + Double(id) * 0.14, id.isMultiple(of: 2) ? 0.4 : -0.4))
        }
        let state = TableState(table: table, balls: balls)
        #expect(ShotAvailability.classify(state: state, active: nil) == .noCleanShot)
    }

    @Test("No cue ball, or nothing to shoot at, says nothing")
    func nothingToSay() {
        let noCue = TableState(table: table, balls: [ball(3, .solid(3), 0, 0)])
        #expect(ShotAvailability.classify(state: noCue, active: nil) == .notApplicable)
        let cueOnly = TableState(table: table, balls: [ball(0, .cue, 0, 0)])
        #expect(ShotAvailability.classify(state: cueOnly, active: nil) == .notApplicable)
        #expect(ShotAvailability.classify(state: TableState(table: table, balls: []),
                                          active: nil) == .notApplicable)
    }
}
