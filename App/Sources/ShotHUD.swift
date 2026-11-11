//
//  ShotHUD.swift
//  CueSync AR
//
//  The two pieces of HUD that answer "which ball, and how likely": the
//  advice cluster above the control bar, and the group switch inside it.
//
//  Their own file rather than more of RootView, which is already over
//  SwiftLint's file-length warning and is the subject of a standing
//  complaint in docs/design/onboarding-and-app-shell.md.
//

import CoachKit
import CueSyncUI
import SwiftUI

/// Cue-ball tip guidance beside the shot the app is offering. Sits along
/// the bottom, above the control bar, and moves to keep clear of the
/// pockets.
struct ShotAdviceCluster: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        let empty = model.shotEmptyState
        if model.isLiveTracking, model.shotGuide != nil || model.activeShot != nil || empty != nil {
            let side = model.presentation.clusterSide
            HStack(alignment: .bottom, spacing: 10) {
                // Along the bottom edge, at whichever of left, middle and
                // right has no pocket under it (HUDPlacement).
                if side != .leading { Spacer(minLength: 0) }
                if let guide = model.shotGuide {
                    CueBallGuideView(tipOffset: guide.tipOffset,
                                     headline: guide.headline,
                                     cutAngleDegrees: guide.cutAngleDegrees)
                }
                if let empty {
                    // A full rack or no clean pot: say so, instead of the
                    // card vanishing and the player wondering if the app
                    // has stopped. A rack outranks any shot rated into it.
                    ShotEmptyCapsule(state: empty)
                } else if let shot = model.activeShot {
                    card(for: shot)
                }
                if side != .trailing { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: side)
        }
    }

    /// The card: the ball and the pocket in the player's words, and how
    /// hard it is as a word. The percentage is not shown; it stays in the
    /// mirror's state.json.
    private func card(for shot: ShotRating) -> some View {
        let call = shot.blocker == nil ? model.shotCall(for: shot) : nil
        return ShotCard(ball: call?.ball,
                        pocket: call?.pocket,
                        confidence: ShotConfidence(model.shownDifficulty(of: shot)),
                        chosenByPlayer: model.targetIsPlayerChosen,
                        blockedReason: shot.blocker == nil ? nil : shot.headline,
                        group: model.ballGroup == .any ? nil : model.ballGroup.label,
                        aimAdvice: model.targetCorrection?.advice)
    }
}

/// Which half of the rack the ranking offers.
///
/// A tap cycles solids → stripes → open. During a game this changes about
/// once, and a menu for a three-way toggle is a menu too many.
struct BallGroupButton: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        Button {
            model.cycleBallGroup()
        } label: {
            Text(model.ballGroup.label)
                .lineLimit(1)
        }
        .accessibilityLabel("Shooting \(model.ballGroup.label). Tap to change group.")
        .accessibilityIdentifier("ball-group-button")
    }
}
