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

    /// What the slot shows now (SessionModel+ShotSlot decides: a payoff for
    /// its second, the called pocket's shot when a pocket is called, else
    /// the suggestion).
    private var content: ShotSlotContent? { model.shotSlotContent }

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
        .animation(.easeInOut(duration: PayoffTiming.fadeSeconds(reduceMotion: reduceMotion)),
                   value: contentKey)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func slot(_ content: ShotSlotContent) -> some View {
        switch content {
        case .payoff(let event):
            PayoffCard(event: event)
                .id(event.id)
        case .empty(let state):
            ShotEmptyCapsule(state: state)
        case .shot(let shot, let isCalled):
            // Keyed on the shot, so a new suggestion cross-fades (~200 ms)
            // from the old card rather than the text changing under the
            // player's eyes.
            card(for: shot, isCalled: isCalled)
                .successPulse(model.feedback.madePulseCount)
                .id(shotKey(shot))
        case .guide(let guide):
            CueBallGuideCard(tipOffset: guide.tipOffset, headline: guide.headline)
        }
    }

    /// Changes when the slot changes what it shows, so the fade runs.
    private var contentKey: String {
        switch content {
        case .payoff(let event): "payoff.\(event.id)"
        case .empty(let state): "empty.\(state.text)"
        case .shot(let shot, _): "shot.\(shotKey(shot))"
        case .guide: "guide"
        case nil: "none"
        }
    }

    private func shotKey(_ shot: ShotRating) -> String {
        "\(shot.ball.rawValue).\(shot.pocket.rawValue)"
    }

    private var cardTransition: AnyTransition {
        PayoffTiming.scalesIn(reduceMotion: reduceMotion)
            ? .opacity.combined(with: .scale(scale: 0.96)) : .opacity
    }

    /// The card: the ball and the pocket in the player's words as one big
    /// line, how hard it is as a word, and the strike tile when the advice
    /// is not centre ball. The percentage is not shown; it stays in the
    /// mirror's state.json.
    private func card(for shot: ShotRating, isCalled: Bool) -> some View {
        // The name comes from the rated ball's own id and nothing else
        // (`ShotCall.make`), the same id the overlay highlights.
        let call = model.shotCall(for: shot)
        let blocked = shot.blocker != nil
        let aim = blocked ? nil : model.aimLine
        return ShotCard(ball: call.ball,
                        leadBall: call.leadBall,
                        // A blocked pick names no pocket unless the pocket is
                        // the one called: then the reason is for that pocket.
                        pocket: (blocked && !isCalled) ? nil : call.pocket,
                        confidence: ShotConfidence(model.shownDifficulty(of: shot)),
                        chosenByPlayer: model.targetIsPlayerChosen,
                        blockedReason: blocked ? model.blockedReason(for: shot) : nil,
                        aimAdvice: aim?.text,
                        aimTone: aim?.tone ?? .neutral,
                        isCalled: isCalled,
                        scoreText: model.cardScoreText,
                        tipOffset: model.shotGuide?.tipOffset)
    }
}
