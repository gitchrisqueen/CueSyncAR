//
//  ShotCard.swift
//  CueSyncUI
//
//  The shot the app is offering: which ball, into which pocket (as the
//  player sees the table), how hard it is as a word, and whether the
//  player chose it or the app did.
//
//  There is deliberately no percentage here. The one the ranking computes
//  swung from 73 to 100 on a table where nothing moved (calibration drift)
//  and is not a make probability a player could check, so the card shows a
//  tier: Easy, Fair or Hard. The number stays in the debug mirror.
//
//  Pure presentation. It takes strings, never a ShotRating —
//  CueSyncUI depends on CueSyncCore alone, and the ranking lives in
//  CoachKit. That keeps the design system testable without the coach.
//

import CueSyncCore
import Foundation

/// How a shot reads at a glance. Mirrors CoachKit's difficulty bands
/// without depending on them.
public enum ShotConfidence: String, Sendable, Equatable, CaseIterable {
    case easy
    case medium
    case hard
    case longShot
    case blocked

    /// Which token carries it. Green for a shot that should go, amber for
    /// one that needs care, coral for one that probably will not — the
    /// same three colours the rest of the HUD already uses.
    public var token: ColorToken {
        switch self {
        case .easy: Theme.feltGreen
        case .medium: Theme.cueAmber
        // Orange: a hard shot is playable, so it is not the red of a block.
        case .hard, .longShot: Theme.hardTier
        case .blocked: Theme.warnCoral
        }
    }

    /// The word the card shows. Three tiers plus blocked: the five bands
    /// are an implementation detail, and "long shot" is just "Hard" to
    /// someone standing at the table.
    public var tierWord: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Fair"
        case .hard, .longShot: "Hard"
        case .blocked: "Blocked"
        }
    }

    /// A SHAPE for the tier, so meaning is never carried by colour alone:
    /// a circle, a diamond, a triangle, a barred circle. SF Symbol names.
    public var tierSymbol: String {
        switch self {
        case .easy: "circle.fill"
        case .medium: "diamond.fill"
        case .hard, .longShot: "triangle.fill"
        case .blocked: "nosign"
        }
    }

    /// The text-grade tint: the same hue as `token`, bright enough to read
    /// on the HUD plate (the table tokens are not; see Theme).
    public var textToken: ColorToken {
        switch self {
        case .easy: Theme.easyText
        case .medium: Theme.fairText
        case .hard, .longShot: Theme.hardTierText
        case .blocked: Theme.hardText
        }
    }

    /// Word for the band, for accessibility and for spoken guidance.
    public var word: String {
        switch self {
        case .easy: "good"
        case .medium: "makeable"
        case .hard: "hard"
        case .longShot: "long shot"
        case .blocked: "blocked"
        }
    }
}

/// Why there is no shot card: a small capsule instead of nothing, so an
/// empty table of advice cannot be mistaken for a broken app.
public enum ShotEmptyState: Sendable, Equatable {
    /// Balls on the table, none of them can be potted cleanly.
    case noCleanShot
    /// A full rack: nothing to rank, but a break to play.
    case breakRack
    /// A pocket is called and no ball can go into it cleanly. The card is
    /// about the called pocket only, so it says so rather than showing a
    /// shot into a different pocket. `pocket` is in the player's words
    /// ("far-left corner").
    case noShotToCalledPocket(pocket: String)

    public var text: String {
        switch self {
        case .noCleanShot: "No clean shot — try a safety"
        case .breakRack: "Break the rack"
        case .noShotToCalledPocket(let pocket): "No clean shot into the \(pocket) — call another pocket"
        }
    }

    public var systemImage: String {
        switch self {
        case .noCleanShot: "shield.lefthalf.filled"
        case .breakRack: "triangle.fill"
        case .noShotToCalledPocket: "scope"
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A glass card carrying one shot: the tier as a word, the ball and the
/// pocket as one big line, who picked it, and (when the advice is not
/// centre ball) the cue-ball guide tile.
///
/// It is always the same width (`HUDMetrics.cardWidth*`, or the screen's
/// less its gutters) and the app always puts it in the same place, so it
/// does not move or resize from one shot to the next.
public struct ShotCard: View {
    /// What the ball is called: "Blue ball". Nil only when nothing is known.
    public let ball: String?
    /// The ball as the headline leads with it, number first when known
    /// ("7 Maroon"). Falls back to `ball`.
    public let leadBall: String?
    /// Where the ball is going, as seen from where the player stands
    /// ("right side pocket"). Nil while the view of the table is unknown:
    /// no pocket beats a pocket named from the wrong side.
    public let pocket: String?
    public let confidence: ShotConfidence
    /// True when the player tapped this ball rather than the app choosing.
    public let chosenByPlayer: Bool
    /// Shown instead of the call when the shot cannot be taken.
    public let blockedReason: String?
    /// Which way to move to get on this shot ("Aim a little left"), when
    /// the player is aiming at all. The actionable line, so it carries the
    /// tint rather than the grey.
    public let aimAdvice: String?
    /// How `aimAdvice` is coloured: green when on line, amber when off
    /// line, plain white for a nudge. Never the tier's colour: the guide
    /// subtitle is about the aim, not the difficulty.
    public let aimTone: AimLine.Tone
    /// True when a pocket is called: the card is then about that pocket
    /// only (the headline names it, the aim line is about it) and the tier
    /// row says "Called" instead of "Best shot".
    public let isCalled: Bool
    /// The score, folded into the card's first row ("2 of 5") instead of a
    /// chip stacked under it. Nil when the scoreboard is off.
    public let scoreText: String?
    /// Where on the cue ball to strike. The tile is drawn only when this
    /// is not a centre hit.
    public let tipOffset: Vec2?

    public init(ball: String?, leadBall: String? = nil, pocket: String?, confidence: ShotConfidence,
                chosenByPlayer: Bool, blockedReason: String? = nil,
                aimAdvice: String? = nil, aimTone: AimLine.Tone = .neutral,
                isCalled: Bool = false, scoreText: String? = nil, tipOffset: Vec2? = nil) {
        self.aimAdvice = aimAdvice
        self.aimTone = aimTone
        self.isCalled = isCalled
        self.scoreText = scoreText
        self.ball = ball
        self.leadBall = leadBall
        self.pocket = pocket
        self.confidence = confidence
        self.chosenByPlayer = chosenByPlayer
        self.blockedReason = blockedReason
        self.tipOffset = tipOffset
    }

    private var tint: Color { confidence.token.color }
    private var textTint: Color { confidence.textToken.color }

    /// "Blue ball → right side pocket". The same shape CoachKit's
    /// `ShotCall.line` has; kept as plain strings here so this package
    /// does not depend on the coach. Used for the mirror and VoiceOver;
    /// the card itself shows `headline`.
    var callLine: String? {
        switch (ball, pocket) {
        case let (ball?, pocket?): "\(ball) → \(pocket)"
        case let (ball?, nil): ball
        case let (nil, pocket?): pocket
        case (nil, nil): nil
        }
    }

    /// The card's big line: "BLUE → RIGHT SIDE". See `HUDCopy.headline`.
    var headline: String? { HUDCopy.headline(ball: leadBall ?? ball, pocket: pocket) }

    /// The hint under the call. A suggestion must never look like the
    /// player's own decision, and one that is not good should not claim to
    /// be the best.
    var hint: String {
        if chosenByPlayer { return "Your pick — tap again to go back to the suggested shot" }
        switch confidence {
        case .easy, .medium: return "Best shot — tap a ball to pick another"
        default: return "Best available — tap a ball to pick another"
        }
    }

    /// The line under the call when the player picked the ball. The tier
    /// row already says "Your pick", so this only says what a second tap
    /// does ("release" read as a stroke, not as "undo my pick").
    var releaseHint: String { "Tap it again to go back to the suggested shot" }

    /// The card's third and last row: why it is blocked, else the aim, else
    /// (for a pick the player made) what a second tap does. Never more than
    /// three rows in any state, so the card cannot grow down over the far
    /// rail and pockets.
    var thirdRow: String? {
        blockedReason ?? aimAdvice ?? (chosenByPlayer ? releaseHint : nil)
    }

    /// Rows the card draws: the tier row, the call, and the third row if any.
    var rowCount: Int { 2 + (thirdRow == nil ? 0 : 1) }

    /// The tint of the aim line.
    private var aimColor: Color {
        switch aimTone {
        case .good: Theme.easyText.color
        case .caution: Theme.fairText.color
        case .neutral: Theme.hudText.color
        }
    }

    /// Who chose this, in two words, beside the tier chip.
    var provenance: String {
        // A blocked pick: the one thing to know is how to get out of it.
        if blockedReason != nil { return "Tap again to go back" }
        if isCalled { return "Called" }
        if chosenByPlayer { return "Your pick" }
        switch confidence {
        case .easy, .medium: return "Best shot"
        default: return "Best available"
        }
    }

    private var showsGuide: Bool {
        guard blockedReason == nil, let tipOffset else { return false }
        return HUDCopy.guideWord(tipOffset: tipOffset) != nil
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize

    /// On a phone at a large text size the column beside the tile is too
    /// narrow for the call (the tier word broke into "HA / RD" and the
    /// pocket was cut off), so the tile moves under the text instead.
    private var guideGoesBelow: Bool {
        showsGuide && sizeClass != .regular && typeSize >= .xLarge
    }

    public var body: some View {
        Group {
            if guideGoesBelow, let tipOffset {
                VStack(alignment: .trailing, spacing: 8) {
                    details
                    CueBallGuideView(tipOffset: tipOffset)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    details
                    if showsGuide, let tipOffset {
                        CueBallGuideView(tipOffset: tipOffset)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .hudCardWidth()
        .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous)
                .stroke(tint.opacity(chosenByPlayer ? 1 : 0.6),
                        lineWidth: chosenByPlayer ? 3 : 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(chosenByPlayer ? "Tap the ball again to go back to the suggested shot"
                                          : "Tap a ball to pick another")
        .accessibilityIdentifier("shot-card")
    }

    /// The text column, three rows at most: tier (with who chose it and the
    /// score), the call, and one line more.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                tierChip
                // Wraps instead of truncating ("Best availa…") when the
                // guide tile leaves the column narrow.
                Text(provenance)
                    .hudFont(.body, weight: .semibold)
                    .foregroundStyle(Theme.hudTextSecondary.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let scoreText {
                    Label(scoreText, systemImage: "target")
                        .hudFont(.body, weight: .semibold)
                        .foregroundStyle(Theme.hudTextSecondary.color)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            if let headline {
                // One line at the default text size; wraps rather than
                // clips when Dynamic Type or a narrow phone needs it. A
                // blocked card names the ball (no pocket).
                Text(HUDCopy.keepingWordsWhole(headline))
                    .hudFont(.headline, weight: .heavy)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let thirdRow {
                Text(thirdRow)
                    .hudFont(.body, weight: .semibold)
                    .foregroundStyle(thirdRowColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thirdRowColor: Color {
        if blockedReason != nil { return Theme.hudText.color }
        if aimAdvice != nil { return aimColor }
        return Theme.hudTextSecondary.color
    }

    /// The tier as an icon AND a word: colour is the third signal, not
    /// the only one.
    private var tierChip: some View {
        HStack(spacing: 8) {
            Image(systemName: confidence.tierSymbol)
                .imageScale(.small)
            Text(confidence.tierWord.uppercased())
                .hudFont(.tier, weight: .heavy)
        }
        .foregroundStyle(textTint)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .overlay(Capsule().stroke(tint, lineWidth: 2))
        // The tier word is never allowed to break ("HA / RD").
        .fixedSize()
    }

    var accessibilityText: String {
        if let blockedReason {
            guard let ball else { return blockedReason }
            return "\(ball): \(blockedReason)"
        }
        let who = isCalled ? "Called shot" : (chosenByPlayer ? "Your pick" : "Suggested shot")
        let tier = confidence.tierWord.lowercased()
        var shot = "\(who), \(tier)"
        if let ball {
            var call = ball
            if let pocket { call += " into the " + pocket }
            shot = "\(who): \(call), \(tier)"
        }
        if let aimAdvice { shot += ". " + aimAdvice }
        if let scoreText { shot += ". Score \(scoreText)" }
        return shot
    }
}

/// The cue-ball guide on its own, for when the player is aiming but no
/// shot is on offer: the same slot, the same width as the shot card.
public struct CueBallGuideCard: View {
    public let tipOffset: Vec2
    public let headline: String

    public init(tipOffset: Vec2, headline: String) {
        self.tipOffset = tipOffset
        self.headline = headline
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(headline)
                .hudFont(.body, weight: .semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            CueBallGuideView(tipOffset: tipOffset)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .hudCardWidth()
        .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
    }
}

public struct ShotEmptyCapsule: View {
    public let state: ShotEmptyState

    public init(state: ShotEmptyState) {
        self.state = state
    }

    public var body: some View {
        Label(state.text, systemImage: state.systemImage)
            .hudFont(.body, weight: .semibold)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .hudCardWidth()
            .fixedSize(horizontal: false, vertical: true)
            .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous)
                .stroke(Theme.cueAmber.color.opacity(0.7), lineWidth: 2))
            .accessibilityIdentifier("shot-empty")
    }
}

#Preview("Shot card") {
    VStack(spacing: 12) {
        ShotCard(ball: "Orange ball", pocket: "near-left corner", confidence: .easy,
                 chosenByPlayer: false)
        ShotCard(ball: "Blue ball", pocket: "right side pocket", confidence: .medium,
                 chosenByPlayer: true, aimAdvice: "Aim a little left",
                 tipOffset: Vec2(0, -0.6))
        ShotCard(ball: "8-ball", pocket: "near-right corner", confidence: .hard,
                 chosenByPlayer: false)
        ShotCard(ball: nil, pocket: nil, confidence: .blocked, chosenByPlayer: true,
                 blockedReason: "Blocked — a ball is in the cue ball's way")
        ShotEmptyCapsule(state: .noCleanShot)
        ShotEmptyCapsule(state: .breakRack)
    }
    .padding()
    .background(Color.green.opacity(0.4))
}
#endif
