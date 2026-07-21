//
//  AnalyticSolver.swift
//  BilliardsPhysics
//
//  MVP trajectory solver. Deterministic, allocation-light, pure function of
//  its inputs. Physical model (documented in Docs/PhysicsModel.md):
//
//  - Balls roll with constant deceleration (rolling friction).
//  - Ball-ball impacts use the ghost-ball model for equal-mass, friction-free
//    spheres: the struck ball departs along the center line with the normal
//    component of velocity; the moving ball continues along the tangent line
//    with the tangential component (stun — no follow/draw in MVP).
//  - Cushions reflect the velocity component normal to the rail, scaled by a
//    restitution coefficient.
//  - A moving ball whose center passes within a pocket's capture radius is
//    pocketed.
//
//  Known MVP limitations (accepted, see roadmap 03-MODULES):
//  - No spin/english, no throw, no jump/masse.
//  - Moving balls are simulated sequentially against a static snapshot;
//    moving-vs-moving collisions are not modeled.
//

import CueSyncCore
import Foundation

public struct PhysicsConfig: Sendable, Equatable, Codable {
    /// Constant rolling deceleration, m/s². Empirical cloth value for MVP.
    public var rollingDeceleration: Double
    /// Speed multiplier for the normal component after a cushion bounce.
    public var cushionRestitution: Double
    /// Energy-transfer efficiency of a ball-ball impact.
    public var ballBallRestitution: Double
    /// Below this speed (m/s) a ball is considered at rest.
    public var restSpeed: Double

    public init(rollingDeceleration: Double = 0.5,
                cushionRestitution: Double = 0.75,
                ballBallRestitution: Double = 0.96,
                restSpeed: Double = 0.05) {
        self.rollingDeceleration = rollingDeceleration
        self.cushionRestitution = cushionRestitution
        self.ballBallRestitution = ballBallRestitution
        self.restSpeed = restSpeed
    }

    public static let standard = PhysicsConfig()
}

public struct AnalyticSolver: TrajectorySolving {
    public let config: PhysicsConfig

    public init(config: PhysicsConfig = .standard) {
        self.config = config
    }

    public func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction {
        let direction = aim.direction.normalized
        guard direction != .zero, options.initialSpeed > config.restSpeed,
              let cue = state.cueBall else {
            return ShotPrediction()
        }

        var prediction = ShotPrediction()
        var eventCount = 0

        // Static snapshot of every other ball; updated as balls come to rest
        // or get pocketed so later rollouts see the predicted end state.
        var stationary: [BallID: Ball] = [:]
        for ball in state.balls where ball.id != cue.id {
            stationary[ball.id] = ball
        }

        // Queue of balls to roll out, starting with the cue ball from the aim
        // origin (contractually the cue ball's center).
        var queue: [MovingBall] = [
            MovingBall(id: cue.id, radius: cue.radius,
                       position: aim.origin, direction: direction,
                       speed: options.initialSpeed)
        ]

        while !queue.isEmpty {
            var ball = queue.removeFirst()
            rollout: while ball.speed > config.restSpeed {
                guard eventCount < options.maxEvents else {
                    // Budget exhausted: close the polyline where it stands.
                    prediction.events.append(.rest(ball: ball.id, point: ball.position))
                    stationary[ball.id] = ball.asStationary
                    break rollout
                }

                let stopDistance = ball.speed * ball.speed / (2 * config.rollingDeceleration)
                let event = nearestEvent(for: ball, in: state.table,
                                         stationary: stationary, within: stopDistance)

                switch event {
                case nil:
                    // Free roll to rest.
                    let end = ball.position + ball.direction * stopDistance
                    prediction.segments.append(TrajectorySegment(
                        ballID: ball.id, start: ball.position, end: end,
                        kind: .roll, entrySpeed: ball.speed))
                    prediction.events.append(.rest(ball: ball.id, point: end))
                    ball.position = end
                    stationary[ball.id] = ball.asStationary
                    break rollout

                case .pocket(let t, let pocketID, let pocketPosition):
                    let entry = ball.position + ball.direction * t
                    prediction.segments.append(TrajectorySegment(
                        ballID: ball.id, start: ball.position, end: entry,
                        kind: .roll, entrySpeed: ball.speed))
                    prediction.segments.append(TrajectorySegment(
                        ballID: ball.id, start: entry, end: pocketPosition,
                        kind: .intoPocket, entrySpeed: ball.speed(after: t, config: config)))
                    prediction.events.append(.pocket(ball: ball.id, pocket: pocketID))
                    prediction.pocketedBalls.append(ball.id)
                    eventCount += 1
                    break rollout

                case .cushion(let t, let normal):
                    let hit = ball.position + ball.direction * t
                    prediction.segments.append(TrajectorySegment(
                        ballID: ball.id, start: ball.position, end: hit,
                        kind: .roll, entrySpeed: ball.speed))
                    prediction.events.append(.cushion(ball: ball.id, point: hit))
                    eventCount += 1

                    let speedAtHit = ball.speed(after: t, config: config)
                    let vIn = ball.direction * speedAtHit
                    let normalComponent = vIn.dot(normal)
                    let vOut = vIn - normal * (normalComponent * (1 + config.cushionRestitution))
                    ball.position = hit
                    ball.speed = vOut.length
                    ball.direction = vOut.normalized
                    if ball.speed <= config.restSpeed {
                        prediction.events.append(.rest(ball: ball.id, point: hit))
                        stationary[ball.id] = ball.asStationary
                        break rollout
                    }

                case .ballHit(let t, let struckID):
                    guard let struck = stationary[struckID] else { break rollout }
                    let ghostCenter = ball.position + ball.direction * t
                    prediction.segments.append(TrajectorySegment(
                        ballID: ball.id, start: ball.position, end: ghostCenter,
                        kind: .roll, entrySpeed: ball.speed))
                    prediction.events.append(.ballBall(
                        moving: ball.id, struck: struckID, contact: ghostCenter))
                    eventCount += 1

                    let speedAtHit = ball.speed(after: t, config: config)
                    let impactNormal = (struck.position - ghostCenter).normalized
                    let cosTheta = Swift.max(0, ball.direction.dot(impactNormal))

                    // Struck ball departs along the center line.
                    let struckSpeed = speedAtHit * cosTheta * config.ballBallRestitution
                    stationary.removeValue(forKey: struckID)
                    if struckSpeed > config.restSpeed {
                        queue.append(MovingBall(
                            id: struckID, radius: struck.radius,
                            position: struck.position, direction: impactNormal,
                            speed: struckSpeed))
                    } else {
                        stationary[struckID] = struck
                    }

                    // Moving ball continues along the tangent line (stun model).
                    let tangent = ball.direction - impactNormal * cosTheta
                    let tangentSpeed = speedAtHit * tangent.length
                    ball.position = ghostCenter
                    ball.direction = tangent.normalized
                    ball.speed = tangentSpeed
                    if ball.speed <= config.restSpeed || ball.direction == .zero {
                        prediction.events.append(.rest(ball: ball.id, point: ghostCenter))
                        stationary[ball.id] = ball.asStationary
                        break rollout
                    }
                }
            }
        }

        return prediction
    }

    // MARK: - Event search

    private enum RollEvent {
        case ballHit(t: Double, struck: BallID)
        case cushion(t: Double, normal: Vec2)
        case pocket(t: Double, pocket: PocketID, position: Vec2)

        var t: Double {
            switch self {
            case .ballHit(let t, _), .cushion(let t, _), .pocket(let t, _, _): t
            }
        }
    }

    /// Earliest event along the ball's ray within `limit` travel distance.
    private func nearestEvent(for ball: MovingBall, in table: Table,
                              stationary: [BallID: Ball],
                              within limit: Double) -> RollEvent? {
        var best: RollEvent?

        func consider(_ event: RollEvent) {
            if event.t <= limit + 1e-9, event.t < (best?.t ?? .infinity) {
                best = event
            }
        }

        // Ball-ball: sweep a circle of radius r1+r2 along the ray.
        for (id, other) in stationary {
            let sumRadius = ball.radius + other.radius
            let rel = other.position - ball.position
            let proj = rel.dot(ball.direction)
            guard proj > 1e-9 else { continue }
            let perpSq = rel.lengthSquared - proj * proj
            let radiusSq = sumRadius * sumRadius
            guard perpSq < radiusSq else { continue }
            let t = proj - (radiusSq - perpSq).squareRoot()
            if t > 1e-9 { consider(.ballHit(t: t, struck: id)) }
        }

        // Pockets: capture when the center enters the capture circle.
        for pocket in table.pockets {
            let rel = pocket.position - ball.position
            let proj = rel.dot(ball.direction)
            guard proj > 1e-9 else { continue }
            let perpSq = rel.lengthSquared - proj * proj
            let capSq = pocket.captureRadius * pocket.captureRadius
            guard perpSq < capSq else { continue }
            let t = proj - (capSq - perpSq).squareRoot()
            if t > 1e-9 {
                consider(.pocket(t: t, pocket: pocket.id, position: pocket.position))
            }
        }

        // Cushions: the ball center reflects off the field inset by its radius.
        let he = table.halfExtents
        let bounds = Vec2(he.x - ball.radius, he.y - ball.radius)
        if ball.direction.x > 1e-12 {
            consider(.cushion(t: (bounds.x - ball.position.x) / ball.direction.x,
                              normal: Vec2(-1, 0)))
        } else if ball.direction.x < -1e-12 {
            consider(.cushion(t: (-bounds.x - ball.position.x) / ball.direction.x,
                              normal: Vec2(1, 0)))
        }
        if ball.direction.y > 1e-12 {
            consider(.cushion(t: (bounds.y - ball.position.y) / ball.direction.y,
                              normal: Vec2(0, -1)))
        } else if ball.direction.y < -1e-12 {
            consider(.cushion(t: (-bounds.y - ball.position.y) / ball.direction.y,
                              normal: Vec2(0, 1)))
        }

        return best
    }
}

private struct MovingBall {
    let id: BallID
    let radius: Double
    var position: Vec2
    var direction: Vec2
    var speed: Double

    /// Speed after traveling `distance` under rolling deceleration.
    func speed(after distance: Double, config: PhysicsConfig) -> Double {
        let vSq = speed * speed - 2 * config.rollingDeceleration * distance
        return vSq > 0 ? vSq.squareRoot() : 0
    }

    var asStationary: Ball {
        Ball(id: id, kind: .unknown, position: position, radius: radius)
    }
}
