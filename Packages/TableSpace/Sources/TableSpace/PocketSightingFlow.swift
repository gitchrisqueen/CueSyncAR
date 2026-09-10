//
//  PocketSightingFlow.swift
//  CueSync AR
//
//  Tapping pockets instead of cushion noses, as a state machine.
//
//  Why this flow exists at all: on a table with cloth-wrapped cushions the
//  nose line has no contrast — that is the whole thesis of the pocket
//  calibration solver. But the four-tap corner flow still asks the user to
//  find a line they cannot see, and the solver that works is reachable only
//  by typing screen coordinates into a debug URL.
//
//  A pocket mouth is the one high-contrast feature on a black table, it can
//  be named without a diagram, and it is visible from the side of the table
//  where the camera actually sits. So the ask becomes "tap the pockets you
//  can see" — two or three taps instead of four, on things that are
//  actually there.
//
//  The flow owns WHAT HAS BEEN SIGHTED and WHAT IS STILL MISSING, and
//  nothing else. It does no raycasting, no solving and no I/O, so the rules
//  about what the solver needs are checkable without a device — which
//  matters, because those rules are where this is easy to get wrong.
//
//  Screen points are Vec2, not CGPoint: this package builds and is tested
//  on Linux, where CoreGraphics does not exist.
//

import CueSyncCore
import Foundation

/// Collects pocket sightings until there is enough to solve a table.
public struct PocketSightingFlow: Sendable, Equatable {

    /// One tap: which pocket the user says it is, and where on screen.
    public struct Sighting: Sendable, Equatable {
        public var pocket: PocketID
        public var screen: Vec2

        public init(pocket: PocketID, screen: Vec2) {
            self.pocket = pocket
            self.screen = screen
        }
    }

    /// What the solver still needs. Each case is a different sentence to
    /// put on screen, which is why they are not collapsed into one.
    public enum Readiness: Sendable, Equatable {
        /// Nothing sighted yet, or one pocket and no rail heading.
        case needMorePockets(have: Int)
        /// Exactly one pocket: the solver can work from it plus the
        /// direction of a rail, but it needs that heading drawn.
        case needRailHeading
        /// Two or more pockets that are all on one line — the fit is
        /// mirror-ambiguous until something says which side the cloth is.
        case needTowardsPoint
        /// Enough to solve.
        case ready
    }

    public private(set) var sightings: [Sighting] = []
    /// A point on the cloth, inside the table, that resolves the mirror
    /// ambiguity of a collinear or single-pocket fit.
    public private(set) var towards: Vec2?
    /// Two screen points along a rail, for the one-pocket path.
    ///
    /// A named type rather than a tuple: a tuple member silently blocks
    /// `Equatable` synthesis, which is the same trap `DetectionHealth`
    /// already hit once in this codebase.
    public struct RailHeading: Sendable, Equatable {
        public var from: Vec2
        public var to: Vec2

        public init(from: Vec2, to: Vec2) {
            self.from = from
            self.to = to
        }

        /// Screen-space direction of the rail.
        public var direction: Vec2 { to - from }
    }

    public private(set) var railHeading: RailHeading?

    public init() {}

    // MARK: - Taps

    /// Record a pocket. Sighting the same pocket twice REPLACES the first —
    /// a user correcting a mis-tap is the common case, and silently keeping
    /// both would hand the solver two contradictory positions for one hole.
    public mutating func sight(_ pocket: PocketID, at screen: Vec2) {
        if let index = sightings.firstIndex(where: { $0.pocket == pocket }) {
            sightings[index] = Sighting(pocket: pocket, screen: screen)
        } else {
            sightings.append(Sighting(pocket: pocket, screen: screen))
        }
    }

    public mutating func setTowards(_ screen: Vec2?) { towards = screen }

    public mutating func setRailHeading(_ heading: RailHeading?) { railHeading = heading }

    /// Remove the most recent sighting. Undo, not reset: a user who
    /// mis-taps the fourth pocket should not lose the first three.
    public mutating func undoLastSighting() {
        guard !sightings.isEmpty else { return }
        sightings.removeLast()
    }

    public mutating func reset() {
        sightings.removeAll()
        towards = nil
        railHeading = nil
    }

    // MARK: - What is still missing

    /// Whether the sighted pockets all lie on one screen line, within a
    /// tolerance. Two pockets are always collinear, which is why the
    /// two-pocket case always wants a towards point.
    public var sightingsAreCollinear: Bool {
        guard sightings.count >= 2 else { return true }
        let first = sightings[0].screen
        let axis = sightings[1].screen - first
        guard axis.length > 1 else { return true }
        let unit = axis / axis.length
        return sightings.dropFirst(2).allSatisfy { sighting in
            let offset = sighting.screen - first
            let along = offset.dot(unit)
            let perpendicular = (offset - unit * along).length
            // Generous: these are finger taps on pocket mouths, not
            // surveyed points. Anything under ~2 % of the span reads as
            // "the user tapped along one rail".
            return perpendicular < max(8, axis.length * 0.02)
        }
    }

    public var readiness: Readiness {
        switch sightings.count {
        case 0:
            return .needMorePockets(have: 0)
        case 1:
            guard railHeading != nil else { return .needRailHeading }
            return towards == nil ? .needTowardsPoint : .ready
        default:
            // Three or more non-collinear pockets pin the table on their
            // own; anything collinear still needs a side.
            if sightingsAreCollinear && towards == nil { return .needTowardsPoint }
            return .ready
        }
    }

    public var canSolve: Bool { readiness == .ready }

    /// What to put on the HUD. Physical nouns, no mechanism, and it counts
    /// so the user can see the flow making progress.
    public var prompt: String {
        switch readiness {
        case .needMorePockets:
            return "Tap the pockets you can see (0 of 2)"
        case .needRailHeading:
            return "One pocket — now drag along the rail it sits on"
        case .needTowardsPoint:
            return sightings.count == 1
                ? "Now tap the middle of the table"
                : "Tap the middle of the table so it knows which side the cloth is"
        case .ready:
            let named = sightings.map(\.pocket.rawValue).joined(separator: ", ")
            return "Ready — \(sightings.count) pocket\(sightings.count == 1 ? "" : "s") (\(named))"
        }
    }
}
