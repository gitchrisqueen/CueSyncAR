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
        case .hard, .longShot, .blocked: Theme.warnCoral
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
        case .hard, .longShot, .blocked: Theme.hardText
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

    public var text: String {
        switch self {
        case .noCleanShot: "No clean shot — try a safety"
        case .breakRack: "Break the rack"
        }
    }

    public var systemImage: String {
        switch self {
        case .noCleanShot: "shield.lefthalf.filled"
        case .breakRack: "triangle.fill"
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// A glass card carrying one shot: the ball and pocket in the player's
/// words, how hard it is, and who picked it.
public struct ShotCard: View {
    /// What the ball is called: "Blue ball". Nil only when nothing is known.
    public let ball: String?
    /// Where the ball is going, as seen from where the player stands
    /// ("right side pocket"). Nil while the view of the table is unknown:
    /// no pocket beats a pocket named from the wrong side.
    public let pocket: String?
    public let confidence: ShotConfidence
    /// True when the player tapped this ball rather than the app choosing.
    public let chosenByPlayer: Bool
    /// Shown instead of the call when the shot cannot be taken.
    public let blockedReason: String?
    /// Which balls are in play ("Solids"), or nil to leave it off.
    public let group: String?
    /// Which way to move to get on this shot ("Aim a little left"), when
    /// the player is aiming at all. The actionable line, so it carries the
    /// tint rather than the grey.
    public let aimAdvice: String?

    public init(ball: String?, pocket: String?, confidence: ShotConfidence,
                chosenByPlayer: Bool, blockedReason: String? = nil,
                group: String? = nil, aimAdvice: String? = nil) {
        self.aimAdvice = aimAdvice
        self.ball = ball
        self.pocket = pocket
        self.confidence = confidence
        self.chosenByPlayer = chosenByPlayer
        self.blockedReason = blockedReason
        self.group = group
    }

    private var tint: Color { confidence.token.color }
    private var textTint: Color { confidence.textToken.color }

    /// "Blue ball → right side pocket". The same shape CoachKit's
    /// `ShotCall.line` has; kept as plain strings here so this package
    /// does not depend on the coach.
    var callLine: String? {
        switch (ball, pocket) {
        case let (ball?, pocket?): "\(ball) → \(pocket)"
        case let (ball?, nil): ball
        case let (nil, pocket?): pocket
        case (nil, nil): nil
        }
    }

    /// The hint under the call. A suggestion must never look like the
    /// player's own decision, and one that is not good should not claim to
    /// be the best.
    var hint: String {
        if chosenByPlayer { return "Your pick — tap again to release" }
        switch confidence {
        case .easy, .medium: return "Best shot — tap a ball to pick another"
        default: return "Best available — tap a ball to pick another"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                tierChip
                Spacer(minLength: 8)
                if let group {
                    Text(group.uppercased())
                        .hudFont(.caption, weight: .bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(Theme.hudTextSecondary.color.opacity(0.6), lineWidth: 1))
                        .foregroundStyle(Theme.hudTextSecondary.color)
                }
            }

            if let blockedReason {
                Text(blockedReason)
                    .hudFont(.body, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let callLine {
                Text(callLine)
                    .hudFont(.headline, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let aimAdvice, blockedReason == nil {
                Text(aimAdvice)
                    .hudFont(.caption, weight: .semibold)
                    .foregroundStyle(textTint)
            }

            Text(hint)
                .hudFont(.caption)
                .foregroundStyle(Theme.hudTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hudCardWidth()
        .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous)
                .stroke(tint.opacity(chosenByPlayer ? 1 : 0.6),
                        lineWidth: chosenByPlayer ? 3 : 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("shot-card")
    }

    /// The tier as an icon AND a word: colour is the third signal, not
    /// the only one.
    private var tierChip: some View {
        HStack(spacing: 6) {
            Image(systemName: confidence.tierSymbol)
                .imageScale(.small)
            Text(confidence.tierWord.uppercased())
                .hudFont(.body, weight: .heavy)
        }
        .foregroundStyle(textTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .overlay(Capsule().stroke(tint, lineWidth: 2))
    }

    var accessibilityText: String {
        if let blockedReason { return blockedReason }
        let who = chosenByPlayer ? "Your pick" : "Suggested shot"
        let tier = confidence.tierWord.lowercased()
        var shot = "\(who), \(tier)"
        if let ball {
            var call = ball
            if let pocket { call += " into the " + pocket }
            shot = "\(who): \(call), \(tier)"
        }
        guard let aimAdvice else { return shot }
        return shot + ". " + aimAdvice
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .hudPlate(Capsule())
            .overlay(Capsule().stroke(Theme.cueAmber.color.opacity(0.7), lineWidth: 2))
            .accessibilityIdentifier("shot-empty")
    }
}

#Preview("Shot card") {
    VStack(alignment: .leading, spacing: 12) {
        ShotCard(ball: "Red ball", pocket: "far-left corner", confidence: .easy,
                 chosenByPlayer: false, group: "Solids")
        ShotCard(ball: "Blue ball", pocket: "right side pocket", confidence: .medium,
                 chosenByPlayer: true, group: "Stripes", aimAdvice: "Aim a little left")
        ShotCard(ball: "8-ball", pocket: "near-right corner", confidence: .hard,
                 chosenByPlayer: false)
        ShotCard(ball: nil, pocket: nil, confidence: .blocked, chosenByPlayer: true,
                 blockedReason: "Blocked — a ball is in the cue ball's way", group: "Solids")
        ShotEmptyCapsule(state: .noCleanShot)
        ShotEmptyCapsule(state: .breakRack)
    }
    .padding()
    .background(Color.green.opacity(0.4))
}
#endif
