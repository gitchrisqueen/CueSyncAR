//
//  SessionScore.swift
//  CoachKit
//
//  The optional scoreboard: shots made out of shots attempted this session.
//  A value so the rules (a scratch is an attempt, a streak ends on a miss,
//  a new table lock starts over) are tested without a screen.
//

import Foundation

public struct SessionScore: Sendable, Equatable, Codable {
    public private(set) var made = 0
    public private(set) var attempted = 0
    /// Consecutive balls made, ended by a miss or a scratch.
    public private(set) var streak = 0
    public private(set) var bestStreak = 0

    public init() {}

    public mutating func record(_ outcome: ShotOutcome) {
        attempted += 1
        if outcome.isMade {
            made += 1
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
        }
    }

    public mutating func reset() {
        self = SessionScore()
    }

    /// The chip: "3 of 5".
    public var chipText: String { "\(made) of \(attempted)" }

    /// What VoiceOver reads for the chip.
    public var spokenText: String {
        attempted == 0
            ? "No shots yet this session"
            : "\(made) made out of \(attempted) shots this session"
    }

    // MARK: Persistence

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// A corrupt or missing blob is an empty score, never a throw.
    public static func decoded(from data: Data?) -> SessionScore {
        guard let data, let score = try? JSONDecoder().decode(SessionScore.self, from: data),
              score.made >= 0, score.attempted >= score.made, score.streak >= 0 else {
            return SessionScore()
        }
        return score
    }
}
