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

/// Cue-ball tip guidance beside the shot the app is offering. Sits at the
/// bottom left, above the control bar, so it never covers the cloth in the
/// middle of the frame.
struct ShotAdviceCluster: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        if model.isLiveTracking, model.shotGuide != nil || model.activeShot != nil {
            HStack(alignment: .bottom, spacing: 10) {
                if let guide = model.shotGuide {
                    CueBallGuideView(tipOffset: guide.tipOffset,
                                     headline: guide.headline,
                                     cutAngleDegrees: guide.cutAngleDegrees)
                }
                if let shot = model.activeShot {
                    ShotCard(percentage: shot.blocker == nil ? shot.percentage : nil,
                             pocket: shot.blocker == nil ? shot.pocket.spokenName : nil,
                             confidence: ShotConfidence(shot.difficulty),
                             chosenByPlayer: model.targetIsPlayerChosen,
                             blockedReason: shot.blocker == nil ? nil : shot.headline,
                             group: model.ballGroup == .any ? nil : model.ballGroup.label,
                             aimAdvice: model.targetCorrection?.advice)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .transition(.opacity)
        }
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
                .font(.footnote.weight(.semibold))
        }
        .accessibilityLabel("Shooting \(model.ballGroup.label). Tap to change group.")
    }
}
