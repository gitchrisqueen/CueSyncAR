//
//  Payoff.swift
//  CueSyncUI
//
//  A made shot, a miss and a scratch are EVENTS, not statuses. They used to
//  be small pills under the shot card, the same size as "Tracking 5 balls",
//  stacked with the score chip and the ball count. Now each takes the shot
//  card's own slot for about a second, in large type, and the card comes
//  back. Nothing stacks under the card.
//
//  The words, the timing and the Reduce Motion rule are plain values here so
//  a test holds them; the view is a few lines under it.
//

import Foundation

public struct PayoffEvent: Equatable, Sendable, Identifiable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The advised ball went into the advised pocket.
        case made
        /// Some other ball went down.
        case madeOther
        case missed
        /// The cue ball went down.
        case scratch
    }

    public enum Tone: Sendable, Equatable { case good, caution, bad }

    public let id: Int
    public let kind: Kind
    /// The run after this shot, 0 when it ended one.
    public let streak: Int
    public let made: Int
    public let attempted: Int

    public init(id: Int, kind: Kind, streak: Int = 0, made: Int = 0, attempted: Int = 0) {
        self.id = id
        self.kind = kind
        self.streak = streak
        self.made = made
        self.attempted = attempted
    }

    /// The big words: "MADE IT".
    public var headline: String {
        switch kind {
        case .made: "MADE IT"
        case .madeOther: "BALL DOWN"
        case .missed: "MISSED"
        case .scratch: "SCRATCH"
        }
    }

    /// The second line: "+1 · 3 IN A ROW", "Line it up again".
    public var detail: String? {
        switch kind {
        case .made, .madeOther:
            streak >= 2 ? "+1 · \(streak) IN A ROW" : "+1"
        case .missed:
            "Line it up again"
        case .scratch:
            "Cue ball down"
        }
    }

    /// Green for a make, amber for a miss, red for a scratch. The word and
    /// the symbol say the same thing, so colour is never the only signal.
    public var tone: Tone {
        switch kind {
        case .made, .madeOther: .good
        case .missed: .caution
        case .scratch: .bad
        }
    }

    public var symbol: String {
        switch kind {
        case .made, .madeOther: "checkmark.circle.fill"
        case .missed: "arrow.uturn.left.circle"
        case .scratch: "exclamationmark.circle.fill"
        }
    }

    /// A make is large; a miss and a scratch use the same slot, smaller.
    public var isCelebration: Bool { kind == .made || kind == .madeOther }

    /// What VoiceOver reads.
    public var spokenText: String {
        [headline.capitalized, detail].compactMap { $0 }.joined(separator: ". ")
    }
}

public enum PayoffTiming {
    /// How long the event holds the card's slot, in seconds: "about 1.2".
    public static func holdSeconds(for kind: PayoffEvent.Kind) -> Double {
        switch kind {
        case .made, .madeOther: 1.2
        case .missed, .scratch: 1.2
        }
    }

    /// The fade in and out, in seconds. Shorter with Reduce Motion.
    public static func fadeSeconds(reduceMotion: Bool) -> Double {
        reduceMotion ? 0.1 : 0.2
    }

    /// Whether the card swells as it appears. Never with Reduce Motion:
    /// opacity only.
    public static func scalesIn(reduceMotion: Bool) -> Bool { !reduceMotion }
}

#if canImport(SwiftUI)
import SwiftUI

/// The payoff in the shot card's slot: same width, same place.
public struct PayoffCard: View {
    public let event: PayoffEvent

    public init(event: PayoffEvent) {
        self.event = event
    }

    private var tint: ColorToken {
        switch event.tone {
        case .good: Theme.easyText
        case .caution: Theme.fairText
        case .bad: Theme.hardText
        }
    }

    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: event.symbol)
                .hudFont(event.isCelebration ? .payoff : .payoffDetail, weight: .bold)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.headline)
                    .hudFont(event.isCelebration ? .payoff : .payoffDetail, weight: .heavy)
                if let detail = event.detail {
                    Text(detail)
                        .hudFont(event.isCelebration ? .payoffDetail : .body, weight: .bold)
                        .foregroundStyle(Theme.hudText.color)
                }
            }
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint.color)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .hudCardWidth()
        .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous)
            .stroke(tint.color, lineWidth: 3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.spokenText)
        .accessibilityIdentifier("payoff-card")
    }
}
#endif
