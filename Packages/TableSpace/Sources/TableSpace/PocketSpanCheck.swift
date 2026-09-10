//
//  PocketSpanCheck.swift
//  CueSync AR
//
//  What the taps actually measured, before any table is fitted.
//
//  A refused pocket fit used to say one number — "fit is 34 cm out" —
//  and then guess at a cause: "stand closer, or sight a third pocket."
//  Both halves are unhelpful. The number does not say WHICH tap was
//  wrong, and the advice is frequently the wrong advice: on the device
//  the dominant error was not range at all, it was the cloth height the
//  taps were cast against.
//
//  Those two causes are separable without fitting anything, by measuring
//  the distances BETWEEN the sighted pockets and comparing them with the
//  distances those same pockets have on a real table:
//
//  * A wrong cloth height moves every point along its own ray, which
//    scales the whole constellation about the camera. Every span is then
//    wrong by roughly the SAME RATIO, and that ratio says which way the
//    plane has to move.
//  * A mislabelled or mis-tapped pocket moves ONE point. Its spans are
//    wrong and everyone else's are right, so it stands out against the
//    median instead of hiding inside an average.
//
//  So the median ratio is the height diagnosis and the outlier is the
//  tap diagnosis, and neither needs a solve to succeed first — which
//  matters, because this runs precisely when the solve was refused.
//

import CueSyncCore
import Foundation

extension PocketCalibration {

    /// One measured pocket-to-pocket distance against its true length.
    public struct Span: Sendable, Equatable {
        public var from: PocketID
        public var to: PocketID
        /// Metres between the two sighted world points.
        public var measured: Double
        /// Metres between those pockets on a table of the stated size.
        public var expected: Double

        public init(from: PocketID, to: PocketID, measured: Double, expected: Double) {
            self.from = from
            self.to = to
            self.measured = measured
            self.expected = expected
        }

        /// Measured over expected. 1.0 is right, below 1 is too small.
        public var ratio: Double { expected > 0 ? measured / expected : 0 }
    }

    /// What a set of sightings says before anything is fitted to them.
    public struct SpanReport: Sendable, Equatable {
        public var spans: [Span]

        public init(spans: [Span]) { self.spans = spans }

        /// The typical scale error. Robust to one bad pocket, which is
        /// the entire reason it is a median and not a mean.
        public var medianRatio: Double {
            let sorted = spans.map(\.ratio).sorted()
            guard !sorted.isEmpty else { return 1 }
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2)
                ? (sorted[mid - 1] + sorted[mid]) / 2
                : sorted[mid]
        }

        /// The pocket whose spans disagree most with the median scale —
        /// the one to re-tap. Nil when fewer than three pockets were
        /// sighted, because with two there is nothing to outvote.
        public var suspectPocket: PocketID? {
            let pockets = Set(spans.flatMap { [$0.from, $0.to] })
            guard pockets.count >= 3 else { return nil }
            let median = medianRatio
            return pockets.max { lhs, rhs in
                disagreement(of: lhs, against: median) < disagreement(of: rhs, against: median)
            }
        }

        /// How far this pocket's own spans sit from the common scale, in
        /// metres — the distance it would have to move to agree.
        public func disagreement(of pocket: PocketID, against scale: Double) -> Double {
            let mine = spans.filter { $0.from == pocket || $0.to == pocket }
            guard !mine.isEmpty else { return 0 }
            return mine.map { abs($0.measured - $0.expected * scale) }.reduce(0, +)
                / Double(mine.count)
        }

        /// The scale-corrected worst disagreement, in metres. Small means
        /// the taps are self-consistent and only the plane is off; large
        /// means at least one of them is on the wrong hole.
        public var worstDisagreement: Double {
            guard let suspect = suspectPocket else { return 0 }
            return disagreement(of: suspect, against: medianRatio)
        }
    }

    /// Measure the sightings against themselves.
    ///
    /// Repeated sightings of one pocket are averaged first, so sighting
    /// the same hole twice cannot contribute a zero-length span and drag
    /// the median toward nonsense.
    public static func spanReport(_ sightings: [Sighting], size: TableSize) -> SpanReport {
        var averaged: [PocketID: (sum: Vec3, count: Double)] = [:]
        for sighting in sightings {
            let existing = averaged[sighting.pocket] ?? (Vec3(0, 0, 0), 0)
            averaged[sighting.pocket] = (existing.sum + sighting.world, existing.count + 1)
        }
        let world = averaged.mapValues { $0.sum / $0.count }

        let table = Table(size: size)
        var truth: [PocketID: Vec2] = [:]
        for pocket in table.pockets { truth[pocket.id] = pocket.position }

        let ids = world.keys.sorted { $0.rawValue < $1.rawValue }
        var spans: [Span] = []
        for (index, first) in ids.enumerated() {
            for second in ids.dropFirst(index + 1) {
                guard let a = truth[first], let b = truth[second] else { continue }
                spans.append(Span(from: first, to: second,
                                  measured: (world[first]! - world[second]!).length,
                                  expected: (a - b).length))
            }
        }
        return SpanReport(spans: spans)
    }
}
