//
//  BallIdentity.swift
//  PerceptionKit
//
//  Naming a tracked ball from many looks at it, rather than one.
//
//  A stripe is found by HUE SPREAD: a solid ball is one pigment and hue
//  survives shading, so its lit pixels agree, while a stripe has two
//  materials and they do not. Measured over 14 frames of the owner's
//  table, interquartile hue spread ran 1.8-9.0 degrees for the two
//  solids and 26.9-35.5 for the two stripes, with nothing in between.
//
//  Whiteness was tried first and does not work on these balls. Measured
//  on Sessions/device-20260909T014006Z, white fraction by ball: eight
//  0.18, cue 0.15-0.19, solid blue 0.08-0.12, stripe red 0.05, stripe
//  purple 0.03 — both stripes scoring BELOW both solids. The bands are
//  plainly visible in the frames; they are simply a warm cream rather
//  than a neutral white, so a neutrality test cannot see them. The test
//  is kept as a second route because it costs nothing and does fire on
//  balls whose bands really are white.
//
//  Both signals are one-directional, which is why the group is decided
//  on the MAXIMUM ever seen for a track rather than the mean: a stripe
//  presenting its solid pole is indistinguishable from a solid, so one
//  clear look is proof of a stripe while never seeing one proves
//  nothing. Balls rotate as they roll, so the evidence arrives on its
//  own.
//
//  The colour is decided the opposite way — by vote — because every look
//  sees the same colour and disagreement there is noise.
//

import CueSyncCore
import Foundation

public struct BallIdentity: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Observations kept per track.
        public var window: Int
        /// White fraction above which a ball has shown a band. Kept as
        /// a second route to the same conclusion: on balls whose bands
        /// really are white it fires, and it costs nothing when they are
        /// not. It is not the primary signal - see `stripeHueSpread`.
        public var stripeWhiteFraction: Double
        /// Interquartile hue spread, in degrees, above which a ball has
        /// shown two materials and is therefore a stripe.
        ///
        /// Measured over 14 frames of the owner's table: solids spanned
        /// 1.8-9.0 degrees and stripes 26.9-35.5, with nothing between.
        /// The default sits about a factor of three from either side,
        /// which is where a threshold should sit when the gap is that
        /// wide and the sample is that small (four balls, one table, one
        /// light).
        public var stripeHueSpread: Double
        /// Confidence a colour vote must reach before the ball is named.
        public var namingConfidence: Double
        /// Looks needed before a group is claimed at all.
        public var minimumObservations: Int
        /// Consecutive looks a different colour must LEAD the vote before
        /// a ball already named is renamed. Without it the name follows
        /// the vote's leader frame to frame, and a ball sitting between
        /// two colours (red and maroon, which no single-frame rule here
        /// separates) flips its label, and the eight with it, every time
        /// the tally crosses. The first name is not held back: it commits
        /// as soon as `minimumObservations` looks exist.
        public var switchObservations: Int
        /// Only ONE ball is the eight. Of the balls reading dark and
        /// neutral, the most neutral wins, and only if its mean chroma
        /// (relative to the cue ball, see `BallAppearance.relativeColour`)
        /// is at or under this; with none that clear, nobody is the eight.
        ///
        /// Measured eights: 0.020-0.079 (research 2026-11-10); the
        /// per-look black ceiling is 0.15. This sits just over the top of
        /// the eights, between the two. A starting point: the owner tunes
        /// it from the `relChroma` published per ball in /state.json.
        public var eightChromaCeiling: Double
        /// A ball already holding the eight is displaced only by one whose
        /// chroma is below the holder's times this, for
        /// `switchObservations` elections running. 0.6 means "clearly more
        /// neutral", not merely marginally.
        public var eightSwitchRatio: Double

        public init(window: Int = 40,
                    stripeWhiteFraction: Double = 0.30,
                    stripeHueSpread: Double = 16,
                    namingConfidence: Double = 0.5,
                    minimumObservations: Int = 5,
                    switchObservations: Int = 5,
                    eightChromaCeiling: Double = 0.10,
                    eightSwitchRatio: Double = 0.6) {
            self.window = window
            self.stripeWhiteFraction = stripeWhiteFraction
            self.stripeHueSpread = stripeHueSpread
            self.namingConfidence = namingConfidence
            self.minimumObservations = minimumObservations
            self.switchObservations = switchObservations
            self.eightChromaCeiling = eightChromaCeiling
            self.eightSwitchRatio = eightSwitchRatio
        }

        public static let `default` = Config()
    }

    /// What is known about one tracked ball.
    public struct Record: Sendable, Equatable {
        public var observations: [AppearanceObservation] = []
        /// Set by the player tapping to correct the app. Wins over
        /// everything and never decays: the classifier will be wrong
        /// sometimes, and a correction that gets voted away is worse than
        /// no correction at all.
        public var override: Ball.Kind?
        /// The colour this ball is currently named. Set when the first
        /// vote is possible and changed only by `switchObservations`
        /// consecutive looks in which another colour leads the vote.
        public internal(set) var committedFamily: ColorFamily?
        /// The colour that has been leading against `committedFamily`,
        /// and for how many consecutive looks.
        var challenger: ColorFamily?
        var challengerLooks = 0

        /// The chromatic colour this ball is named when it is NOT the
        /// eight, held by the same rule as `committedFamily`. Only
        /// meaningful for a ball whose raw vote is black.
        public internal(set) var committedFallback: ColorFamily?
        var fallbackChallenger: ColorFamily?
        var fallbackChallengerLooks = 0

        /// Mean over the kept looks of what each one measured. Nil when no
        /// look carried the number (observations built without it).
        public var meanRGB: Vec3? {
            let all = observations.compactMap(\.meanRGB)
            guard !all.isEmpty else { return nil }
            return all.reduce(Vec3(0, 0, 0), +) / Double(all.count)
        }

        /// Rec. 601 luma of `meanRGB`, matching the camera's own YCbCr.
        public var meanLuma: Double? {
            meanRGB.map { 0.299 * $0.x + 0.587 * $0.y + 0.114 * $0.z }
        }

        public var meanRelativeChroma: Double? { Self.mean(observations.compactMap(\.relativeChroma)) }
        public var meanRelativeValue: Double? { Self.mean(observations.compactMap(\.relativeValue)) }

        private static func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        /// Highest white fraction ever seen. One clear look at a band is
        /// the evidence; averaging it away is the mistake.
        public var peakWhiteFraction: Double {
            observations.map(\.whiteFraction).max() ?? 0
        }

        /// Widest hue spread ever seen, for the same reason: a stripe
        /// presenting its solid pole is indistinguishable from a solid,
        /// so the evidence is the best look, not the typical one.
        public var peakHueSpread: Double? {
            observations.compactMap(\.hueSpread).max()
        }
    }

    public var config: Config
    private var records: [BallID: Record] = [:]
    private var eightElection = EightElection()

    /// The one ball currently named the eight, if any.
    public var eightHolder: BallID? { eightElection.holder }

    public init(config: Config = .default) {
        self.config = config
    }

    public func record(for id: BallID) -> Record? { records[id] }
    public var trackedCount: Int { records.count }

    // MARK: - Accumulating

    public mutating func observe(_ observation: AppearanceObservation, for id: BallID) {
        record(observation, for: id)
        electEight()
    }

    private mutating func record(_ observation: AppearanceObservation, for id: BallID) {
        var record = records[id] ?? Record()
        record.observations.append(observation)
        if record.observations.count > config.window {
            record.observations.removeFirst(record.observations.count - config.window)
        }
        commit(&record)
        records[id] = record
    }

    /// Advance the ball's committed colour, and its fallback colour, by
    /// one look.
    private func commit(_ record: inout Record) {
        guard record.observations.count >= config.minimumObservations else { return }
        if let leader = Self.tally(record.observations)?.leader {
            Self.advance(&record.committedFamily, challenger: &record.challenger,
                         looks: &record.challengerLooks, towards: leader,
                         after: config.switchObservations)
        }
        if let leader = Self.tally(fallbackLooks: record.observations)?.leader {
            Self.advance(&record.committedFallback, challenger: &record.fallbackChallenger,
                         looks: &record.fallbackChallengerLooks, towards: leader,
                         after: config.switchObservations)
        }
    }

    /// The hold: the first name commits at once, a change of name only
    /// after `after` consecutive looks in which another colour leads.
    private static func advance(_ committed: inout ColorFamily?, challenger: inout ColorFamily?,
                                looks: inout Int, towards leader: ColorFamily, after: Int) {
        guard let current = committed else {
            committed = leader
            return
        }
        if leader == current {
            challenger = nil
            looks = 0
            return
        }
        looks = leader == challenger ? looks + 1 : 1
        challenger = leader
        if looks >= after {
            committed = leader
            challenger = nil
            looks = 0
        }
    }

    /// Take a whole frame's readings at once. One election per frame, so
    /// "elections running" counts frames and not balls.
    public mutating func observe(_ observations: [BallID: AppearanceObservation]) {
        for id in observations.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let observation = observations[id] { record(observation, for: id) }
        }
        electEight()
    }

    /// The player's correction, pinned to the track for the session.
    public mutating func setOverride(_ kind: Ball.Kind?, for id: BallID) {
        var record = records[id] ?? Record()
        record.override = kind
        records[id] = record
        electEight()
    }

    /// Forget tracks that no longer exist, so ids reused by a restarted
    /// tracker do not inherit a previous ball's colour.
    public mutating func retain(_ live: Set<BallID>) {
        records = records.filter { live.contains($0.key) }
        electEight()
    }

    public mutating func clear() {
        records = [:]
        eightElection.reset()
    }

    /// Re-run the eight's election over the current records.
    private mutating func electEight() {
        let pinned = records.filter { $0.value.override == .eight }.keys
            .min { $0.rawValue < $1.rawValue }
        let candidates: [EightElection.Candidate] = records.compactMap { id, record in
            guard record.override == nil,
                  record.observations.count >= config.minimumObservations,
                  record.committedFamily == .black else { return nil }
            // Looks built without the measurement (older callers) count as
            // perfectly neutral, which is how they were treated before.
            return EightElection.Candidate(id: id, chroma: record.meanRelativeChroma ?? 0,
                                           value: record.meanRelativeValue ?? 0)
        }
        eightElection.elect(candidates: candidates, pinned: pinned,
                            chromaCeiling: config.eightChromaCeiling,
                            switchRatio: config.eightSwitchRatio,
                            switchElections: config.switchObservations)
    }

    // MARK: - Deciding

    /// The winning colour and how strongly it won, or nil while there is
    /// not enough to say.
    ///
    /// The confidence is the vote share TIMES how sure the winning looks
    /// individually were, and it has to be both. Vote share alone says
    /// only that the looks agreed with each other — twenty looks that
    /// each scored 0.12 agree perfectly and produce a vote share of 1.0.
    /// Measured on the owner's table, that is exactly what the orange
    /// solid and the red stripe do: the warm colours sit inside each
    /// other's tolerance, every frame reads them the same unsure way,
    /// and a vote-share confidence turned that unanimous uncertainty
    /// into a confident answer. It named two different balls the 13.
    public func family(for id: BallID) -> (family: ColorFamily, confidence: Double)? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations,
              let tally = Self.tally(record.observations) else { return nil }
        // The name held since the last switch, not whoever leads this
        // instant; the leader only takes over after `switchObservations`
        // consecutive looks. While it is being challenged the held
        // colour's share has already shrunk, so the confidence (and so
        // `isTentative`) shows the doubt.
        let family = record.committedFamily.flatMap { tally.scores[$0] == nil ? nil : $0 }
            ?? tally.leader
        // Black belongs to the one ball elected the eight. Every other
        // ball that reads dark and neutral is named by its hue instead,
        // or by nothing when no hue was measurable.
        if family == .black, eightElection.holder != id, records[id]?.override != .eight {
            return fallbackFamily(for: record)
        }
        guard let score = tally.scores[family] else { return nil }
        return (family, score.share * score.strength)
    }

    /// The chromatic colour of a dark ball that is not the eight, held
    /// like any other name.
    private func fallbackFamily(for record: Record) -> (family: ColorFamily, confidence: Double)? {
        guard let tally = Self.tally(fallbackLooks: record.observations) else { return nil }
        let family = record.committedFallback.flatMap { tally.scores[$0] == nil ? nil : $0 } ?? tally.leader
        guard let score = tally.scores[family] else { return nil }
        return (family, score.share * score.strength)
    }

    /// Confidence-weighted vote over a window of looks, with a
    /// deterministic tie-break so the same looks always name the same ball
    /// the same way.
    private static func tally(_ observations: [AppearanceObservation])
        -> (leader: ColorFamily, scores: [ColorFamily: (share: Double, strength: Double)])? {
        tally(observations.map { ($0.family, $0.confidence) })
    }

    /// The same vote over the chromatic readings of the looks that called
    /// the ball black.
    private static func tally(fallbackLooks observations: [AppearanceObservation])
        -> (leader: ColorFamily, scores: [ColorFamily: (share: Double, strength: Double)])? {
        tally(observations.compactMap { look in look.fallbackFamily.map { ($0, look.fallbackConfidence) } })
    }

    private static func tally(_ looks: [(family: ColorFamily, confidence: Double)])
        -> (leader: ColorFamily, scores: [ColorFamily: (share: Double, strength: Double)])? {
        var weights: [ColorFamily: Double] = [:]
        var counts: [ColorFamily: Int] = [:]
        for look in looks {
            weights[look.family, default: 0] += look.confidence
            counts[look.family, default: 0] += 1
        }
        let total = weights.values.reduce(0, +)
        guard total > 0,
              let best = weights.max(by: {
                  $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value
              }) else { return nil }
        var scores: [ColorFamily: (share: Double, strength: Double)] = [:]
        for (family, weight) in weights {
            guard let count = counts[family], count > 0, weight > 0 else { continue }
            scores[family] = (weight / total, weight / Double(count))
        }
        guard scores[best.key] != nil else { return nil }
        return (best.key, scores)
    }

    /// Which half of the rack, decided on the strongest evidence ever
    /// seen rather than the average.
    public func group(for id: BallID) -> BallGrouping? {
        guard let record = records[id],
              record.observations.count >= config.minimumObservations,
              let colour = family(for: id) else { return nil }
        if colour.family == .black { return .eight }
        if colour.family == .white { return .cue }
        // A dark ball that lost the eight's election has a hue but no
        // validated group. The stripe signals (hue spread, white band)
        // were measured on bright balls only, and in dim light a dark
        // ball's hue spread is mostly noise, so "no band seen" would read
        // as "solid" and a noisy spread as a stripe. Say nothing instead;
        // `BallGroup.includes` admits an unnamed ball into either half.
        if record.committedFamily == .black { return nil }
        // Either signal is enough. Both are one-directional: they can
        // only ever have seen a band, never proved there isn't one, so a
        // ball that has shown neither is called solid provisionally and
        // will be corrected the moment it rolls and shows otherwise.
        if let spread = record.peakHueSpread, spread >= config.stripeHueSpread { return .stripe }
        return record.peakWhiteFraction >= config.stripeWhiteFraction ? .stripe : .solid
    }

    /// The ball's identity: a player's correction if there is one, else
    /// colour and group combined into a number.
    ///
    /// `.unknown` freely, and by design. Every consumer already handles
    /// it — `BallGroup.includes` admits unnamed balls into both halves of
    /// the rack precisely so a ranking never goes blank on a player who
    /// has picked a side.
    public func kind(for id: BallID) -> Ball.Kind {
        if let override = records[id]?.override { return override }
        guard let colour = family(for: id), let grouping = group(for: id) else { return .unknown }
        switch grouping {
        case .cue: return .cue
        case .eight: return .eight
        case .solid, .stripe:
            guard colour.confidence >= config.namingConfidence,
                  let number = colour.family.solidNumber else { return .unknown }
            return grouping == .solid ? .solid(number) : .stripe(number + 8)
        }
    }

    /// Name every ball in `state` this has an opinion about.
    ///
    /// A ball already known to be the cue ball is never renamed. The
    /// detector's own `white-ball` class and the player's tap
    /// designation are both stronger evidence than a colour vote, and a
    /// mis-renamed cue ball does not just mislabel one ball — it takes
    /// the aim line, the ghost ball and the whole ranking with it.
    ///
    /// At most one ball in the result is `.eight`: the player's tapped
    /// one, else the elected one, else the lowest id. Any other is left
    /// `.unknown` rather than renamed, so a stray eight from anywhere
    /// cannot produce two.
    public func apply(to state: TableState) -> TableState {
        var updated = state
        updated.balls = state.balls.map { ball in
            guard ball.kind != .cue else { return ball }
            let named = kind(for: ball.id)
            guard named != .unknown else { return ball }
            var renamed = ball
            renamed.kind = named
            return renamed
        }
        let eights = updated.balls.filter { $0.kind == .eight }.map(\.id)
        guard eights.count > 1 else { return updated }
        let keeper = eights.first { records[$0]?.override == .eight }
            ?? eights.first { $0 == eightElection.holder }
            ?? eights.min { $0.rawValue < $1.rawValue }
        updated.balls = updated.balls.map { ball in
            guard ball.kind == .eight, ball.id != keeper else { return ball }
            var demoted = ball
            demoted.kind = .unknown
            return demoted
        }
        return updated
    }

    /// True when the ball is named but the naming is a guess worth
    /// showing dimly rather than stating. The HUD uses it to mark a
    /// number as correctable instead of asserting it.
    public func isTentative(for id: BallID) -> Bool {
        guard records[id]?.override == nil, let colour = family(for: id) else { return false }
        return colour.confidence < 0.75
    }
}

/// What a ball is, before it has a number.
public enum BallGrouping: String, Sendable, Equatable, CaseIterable {
    case cue
    case solid
    case stripe
    case eight
}
