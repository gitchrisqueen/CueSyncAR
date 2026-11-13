//
//  FeedbackViews.swift
//  CueSync AR
//
//  What the arcade feel layer looks like: the banner capsule that takes the
//  toast slot, the scoreboard chip, the success pulse on the shot card, the
//  table-lock flash on the status capsule, and the full-screen effects (table
//  outline flash, pocket ring on a made ball). Settings and More sections for
//  the new switches live here too.
//
//  Motion rule: every animation reads Reduce Motion. With it on, nothing
//  scales, slides or travels; things only fade.
//
//  Colour rule: every text colour is one of Theme's text-grade tokens on the
//  HUD plate (HUDContrastTests holds each to 4.5:1 against the worst
//  backdrop). The glows are decoration; no information is carried by colour
//  alone, because each one has words or a symbol beside it.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import SwiftUI

// MARK: - The banner slot

/// The one slot under the status capsule: a camera-denied or calibration
/// error always wins it, then a feedback banner, then the old transient
/// toast. The scoreboard chip sits under whichever is showing.
struct FeedbackSlot: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: HUDMessage?

    var body: some View {
        VStack(spacing: 6) {
            if let message, message.kind <= .calibrationError {
                HUDToast(message: message)
            } else if let banner = model.feedback.banner {
                FeedbackBannerView(banner: banner)
                    .id(banner.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.88)))
            } else if let message {
                HUDToast(message: message)
            }
            // The score lives IN the card (and the payoff) whenever one is
            // showing, so nothing stacks under it; the chip is only for a
            // screen with no card.
            if model.settings.showScoreboard, model.isLiveTracking, model.shotSlotContent == nil {
                ScoreChip(score: model.feedback.score)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15)
                                : .spring(response: 0.3, dampingFraction: 0.75),
                   value: model.feedback.banner?.id)
    }
}

struct FeedbackBannerView: View {
    let banner: FeedbackCenter.Banner

    var body: some View {
        Label(banner.text, systemImage: banner.symbol)
            .hudFont(.body, weight: .semibold)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            // Before the plate: the nearer foreground style wins, and the
            // plate sets its own white on the outside.
            .foregroundStyle(Self.color(for: banner.tone))
            .hudPlate(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(banner.text)
            .accessibilityIdentifier("feedback-banner")
    }

    static func color(for tone: BannerTone) -> Color {
        switch tone {
        case .good: Theme.easyText.color
        case .neutral: Theme.hudText.color
        case .caution: Theme.fairText.color
        case .bad: Theme.hardText.color
        }
    }
}

/// "3 of 5": shots made out of shots tried this session.
struct ScoreChip: View {
    let score: SessionScore

    var body: some View {
        Label(HUDCopy.scoreLine(chip: score.chipText, streak: score.streak), systemImage: "target")
            .hudFont(.caption, weight: .semibold)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .hudPlate(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(score.spokenText)
            .accessibilityIdentifier("score-chip")
    }
}

// MARK: - Pulses

private struct PulseValue {
    var scale = 1.0
    var glow = 0.0
}

/// A brief green glow (and, unless Reduce Motion, a small swell) each time
/// `trigger` changes. Used on the shot card when a ball goes down.
struct SuccessPulse: ViewModifier {
    let trigger: Int
    var cornerRadius: CGFloat = HUDMetrics.cornerRadius
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: PulseValue(), trigger: trigger) { view, value in
            view
                .scaleEffect(reduceMotion ? 1 : value.scale)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Theme.easyText.color, lineWidth: 3)
                        .opacity(value.glow)
                        .allowsHitTesting(false)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.05, duration: 0.14)
                CubicKeyframe(1.0, duration: 0.32)
            }
            KeyframeTrack(\.glow) {
                LinearKeyframe(1, duration: 0.10)
                LinearKeyframe(0, duration: 0.70)
            }
        }
    }
}

/// The status capsule going green for a moment when the table locks. The
/// capsule's own words ("Tracking N balls", with its check) stay put; this
/// adds a fill and a ring on top.
struct LockFlash: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: PulseValue(), trigger: trigger) { view, value in
            view
                .scaleEffect(reduceMotion ? 1 : value.scale)
                .background {
                    Capsule().fill(Theme.feltGreen.color.opacity(0.55 * value.glow))
                }
                .overlay {
                    Capsule().stroke(Theme.easyText.color, lineWidth: 3)
                        .opacity(value.glow)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.08, duration: 0.16)
                CubicKeyframe(1.0, duration: 0.4)
            }
            KeyframeTrack(\.glow) {
                LinearKeyframe(1, duration: 0.12)
                LinearKeyframe(1, duration: 0.5)
                LinearKeyframe(0, duration: 0.5)
            }
        }
    }
}

extension View {
    func successPulse(_ trigger: Int, cornerRadius: CGFloat = HUDMetrics.cornerRadius) -> some View {
        modifier(SuccessPulse(trigger: trigger, cornerRadius: cornerRadius))
    }

    func lockFlash(_ trigger: Int) -> some View {
        modifier(LockFlash(trigger: trigger))
    }
}

// MARK: - Full-screen effects

/// Effects drawn on the screen over the camera, off the table's projected
/// footprint (ShotPresentation.footprint): the table outline flashing once
/// when it locks, and a ring at the pocket a ball just went into. Hit-test
/// free. The footprint exists only while a camera is projecting the table,
/// so in the Simulator, which has no camera, neither effect shows.
struct FeedbackEffectsLayer: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let quad = model.presentation.footprint?.quad, quad.count == 4 {
                TableOutline(quad: quad)
                    .keyframeAnimator(initialValue: 0.0, trigger: model.feedback.lockFlashCount) { view, opacity in
                        view.opacity(opacity)
                    } keyframes: { _ in
                        KeyframeTrack {
                            LinearKeyframe(1, duration: 0.15)
                            LinearKeyframe(1, duration: 0.45)
                            LinearKeyframe(0, duration: 0.6)
                        }
                    }
            }
            if let point = madePocketPoint {
                PocketRing(reduceMotion: reduceMotion)
                    .position(point)
                    .id(model.feedback.madePulseCount)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the last made ball's pocket is on the screen. Only when every
    /// pocket projected: a missing one would shift the index.
    private var madePocketPoint: CGPoint? {
        guard model.feedback.madePulseCount > 0,
              let id = model.feedback.lastMadePocket,
              let table = model.tableState?.table,
              let pockets = model.presentation.footprint?.pockets,
              pockets.count == table.pockets.count,
              let index = table.pockets.firstIndex(where: { $0.id == id }) else { return nil }
        return CGPoint(x: pockets[index].x, y: pockets[index].y)
    }
}

private struct TableOutline: View {
    let quad: [Vec2]

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: quad[0].x, y: quad[0].y))
            for point in quad.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
        }
        .stroke(Theme.easyText.color, style: StrokeStyle(lineWidth: 5, lineJoin: .round))
        .shadow(color: Theme.feltGreen.color, radius: 8)
    }
}

/// A ring that opens and fades where the ball went down. With Reduce Motion
/// it holds its size and only fades.
private struct PocketRing: View {
    let reduceMotion: Bool

    var body: some View {
        Circle()
            .stroke(Theme.easyText.color, lineWidth: 4)
            .frame(width: 44, height: 44)
            .keyframeAnimator(initialValue: PulseValue(scale: 0.6, glow: 0)) { view, value in
                view.scaleEffect(reduceMotion ? 1 : value.scale).opacity(value.glow)
            } keyframes: { _ in
                KeyframeTrack(\.scale) { CubicKeyframe(1.9, duration: 0.55) }
                KeyframeTrack(\.glow) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(0, duration: 0.5)
                }
            }
    }
}

// MARK: - Settings and More

/// Sounds, haptics and the scoreboard: the three player-facing switches of
/// the arcade layer. Voice guidance is its own section and is not touched.
struct FeedbackSettingsSection: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        Section {
            Toggle("Sounds", isOn: Binding(
                get: { model.settings.soundsEnabled },
                set: { on in
                    model.updateSettings { $0.soundsEnabled = on }
                    if on { model.previewFeedbackSound() }
                }))
                .accessibilityIdentifier("settings-sounds")
            Toggle("Haptics", isOn: Binding(
                get: { model.settings.hapticsEnabled },
                set: { on in model.updateSettings { $0.hapticsEnabled = on } }))
                .accessibilityIdentifier("settings-haptics")
            Toggle("Show scoreboard", isOn: Binding(
                get: { model.settings.showScoreboard },
                set: { on in model.updateSettings { $0.showScoreboard = on } }))
                .accessibilityIdentifier("settings-scoreboard")
        } header: {
            SheetHeader("Sounds and haptics")
        } footer: {
            SheetFootnote("""
                Short tones and taps when the table locks, when you pick a \
                shot, and when a ball goes down or a shot misses. Sounds \
                follow the ring switch, so silent mode silences them. The \
                scoreboard counts shots made out of shots tried since the \
                table was last locked.
                """)
        }
    }
}

/// The session's made / attempted count, in the More sheet. Shown only when
/// the player has turned the scoreboard on.
struct ScoreboardSection: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        if model.settings.showScoreboard {
            Section {
                LabeledContent("Shots made", value: model.feedback.score.chipText)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.feedback.score.spokenText)
                    .accessibilityIdentifier("more-score")
                LabeledContent("Best streak", value: "\(model.feedback.score.bestStreak)")
                Button("Reset score") { model.feedback.resetScore() }
                    .accessibilityIdentifier("more-score-reset")
            } header: {
                SheetHeader("This session")
            } footer: {
                SheetFootnote("Counted from the last time the table was locked.")
            }
        }
    }
}
