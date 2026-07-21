//
//  ShotGuide.swift
//  CoachKit
//
//  Deterministic cue-tip guidance — CoachKit's first shipping content
//  (the LLM adapters remain post-MVP). Given the tracked state and the
//  current prediction, recommends where on the cue ball's face to strike
//  (normalized tip offset) with an honest, teaching-style reason.
//
//  Honesty rule: the trajectory solver is spin-blind until TrajectorySolving
//  v2, so recommendations stick to standard fundamentals (center, stun,
//  draw) that don't require simulating english — never a claim the physics
//  can't back.
//

import CueSyncCore
import Foundation

public struct ShotGuide: Sendable, Equatable {
    public enum Spin: String, Sendable, Equatable {
        case center
        case stun
        case draw
    }

    /// Tip contact on the cue-ball face: x right, y up, unit = ball radius
    /// (−1...1); (0, 0) is a center-ball hit.
    public var tipOffset: Vec2
    public var spin: Spin
    public var headline: String
    public var detail: String
    /// Cut angle in degrees (0 = dead straight); nil without a contact.
    public var cutAngleDegrees: Double?

    public init(tipOffset: Vec2, spin: Spin, headline: String,
                detail: String, cutAngleDegrees: Double?) {
        self.tipOffset = tipOffset
        self.spin = spin
        self.headline = headline
        self.detail = detail
        self.cutAngleDegrees = cutAngleDegrees
    }

    public static func recommend(state: TableState,
                                 prediction: ShotPrediction) -> ShotGuide {
        guard let cue = state.cueBall else {
            return ShotGuide(tipOffset: .zero, spin: .center,
                             headline: "Find the cue ball",
                             detail: "No cue ball is being tracked yet.",
                             cutAngleDegrees: nil)
        }
        guard let contact = prediction.firstContact else {
            return ShotGuide(tipOffset: .zero, spin: .center,
                             headline: "Center ball",
                             detail: "Aim at an object ball to get shot guidance.",
                             cutAngleDegrees: nil)
        }

        let cutAngle = Self.cutAngleDegrees(cuePosition: cue.position,
                                            contact: contact.contact,
                                            struck: contact.struck,
                                            prediction: prediction)

        if prediction.isScratch(cueBall: cue.id) {
            return ShotGuide(tipOffset: Vec2(0, -0.6), spin: .draw,
                             headline: "Draw — scratch predicted",
                             detail: "Hit well below center to kill the cue "
                                + "ball's roll after contact.",
                             cutAngleDegrees: cutAngle)
        }
        if let cutAngle, cutAngle >= 60 {
            return ShotGuide(tipOffset: .zero, spin: .center,
                             headline: "Thin cut — center ball",
                             detail: "Very thin hit; keep the strike simple "
                                + "and focus on aim and speed.",
                             cutAngleDegrees: cutAngle)
        }
        if let cutAngle, cutAngle <= 15 {
            return ShotGuide(tipOffset: Vec2(0, -0.3), spin: .stun,
                             headline: "Stun — just below center",
                             detail: "Nearly straight; a stun hit stops the "
                                + "cue ball at contact instead of following in.",
                             cutAngleDegrees: cutAngle)
        }
        return ShotGuide(tipOffset: .zero, spin: .center,
                         headline: "Center ball",
                         detail: "Medium cut; a center strike keeps the cue "
                            + "ball's path predictable.",
                         cutAngleDegrees: cutAngle)
    }

    /// Angle between the cue ball's approach into the contact point and the
    /// struck ball's departure direction.
    static func cutAngleDegrees(cuePosition: Vec2, contact: Vec2,
                                struck: BallID,
                                prediction: ShotPrediction) -> Double? {
        let approach = contact - cuePosition
        guard approach.length > 1e-9,
              let departure = prediction.segments(for: struck).first else {
            return nil
        }
        let travel = departure.end - departure.start
        guard travel.length > 1e-9 else { return nil }
        return approach.angle(to: travel) * 180 / .pi
    }
}
