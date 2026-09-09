//
//  ShotCard.swift
//  CueSyncUI
//
//  The shot the app is offering: how likely it is to go, into which
//  pocket, and whether the player chose it or the app did.
//
//  Pure presentation. It takes numbers and strings, never a ShotRating —
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

#if canImport(SwiftUI)
import SwiftUI

/// A glass card carrying one shot: the percentage, the pocket, and who
/// picked it.
public struct ShotCard: View {
    /// 0...100, already rounded. Nil for a blocked shot, where a number
    /// would be worse than the reason.
    public let percentage: Int?
    /// Where the ball is going, spoken ("top-right corner").
    public let pocket: String?
    public let confidence: ShotConfidence
    /// True when the player tapped this ball rather than the app choosing.
    public let chosenByPlayer: Bool
    /// Shown instead of the percentage when the shot cannot be taken.
    public let blockedReason: String?
    /// Which balls are in play ("Solids"), or nil to leave it off.
    public let group: String?
    /// Which way to move to get on this shot ("Aim a little left"), when
    /// the player is aiming at all. The actionable line, so it carries the
    /// tint rather than the grey.
    public let aimAdvice: String?

    public init(percentage: Int?, pocket: String?, confidence: ShotConfidence,
                chosenByPlayer: Bool, blockedReason: String? = nil,
                group: String? = nil, aimAdvice: String? = nil) {
        self.aimAdvice = aimAdvice
        self.percentage = percentage
        self.pocket = pocket
        self.confidence = confidence
        self.chosenByPlayer = chosenByPlayer
        self.blockedReason = blockedReason
        self.group = group
    }

    private var tint: Color { confidence.token.color }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let percentage, blockedReason == nil {
                    Text("\(percentage)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "nosign")
                        .font(.title2.weight(.semibold))
                }
                Spacer(minLength: 8)
                if let group {
                    Text(group.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(tint)

            if let blockedReason {
                Text(blockedReason)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let pocket {
                Text(pocket)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }

            if let aimAdvice, blockedReason == nil {
                Text(aimAdvice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            // Never let a suggestion look like the player's own decision.
            Text(chosenByPlayer ? "Your pick — tap again to release"
                                : "Best shot — tap any ball to override")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 210, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(chosenByPlayer ? 0.9 : 0.35),
                        lineWidth: chosenByPlayer ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    var accessibilityText: String {
        if let blockedReason { return blockedReason }
        let who = chosenByPlayer ? "Your pick" : "Suggested shot"
        guard let percentage, let pocket else { return who }
        let shot = "\(who): \(percentage) per cent into the \(pocket), \(confidence.word)"
        guard let aimAdvice else { return shot }
        return shot + ". " + aimAdvice
    }
}

#Preview("Shot card") {
    VStack(alignment: .leading, spacing: 12) {
        ShotCard(percentage: 91, pocket: "top-right corner", confidence: .easy,
                 chosenByPlayer: false, group: "Solids")
        ShotCard(percentage: 54, pocket: "bottom side", confidence: .medium,
                 chosenByPlayer: true, group: "Stripes")
        ShotCard(percentage: nil, pocket: nil, confidence: .blocked, chosenByPlayer: true,
                 blockedReason: "Blocked — a ball is in the cue ball's way", group: "Solids")
    }
    .padding()
}
#endif
