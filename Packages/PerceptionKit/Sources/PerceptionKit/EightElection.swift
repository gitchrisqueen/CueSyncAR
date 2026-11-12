//
//  EightElection.swift
//  PerceptionKit
//
//  Which ONE ball is the eight.
//
//  Measured on the owner's iPad over a full 16-ball layout on black cloth
//  in a dim room: five balls (the dark blue 2 and 10, the purple 4 and 12,
//  the maroon 7 and 15, the dark green 6 and 14 and the real 8) all read
//  as neutral and dark against the bright cue ball, and the app named every
//  one of them the eight. A threshold cannot fix that, because the
//  assumption behind it, that a dark ball is THE eight, is false on a full
//  table. So the eight is elected: among the balls that look dark and
//  neutral, the most neutral one wins, and the rest go back to their hue.
//
//  Two rules keep the answer still:
//  * Incumbency. The holder keeps the title while it still qualifies, so
//    the real eight rolling behind another ball (its looks simply stop
//    arriving) does not hand the name to a dark neighbour.
//  * A clear challenger. Another ball takes the title only by being much
//    more neutral than the holder, for several elections running. That
//    also repairs an early wrong pick made before the real eight had been
//    seen often enough to rank.
//

import CueSyncCore
import Foundation

struct EightElection: Sendable, Equatable {
    /// A ball that has been reading as dark and neutral.
    struct Candidate: Sendable, Equatable {
        var id: BallID
        /// Mean chroma of the ball, relative to the cue ball's brightness.
        var chroma: Double
        /// Mean brightness, relative to the cue ball's.
        var value: Double
    }

    private(set) var holder: BallID?
    private var challenger: BallID?
    private var challengerElections = 0

    /// Run one election.
    ///
    /// - Parameters:
    ///   - candidates: every ball whose committed colour is black.
    ///   - pinned: a ball the player corrected to the eight. It wins
    ///     outright and is never contested.
    ///   - chromaCeiling: a candidate more coloured than this is not
    ///     clearly neutral, so it is not a candidate. If none is left
    ///     nobody is the eight: no real eight is on the table.
    ///   - switchRatio: a challenger must be more neutral than the holder
    ///     by at least this factor (chroma below holder chroma times it).
    ///   - switchElections: and stay so for this many elections running.
    mutating func elect(candidates: [Candidate], pinned: BallID?, chromaCeiling: Double,
                        switchRatio: Double, switchElections: Int) {
        if let pinned {
            holder = pinned
            clearChallenger()
            return
        }
        let ranked = candidates.filter { $0.chroma <= chromaCeiling }.sorted(by: Self.ranksBefore)
        guard let best = ranked.first else {
            holder = nil
            clearChallenger()
            return
        }
        guard let current = holder, let held = ranked.first(where: { $0.id == current }) else {
            holder = best.id
            clearChallenger()
            return
        }
        guard best.id != current, best.chroma < held.chroma * switchRatio else {
            clearChallenger()
            return
        }
        challengerElections = challenger == best.id ? challengerElections + 1 : 1
        challenger = best.id
        if challengerElections >= switchElections {
            holder = best.id
            clearChallenger()
        }
    }

    mutating func reset() {
        holder = nil
        clearChallenger()
    }

    private mutating func clearChallenger() {
        challenger = nil
        challengerElections = 0
    }

    /// Lowest chroma first, then the darkest, then the lower id. Chroma is
    /// compared in hundredths so that two balls a hair apart fall through
    /// to darkness rather than being separated by noise, and the id makes
    /// the same inputs always elect the same ball.
    static func ranksBefore(_ a: Candidate, _ b: Candidate) -> Bool {
        let (chromaA, chromaB) = (Int((a.chroma * 100).rounded()), Int((b.chroma * 100).rounded()))
        if chromaA != chromaB { return chromaA < chromaB }
        let (valueA, valueB) = (Int((a.value * 100).rounded()), Int((b.value * 100).rounded()))
        if valueA != valueB { return valueA < valueB }
        return a.id.rawValue < b.id.rawValue
    }
}
