//
//  SessionModel+Ranking.swift
//  CueSync AR
//
//  Which ball to shoot at, and how likely it is to go.
//
//  The AR overlay answers "where does my aim go". This answers "which
//  ball should I be aiming at" — CoachKit's ShotRanking rates every ball
//  into every pocket and ShotSelection holds the result, the suggestion
//  and the player's override together.
//
//  Nothing is decided here: the rules live in the pure types, so what the
//  app shows is what the offline tests judge. This file is the wiring and
//  the words.
//

import ARExperience
import BilliardsPhysics
import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation

extension SessionModel {

    // MARK: - Reading

    /// Best pocket per ball, best ball first.
    var shotRanking: [ShotRating] { shotSelection.ranking }
    /// The shot being shown: the player's pick, else the app's suggestion.
    var activeShot: ShotRating? { shotSelection.active }
    /// True when the active shot is the player's choice rather than the
    /// app's — the HUD says so, because a suggestion the player did not
    /// make should never look like one they did.
    var targetIsPlayerChosen: Bool { shotSelection.isPlayerChosen }
    var ballGroup: BallGroup { settings.ballGroup }

    // MARK: - Recomputing

    /// Re-rank on the latest tracked state. Called on every pipeline
    /// output: six balls into six pockets is a few dozen closed-form
    /// evaluations, far cheaper than the solve that follows it.
    func recomputeRanking() {
        guard let state = tableState else {
            shotSelection.clear()
            return
        }
        shotSelection.update(state: state,
                             group: settings.ballGroup,
                             config: settings.skillLevel.rankingConfig)
        refreshTargetOverlay()
        // The offered shot may have changed, which is the one thing the
        // voice most wants to announce (SessionModel+Speech).
        narrateIfNeeded()
    }

    func clearRanking() {
        shotSelection.clear()
        targetOverlay = nil
    }

    /// Solve the shot the app is offering, so the overlay can draw how to
    /// make it — not just say how likely it is.
    ///
    /// This is the prescription to the live guide's description. Both use
    /// the same solver, the same speed and the same trim policy, so the
    /// two lines are directly comparable: the gap between them is exactly
    /// the correction the player has to make.
    func refreshTargetOverlay() {
        guard let state = tableState, let shot = activeShot, shot.blocker == nil,
              let prediction = TargetGuide.plan(state: state,
                                                ghostBall: shot.ghostBall,
                                                solver: targetSolver,
                                                speed: guideSpeed,
                                                maxEvents: shotPlanner.config.maxEvents,
                                                policy: shotPlanner.config.guide) else {
            targetOverlay = nil
            return
        }
        targetOverlay = OverlayLayout.Target(prediction: prediction,
                                             ball: shot.ball,
                                             pocket: shot.pocket,
                                             ghostBall: shot.ghostBall)
    }

    /// The aim that makes the offered shot, or nil when there is none.
    private var idealAim: AimRay? {
        guard let state = tableState, let cue = state.cueBall, let shot = activeShot,
              shot.blocker == nil else { return nil }
        return TargetGuide.aim(cueBall: cue, ghostBall: shot.ghostBall)
    }

    /// Which way to move to get on the offered shot. Nil when the player
    /// is not aiming, or there is nothing to aim at.
    ///
    /// A cue lying on the cloth still produces an aim — that is what the
    /// stick detector sees — so `stickIsResting` gates the advice as well
    /// as the angle. Advising on a resting cue is how the card ended up
    /// offering to correct a 52° error at the table on 2026-09-09.
    var targetCorrection: TargetGuide.Correction? {
        guard !shotPlanner.stickIsResting else { return nil }
        return TargetGuide.correction(current: shotPlanner.plan?.aim, ideal: idealAim)
    }

    /// How far off that aim is, in degrees — the number the feature exists
    /// to shrink, and the one the mirror reports.
    var targetAimErrorDegrees: Double? {
        TargetGuide.aimError(current: shotPlanner.plan?.aim, ideal: idealAim)
    }

    /// Hand the choice back to the app without needing to know which ball
    /// is currently held.
    func clearTarget() {
        guard let state = tableState, let target = shotSelection.target,
              let ball = state.balls.first(where: { $0.id == target }) else { return }
        _ = shotSelection.chooseTarget(near: ball.position, in: state, maxDistance: 0.01)
    }

    // MARK: - Choosing a ball

    /// Make the tracked ball nearest `tablePoint` the target, or release
    /// it when it is already selected.
    ///
    /// Returns false when no rankable ball is close enough, so the caller
    /// can fall through to another reading of the tap rather than
    /// swallowing it silently — the failure mode this codebase has already
    /// paid for once.
    @discardableResult
    func selectTarget(near tablePoint: Vec2, maxDistance: Double = 0.25) -> Bool {
        guard let state = tableState else { return false }
        switch shotSelection.chooseTarget(near: tablePoint, in: state, maxDistance: maxDistance) {
        case .missed:
            return false
        case .released:
            refreshTargetOverlay()
            Self.log.info("target released")
            showTapFeedback("Back to the suggested shot")
            return true
        case .selected(let rating):
            refreshTargetOverlay()
            let summary = "target=\(rating.ball.rawValue) p=\(rating.percentage)%"
                + " pocket=\(rating.pocket.rawValue)"
            Self.log.info("target selected: \(summary, privacy: .public)")
            showTapFeedback(rating.headline)
            // Deliberately not recorded as a RecordedEvent yet: a replayed
            // target only means something once the ranking is in the
            // replay output schema, and adding a case ReplayRunner ignores
            // would be worse than not having it.
            return true
        }
    }

    /// Whether a tap landed on the ball currently acting as the cue ball.
    ///
    /// Kept separate from `selectTarget` so designation keeps working: a
    /// player whose measle ball is tracked as an object ball still has to
    /// be able to say "this one is the cue ball", and to take it back.
    func tapIsOnTheCueBall(near tablePoint: Vec2, maxDistance: Double = 0.25) -> Bool {
        guard let state = tableState, let cue = state.cueBall else { return false }
        let toCue = cue.position.distance(to: tablePoint)
        guard toCue <= maxDistance else { return false }
        // Only when it is also the nearest ball, so a tap between the cue
        // ball and a neighbour cannot silently clear the designation.
        return state.balls.allSatisfy {
            $0.id == cue.id || $0.position.distance(to: tablePoint) >= toCue
        }
    }

    // MARK: - Group and skill

    /// Choose which half of the rack the ranking offers.
    func setBallGroup(_ group: BallGroup) {
        guard settings.ballGroup != group else { return }
        updateSettings { $0.ballGroup = group }
        recomputeRanking()
        showTapFeedback("Shooting \(group.label.lowercased())")
        Self.log.info("ball group -> \(group.rawValue, privacy: .public)")
    }

    /// Cycle the group from the HUD: solids, stripes, open, and back.
    ///
    /// The eight is not in the cycle — it is reached by clearing the table
    /// or from Settings, never by a stray tap mid-rack.
    func cycleBallGroup() {
        let next: BallGroup = switch settings.ballGroup {
        case .solids: .stripes
        case .stripes: .any
        case .any, .eight: .solids
        }
        setBallGroup(next)
    }

    func setSkillLevel(_ level: SkillLevel) {
        guard settings.skillLevel != level else { return }
        updateSettings { $0.skillLevel = level }
        recomputeRanking()
        Self.log.info("skill -> \(level.rawValue, privacy: .public)")
    }
}

extension ShotConfidence {
    /// Bridge CoachKit's band to the design system's, so CueSyncUI keeps
    /// depending on CueSyncCore alone.
    init(_ difficulty: ShotRating.Difficulty) {
        self = switch difficulty {
        case .easy: .easy
        case .medium: .medium
        case .hard: .hard
        case .longShot: .longShot
        case .blocked: .blocked
        }
    }
}

extension SessionModel {
    /// Group, skill and target commands from the mirror. Returns false for
    /// anything it does not recognise.
    func handleShotSelectionMirrorCommand(_ params: [String: String]) -> Bool {
        switch params["action"] {
        case "setGroup":
            guard let raw = params["group"], let group = BallGroup(rawValue: raw) else { return false }
            setBallGroup(group)
        case "setSkill":
            guard let raw = params["skill"], let level = SkillLevel(rawValue: raw) else { return false }
            setSkillLevel(level)
            showTapFeedback("Skill: \(level.title) (remote)")
        case "target":
            // Same generous radius as `designate`: the caller clicked a
            // listed ball's own coordinates, not a screen guess.
            guard let x = params["x"].flatMap(Double.init),
                  let y = params["y"].flatMap(Double.init) else { return false }
            if !selectTarget(near: Vec2(x, y), maxDistance: 0.4) {
                showTapFeedback("No rankable ball near that point (remote)")
            }
        case "clearTarget":
            clearTarget()
            showTapFeedback("Back to the suggested shot (remote)")
        default:
            return false
        }
        return true
    }
}
