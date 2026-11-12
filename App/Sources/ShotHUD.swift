//
//  ShotHUD.swift
//  CueSync AR
//
//  The piece of HUD that answers "which ball, and how likely": the shot
//  card under the status capsule.
//
//  Its own file rather than more of RootView, which is already over
//  SwiftLint's file-length warning and is the subject of a standing
//  complaint in docs/design/onboarding-and-app-shell.md.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import SwiftUI

/// The shot card (or the reason there is none, or the bare cue-ball guide),
/// in ONE place: the top centre, directly under the status capsule, at one
/// fixed width.
///
/// It used to go wherever the table was not (HUDPlacement.clusterPlan): the
/// bottom, a side column, a one-line pill, so it jumped between states and
/// once covered the left edge where the stick enters. A card that moves is
/// a card the player has to find again after every shot, so it does not.
/// It sits in RootView's top stack, so it can never overlap the capsule
/// whatever the text size, and it never takes a tap (`allowsHitTesting`):
/// balls and pockets under it stay tappable.
struct ShotAdviceCluster: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the slot shows now. The card outranks the bare guide.
    private enum Content {
        case empty(ShotEmptyState)
        case shot(ShotRating)
        case guide(ShotGuide)
    }

    private var content: Content? {
        // No confident card while the app cannot stand behind it: a stale
        // calibration, or a status that says tracking is degraded
        // (`HUDStatus.allowsShotAdvice`). The capsule says why.
        guard model.isLiveTracking, !model.calibrationIsStale,
              model.hudStatus?.allowsShotAdvice ?? true else { return nil }
        // A full rack or no clean pot: say so, instead of the card
        // vanishing and the player wondering if the app has stopped. A
        // rack outranks any shot rated into it.
        if let empty = model.shotEmptyState { return .empty(empty) }
        if let shot = model.activeShot { return .shot(shot) }
        // Aiming with no shot on offer: the strike advice alone, when it
        // is not just "centre ball".
        if let guide = model.shotGuide,
           HUDCopy.guideWord(tipOffset: guide.tipOffset) != nil { return .guide(guide) }
        return nil
    }

    var body: some View {
        // The slot fades in and out instead of popping (Reduce Motion:
        // opacity only, no scale).
        ZStack {
            if let content {
                slot(content)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(cardTransition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22),
                   value: contentKey)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func slot(_ content: Content) -> some View {
        switch content {
        case .empty(let state):
            ShotEmptyCapsule(state: state)
        case .shot(let shot):
            // Keyed on the shot, so a new suggestion cross-fades (~200 ms)
            // from the old card rather than the text changing under the
            // player's eyes.
            card(for: shot)
                .successPulse(model.feedback.madePulseCount)
                .id(shotKey)
        case .guide(let guide):
            CueBallGuideCard(tipOffset: guide.tipOffset, headline: guide.headline)
        }
    }

    /// Changes when the slot changes what it shows, so the fade runs.
    private var contentKey: String {
        switch content {
        case .empty(let state): "empty.\(state.text)"
        case .shot: "shot.\(shotKey)"
        case .guide: "guide"
        case nil: "none"
        }
    }

    private var shotKey: String {
        model.activeShot.map { "\($0.ball.rawValue).\($0.pocket.rawValue)" } ?? "none"
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    /// The card: the ball and the pocket in the player's words as one big
    /// line, how hard it is as a word, and the strike tile when the advice
    /// is not centre ball. The percentage is not shown; it stays in the
    /// mirror's state.json.
    private func card(for shot: ShotRating) -> some View {
        let call = shot.blocker == nil ? model.shotCall(for: shot) : nil
        return ShotCard(ball: call?.ball,
                        pocket: call?.pocket,
                        confidence: ShotConfidence(model.shownDifficulty(of: shot)),
                        chosenByPlayer: model.targetIsPlayerChosen,
                        blockedReason: shot.blocker == nil ? nil : shot.headline,
                        aimAdvice: model.targetCorrection?.advice,
                        tipOffset: model.shotGuide?.tipOffset)
    }
}
