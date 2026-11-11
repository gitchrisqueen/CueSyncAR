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
import CueSyncCore
import CueSyncUI
import SwiftUI

/// Cue-ball tip guidance beside the shot the app is offering.
///
/// It is a full-screen, hit-test-free layer that puts the cluster where the
/// TABLE is not (HUDPlacement.clusterPlan): the bottom edge when there is
/// clear screen there, else the band under the status capsule, else a side
/// column, and on a phone or when nothing is free a one-line pill. It never
/// disappears for lack of room.
struct ShotAdviceCluster: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.hudBottomInset) private var bottomInset
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Points reserved at the top for the status capsule, a recording badge
    /// and one toast, below the safe area, plus the scoreboard chip when on.
    private static let baseTopReserve = 124.0
    private static let scoreChipReserve = 38.0
    private var topReserve: Double {
        Self.baseTopReserve + (model.settings.showScoreboard ? Self.scoreChipReserve : 0)
    }
    private static let sideInset = 16.0

    var body: some View {
        // The cluster fades in and out instead of popping (Reduce Motion:
        // opacity only, no scale).
        ZStack { clusterIfAny }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.22), value: isShowing)
    }

    private var isShowing: Bool {
        model.isLiveTracking
            && (model.shotGuide != nil || model.activeShot != nil || model.shotEmptyState != nil)
    }

    @ViewBuilder
    private var clusterIfAny: some View {
        let empty = model.shotEmptyState
        if isShowing {
            // The outer reader respects the safe area, so it can report it;
            // the inner one ignores it, so its size is the whole screen,
            // the space the table's projected corners are in.
            GeometryReader { outer in
              GeometryReader { proxy in
                let size = Vec2(Double(proxy.size.width), Double(proxy.size.height))
                let insets = HUDClusterInsets(
                    top: Double(outer.safeAreaInsets.top) + topReserve,
                    bottom: Double(outer.safeAreaInsets.bottom + bottomInset) + 8,
                    side: Self.sideInset)
                let plan = model.presentation.clusterPlan(
                    viewport: size, sizes: sizes(viewport: size), insets: insets)
                cluster(plan: plan, empty: empty)
                    .padding(.horizontal, insets.side)
                    .padding(.top, insets.top)
                    .padding(.bottom, insets.bottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: alignment(plan.anchor))
                    .animation(.easeInOut(duration: 0.2), value: plan.anchor)
                    .animation(.easeInOut(duration: 0.2), value: plan.style)
                    .animation(.easeInOut(duration: 0.2), value: shotKey)
              }
              .ignoresSafeArea()
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func alignment(_ anchor: HUDClusterAnchor) -> Alignment {
        switch anchor {
        case .bottomLeading, .leadingColumn: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomTrailing, .trailingColumn: .bottomTrailing
        case .topCenter: .top
        }
    }

    @ViewBuilder
    private func cluster(plan: HUDClusterPlan, empty: ShotEmptyState?) -> some View {
        switch plan.style {
        case .wide:
            HStack(alignment: .bottom, spacing: 10) {
                guide(compact: false)
                shot(empty: empty, style: .full)
            }
        case .column:
            VStack(alignment: .leading, spacing: 10) {
                guide(compact: false)
                shot(empty: empty, style: .full)
                    .frame(width: Self.columnWidth)
            }
        case .pill:
            HStack(alignment: .center, spacing: 8) {
                guide(compact: true)
                shot(empty: empty, style: .pill)
            }
        }
    }

    @ViewBuilder
    private func guide(compact: Bool) -> some View {
        if let guide = model.shotGuide {
            CueBallGuideView(tipOffset: guide.tipOffset, headline: guide.headline,
                             cutAngleDegrees: guide.cutAngleDegrees, compact: compact)
        }
    }

    @ViewBuilder
    private func shot(empty: ShotEmptyState?, style: ShotCardStyle) -> some View {
        if let empty {
            // A full rack or no clean pot: say so, instead of the card
            // vanishing and the player wondering if the app has stopped. A
            // rack outranks any shot rated into it.
            ShotEmptyCapsule(state: empty)
                .transition(cardTransition)
        } else if let shot = model.activeShot {
            // Keyed on the shot, so a new suggestion cross-fades (~200 ms)
            // from the old card rather than the text changing under the
            // player's eyes.
            card(for: shot, style: style)
                .successPulse(model.feedback.madePulseCount)
                .id(shotKey)
                .transition(cardTransition)
        }
    }

    private var shotKey: String {
        model.activeShot.map { "\($0.ball.rawValue).\($0.pocket.rawValue)" } ?? "none"
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    // MARK: Sizes the plan reasons with

    static let columnWidth = 260.0

    /// Rough drawn sizes, in points: enough to keep clear of the cloth, not
    /// pixel measurements (the views size themselves).
    private func sizes(viewport: Vec2) -> HUDClusterSizes {
        let regular = sizeClass == .regular
        let guideFull = model.shotGuide.map { Self.isCentreHit($0.tipOffset) ? 64.0 : 130.0 } ?? 0
        let guideTall = model.shotGuide.map { Self.isCentreHit($0.tipOffset) ? 64.0 : 170.0 } ?? 0
        let cardWidth = regular ? HUDMetrics.cardWidthRegular : HUDMetrics.cardWidthCompact
        let hasAdvice = model.targetCorrection?.advice != nil
        let cardHeight = (regular ? 150.0 : 130.0) + (hasAdvice ? (regular ? 30 : 22) : 0)
        let wide = Vec2(cardWidth + (guideFull > 0 ? guideFull + 10 : 0),
                        max(cardHeight, guideTall))
        let column = Vec2(max(Self.columnWidth, guideFull),
                          cardHeight * (regular ? 1.7 : 1.5) + (guideTall > 0 ? guideTall + 10 : 0))
        let pillWidth = min(viewport.x - 2 * Self.sideInset, regular ? 620 : 520)
        let pill = Vec2(pillWidth, max(64, (regular ? 72 : 76) + (hasAdvice ? (regular ? 30 : 22) : 0)))
        return HUDClusterSizes(wide: wide, column: column, pill: pill)
    }

    private static func isCentreHit(_ tip: Vec2) -> Bool {
        abs(tip.x) < 0.05 && abs(tip.y) < 0.05
    }

    /// The card: the ball and the pocket in the player's words, and how
    /// hard it is as a word. The percentage is not shown; it stays in the
    /// mirror's state.json.
    private func card(for shot: ShotRating, style: ShotCardStyle) -> some View {
        let call = shot.blocker == nil ? model.shotCall(for: shot) : nil
        return ShotCard(ball: call?.ball,
                        pocket: call?.pocket,
                        confidence: ShotConfidence(model.shownDifficulty(of: shot)),
                        chosenByPlayer: model.targetIsPlayerChosen,
                        blockedReason: shot.blocker == nil ? nil : shot.headline,
                        group: model.ballGroup == .any ? nil : model.ballGroup.label,
                        aimAdvice: model.targetCorrection?.advice,
                        style: style)
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
        }
        .accessibilityLabel("Shooting \(model.ballGroup.label). Tap to change group.")
        .accessibilityIdentifier("ball-group-button")
    }
}
