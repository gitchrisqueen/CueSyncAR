//
//  JawConeSweepTests.swift
//  CoachKitTests
//
//  Derives the planner's jaw acceptance cones from the real AnalyticSolver
//  instead of trusting hand-picked constants. A single ball is rolled at the
//  pocket mouth center from several distances, at angles off the pocket's
//  inward axis from 0 to 80 degrees (both signs), and the widest angle at
//  which it still drops is recorded. The solver models a pocket as an
//  idealized capture circle, so these are solver-consistent bounds, not
//  measurements of real jaws.
//
//  Two different things can end a sweep row, and they must not be confused:
//  - solver-limited: a legal start position exists at the angle and the
//    solver does not pocket the ball (the cone really ends there);
//  - reach-limited: every legal start position pots, but beyond some angle
//    no legal start exists (a ball cannot sit inside the rail), so the table
//    itself caps the approach and the cone is only bounded from below.
//

import BilliardsPhysics
import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

/// Test-support sweep: how wide a cone does the solver accept at a pocket?
enum JawConeSweep {
    /// Firm speed so no sweep point dies on the cloth: 4 m/s rolls about
    /// 16 m at the solver's 0.5 m/s² deceleration, far more than 1 m.
    static let speed = 4.0
    static let distances = [0.3, 0.6, 1.0]
    static let maxAngleDegrees = 80

    struct Row {
        let pocket: PocketID
        let distance: Double
        /// First legal angle (whole degrees, either sign) at which the ball
        /// does not drop; nil when every legal angle drops.
        let firstFailDegrees: Int?
        /// Largest angle with a legal start position (either sign).
        let maxLegalDegrees: Int
        /// Largest angle at which the ball drops at all.
        let largestPottedDegrees: Int

        /// Cone half-angle for this distance: the last angle before the first
        /// failure, or the largest legal angle when nothing fails.
        var coneDegrees: Int {
            firstFailDegrees.map { $0 - 1 } ?? maxLegalDegrees
        }

        /// True when the solver, not the table edge, ended the sweep.
        var solverLimited: Bool { firstFailDegrees != nil }
    }

    /// Inward axis of a pocket, matching the planner's definition.
    static func inwardAxis(of pocket: Pocket) -> Vec2 {
        if pocket.id == .sideTop || pocket.id == .sideBottom {
            return Vec2(0, pocket.position.y >= 0 ? 1 : -1)
        }
        return Vec2(pocket.position.x >= 0 ? 1 : -1,
                    pocket.position.y >= 0 ? 1 : -1).normalized
    }

    /// nil when the start position is not a legal ball position.
    static func drops(table: Table, pocket: Pocket, distance: Double,
                      degrees: Int, sign: Double) -> Bool? {
        // Travel direction: the pocket's inward axis turned off by `degrees`.
        let travel = inwardAxis(of: pocket)
            .rotated(by: sign * Double(degrees) * .pi / 180)
        let start = pocket.position - travel * distance
        let ball = Ball(id: BallID(0), kind: .cue, position: start)
        guard table.contains(start, ballRadius: ball.radius) else { return nil }
        let state = TableState(table: table, balls: [ball])
        let prediction = AnalyticSolver().predict(
            state: state, aim: AimRay(origin: start, direction: travel),
            options: SolverOptions(initialSpeed: speed))
        return prediction.events.contains {
            if case .pocket(_, let id) = $0 { return id == pocket.id }
            return false
        }
    }

    static func run(table: Table = Table(size: .nineFoot)) -> [Row] {
        var rows: [Row] = []
        // One representative per type: corners and sides are symmetric.
        for id in [PocketID.cornerTopRight, .sideTop] {
            guard let pocket = table.pockets.first(where: { $0.id == id }) else { continue }
            for distance in distances {
                var firstFail: Int?
                var maxLegal = 0
                var largest = 0
                for degrees in 0...maxAngleDegrees {
                    for sign in [1.0, -1.0] {
                        guard let dropped = drops(table: table, pocket: pocket,
                                                  distance: distance, degrees: degrees,
                                                  sign: sign) else { continue }
                        maxLegal = Swift.max(maxLegal, degrees)
                        if dropped { largest = Swift.max(largest, degrees) }
                        if !dropped, firstFail == nil { firstFail = degrees }
                    }
                }
                rows.append(Row(pocket: id, distance: distance,
                                firstFailDegrees: firstFail,
                                maxLegalDegrees: maxLegal,
                                largestPottedDegrees: largest))
            }
        }
        return rows
    }

    /// Conservative cone for a pocket type. Solver-limited rows give the real
    /// bound (minimum across distances). When no row is solver-limited the
    /// solver accepts everything the table can present, so the cone is only
    /// bounded below by the widest reach seen.
    static func cone(_ rows: [Row], pocket: PocketID)
        -> (degrees: Int, solverLimited: Bool) {
        let mine = rows.filter { $0.pocket == pocket }
        let limited = mine.filter(\.solverLimited)
        if let tightest = limited.map(\.coneDegrees).min() {
            return (tightest, true)
        }
        return (mine.map(\.coneDegrees).max() ?? 0, false)
    }
}

@Suite("Jaw cone sweep")
struct JawConeSweepTests {
    private let rows = JawConeSweep.run()
    private let planner = ShotPlanner.Config()

    private func row(_ pocket: PocketID, _ distance: Double) -> JawConeSweep.Row? {
        rows.first { $0.pocket == pocket && $0.distance == distance }
    }

    @Test func printSweepTable() {
        for row in rows {
            let limit = row.solverLimited ? "solver-limited" : "reach-limited"
            print("JAWSWEEP \(row.pocket.rawValue) d=\(row.distance) m "
                  + "cone=\(row.coneDegrees)° maxLegal=\(row.maxLegalDegrees)° "
                  + "largestPotted=\(row.largestPottedDegrees)° \(limit)")
        }
        #expect(rows.count == JawConeSweep.distances.count * 2)
    }

    /// Measured: corner cone 39° / 42° / 43° at 0.3 / 0.6 / 1.0 m. No row is
    /// ended by the solver: every ball that can legally sit at that angle
    /// drops. The shrinking number at short range is the cushion line (a
    /// ball center cannot be within one radius of a rail), not the pocket.
    @Test func cornerSweepIsLimitedByTableReachNotBySolver() throws {
        let expected: [Double: Int] = [0.3: 39, 0.6: 42, 1.0: 43]
        for (distance, degrees) in expected {
            let measured = try #require(row(.cornerTopRight, distance))
            #expect(!measured.solverLimited, "corner d=\(distance) failed at \(measured.firstFailDegrees ?? -1)°")
            #expect(abs(measured.coneDegrees - degrees) <= 1,
                    "corner d=\(distance): cone \(measured.coneDegrees)°, pinned \(degrees)°")
        }
        let cone = JawConeSweep.cone(rows, pocket: .cornerTopRight)
        #expect(!cone.solverLimited)
        // The planner's constant agrees with the solver within 2°, and is
        // never wider than what the solver accepts.
        #expect(abs(Double(cone.degrees) - planner.cornerAcceptanceDegrees) <= 2)
        #expect(planner.cornerAcceptanceDegrees <= Double(cone.degrees))
    }

    /// Measured: side cone 79° at every distance; the ball first misses at
    /// 80° because the rail rebound carries it just outside the 0.058 m
    /// capture circle. The solver's side pocket is far more forgiving than
    /// a real one, so the planner deliberately stays tighter (29°).
    @Test func sideSweepIsLimitedBySolverAt79Degrees() throws {
        for distance in JawConeSweep.distances {
            let measured = try #require(row(.sideTop, distance))
            #expect(measured.solverLimited, "side d=\(distance) never failed")
            #expect(abs(measured.coneDegrees - 79) <= 1,
                    "side d=\(distance): cone \(measured.coneDegrees)°, pinned 79°")
        }
        let cone = JawConeSweep.cone(rows, pocket: .sideTop)
        #expect(cone.solverLimited)
        #expect(planner.sideAcceptanceDegrees <= Double(cone.degrees),
                "planner side cone must not exceed what the solver accepts")
    }
}
