//
//  TargetGuide.swift
//  ARExperience
//
//  How to shoot the ball you picked.
//
//  The live guide answers "where does my aim go" — it follows the cue and
//  is a description. This answers "where should the cue ball go to make
//  this" — it starts from the ranked shot's ghost-ball position and is a
//  prescription. Both are needed and they are not the same line: the gap
//  between them is the correction the player has to make.
//
//  The prescription is SOLVED, not drawn as two straight lines. Running
//  the ideal aim through the same solver at the same speed and trimming it
//  with the same policy means what the player sees is the real predicted
//  outcome — the object ball's path to the pocket AND where the cue ball
//  finishes — rather than an artist's impression of one.
//

import CueSyncCore
import Foundation

public enum TargetGuide {
    /// The aim that sends the cue ball's centre through `ghostBall`.
    ///
    /// Nil when the cue ball is already sitting on the ghost position:
    /// there is no direction to shoot, and a normalized zero vector would
    /// silently become (1, 0).
    public static func aim(cueBall: Ball, ghostBall: Vec2) -> AimRay? {
        let toGhost = ghostBall - cueBall.position
        guard toGhost.length > 1e-6 else { return nil }
        return AimRay(origin: cueBall.position, direction: toGhost)
    }

    /// Solve the shot that makes the chosen ball, trimmed the same way the
    /// live guide is.
    ///
    /// Returns nil when there is no cue ball, no aim, or the solve produces
    /// nothing worth drawing — never an empty prediction, so a caller can
    /// treat nil as "draw nothing" without inspecting the contents.
    public static func plan(state: TableState,
                            ghostBall: Vec2,
                            solver: some TrajectorySolving,
                            speed: Double,
                            maxEvents: Int = 8,
                            policy: GuidePolicy = .default) -> ShotPrediction? {
        guard let cue = state.cueBall, let ray = aim(cueBall: cue, ghostBall: ghostBall) else {
            return nil
        }
        let solved = solver.predict(
            state: state, aim: ray,
            options: SolverOptions(initialSpeed: speed, maxEvents: maxEvents))
        let trimmed = GuidePolicy.trim(solved, cueID: cue.id, policy: policy)
        return trimmed.segments.isEmpty ? nil : trimmed
    }

    /// How far the player's current aim is from the aim that makes the
    /// chosen shot, in degrees. Nil without both.
    ///
    /// This is the number the whole feature exists to shrink, so it is
    /// computed here rather than left for a view to work out — and it is
    /// what the HUD can say out loud ("a touch left").
    public static func aimError(current: AimRay?, ideal: AimRay?) -> Double? {
        guard let current, let ideal else { return nil }
        // atan2(|cross|, dot) rather than acos(dot). Both are correct in
        // exact arithmetic, but acos loses precision exactly where this
        // value matters most: near zero, where its derivative is
        // unbounded, so a dot product one ulp below 1 reports a degree
        // error of ~1e-6 instead of ~1e-17. atan2 is stable across the
        // whole range.
        let d = current.direction
        let i = ideal.direction
        return atan2(abs(d.cross(i)), d.dot(i)) * 180 / .pi
    }

    /// Which way the player has to move to close that gap, from the cue
    /// ball's point of view looking down the shot.
    public enum Correction: String, Sendable, Equatable {
        case onLine
        case left
        case right

        public var advice: String {
            switch self {
            case .onLine: "On line"
            case .left: "Aim a little left"
            case .right: "Aim a little right"
            }
        }
    }

    /// `tolerance` is in degrees; inside it the aim reads as on line.
    ///
    /// The default is deliberately coarser than the aim tolerance a pot
    /// actually needs (often under a tenth of a degree at distance). This
    /// is guidance for a human hand, not a target-lock: telling someone
    /// they are 0.09° left is noise they cannot act on.
    public static func correction(current: AimRay?, ideal: AimRay?,
                                  tolerance: Double = 1.0) -> Correction? {
        guard let current, let ideal,
              let error = aimError(current: current, ideal: ideal) else { return nil }
        guard error > tolerance else { return .onLine }
        // Positive cross product = ideal lies counter-clockwise of current,
        // which in table space (x right, y up) is to the player's left.
        return current.direction.cross(ideal.direction) > 0 ? .left : .right
    }
}
