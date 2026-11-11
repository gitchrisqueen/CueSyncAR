//
//  ShotCall.swift
//  CoachKit
//
//  Naming the shot the way the player sees it.
//
//  The shot card used to say "bottom side": a name in TABLE coordinates,
//  which from where the player stands might be the pocket on their right,
//  the one in front of them or the one furthest away. And it never named
//  the ball at all. A player reads "Blue ball -> right side pocket"; this
//  file is where that sentence comes from, as pure functions so every
//  camera position and every pocket is covered by a test on Linux.
//
//  Three small pieces:
//
//  * `PocketViewFrame` — which table direction is the viewer's right and
//    which is "away". Built from the camera's position, or (what the app
//    uses, because it is exact for any device orientation and tilt) from
//    where the table's own axes land on the screen.
//  * `PocketViewNaming` — a pocket's position in that frame, as words.
//  * `BallNaming` — the ball, as words.
//

import CueSyncCore
import Foundation

// MARK: - The viewer's frame

/// Which table-space directions are "right" and "away" for whoever is
/// looking at the table.
///
/// Table space is read as seen from above, x to the right and y up the page
/// (the table's normal pointing at the viewer); the camera-position
/// initialiser relies on that. The screen-axes initialiser does not: it is
/// derived from where the axes actually land, so a mirrored calibration
/// still comes out right.
public struct PocketViewFrame: Sendable, Equatable {
    /// Unit vector in table space pointing to the viewer's right.
    public let right: Vec2
    /// Unit vector in table space pointing away from the viewer, up the
    /// screen.
    public let forward: Vec2

    public init(right: Vec2, forward: Vec2) {
        self.right = right.normalized
        self.forward = forward.normalized
    }

    /// The view the 2D table drawing has: table x to the right, table y up.
    public static let identity = PocketViewFrame(right: Vec2(1, 0), forward: Vec2(0, 1))

    /// A camera at `camera` looking toward `target` (the table centre by
    /// default), both in table space. Nil when the camera is so close to
    /// the target that "toward" has no meaning.
    public init?(cameraAt camera: Vec2, lookingAt target: Vec2 = Vec2(0, 0)) {
        let toward = target - camera
        guard toward.length > 0.05 else { return nil }
        let forward = toward.normalized
        self.init(right: Vec2(forward.y, -forward.x), forward: forward)
    }

    /// From where the table's axes land on the screen.
    ///
    /// - Parameters:
    ///   - origin: the screen point of the table centre.
    ///   - xTip: the screen point of the table centre moved along +x.
    ///   - yTip: the screen point of the table centre moved along +y.
    ///
    /// Screen points have y DOWN, as UIKit and SwiftUI do. Nil when the
    /// axes are degenerate on screen, which is what a table seen edge-on
    /// looks like.
    public init?(screenOrigin origin: Vec2, xTip: Vec2, yTip: Vec2) {
        let sx = xTip - origin
        let sy = yTip - origin
        let determinant = sx.x * sy.y - sy.x * sx.y
        guard abs(determinant) > 1e-6 else { return nil }
        // Invert [sx sy]: the table direction that moves a point right on
        // the screen, and the one that moves it up.
        let right = Vec2(sy.y, -sx.y) / determinant
        let forward = Vec2(sy.x, -sx.x) / determinant
        guard right.length > 1e-9, forward.length > 1e-9 else { return nil }
        self.init(right: right, forward: forward)
    }
}

// MARK: - Pockets

/// A pocket named from the viewer's side of the table.
public struct PocketViewLabel: Sendable, Equatable {
    public enum Depth: String, Sendable, Equatable { case near, far }
    public enum Lateral: String, Sendable, Equatable { case left, right }

    /// A corner pocket sits at a depth AND a side; a side pocket at one
    /// of the two.
    public enum Place: Sendable, Equatable {
        case corner(Depth, Lateral)
        /// A corner seen from a table corner: straight ahead or behind.
        case cornerAhead(Depth)
        /// A corner seen from a table corner: straight left or right.
        case cornerAside(Lateral)
        case sideAcross(Lateral)
        case sideAlong(Depth)
    }

    public let place: Place

    /// "far-left corner", "right side pocket", "near side pocket".
    public var name: String {
        switch place {
        case .corner(let depth, let lateral): "\(depth.rawValue)-\(lateral.rawValue) corner"
        case .cornerAhead(let depth): "\(depth.rawValue) corner"
        case .cornerAside(let lateral): "\(lateral.rawValue) corner"
        case .sideAcross(let lateral): "\(lateral.rawValue) side pocket"
        case .sideAlong(let depth): "\(depth.rawValue) side pocket"
        }
    }
}

public enum PocketViewNaming {

    /// Below this ratio of the smaller offset to the larger, a corner is
    /// "straight ahead" (or aside) rather than ahead-and-to-one-side.
    /// A table seen end-on has 0.5 for its corners, so this leaves a margin.
    static let diamondRatio = 0.4

    /// Where a pocket is, as seen from `frame`.
    ///
    /// - Parameters:
    ///   - position: the pocket mouth in table space (the table centre is
    ///     the origin).
    ///   - halfExtents: half the playing field, `Table.halfExtents`. Only
    ///     used to tell a corner from a side pocket.
    public static func label(forPocketAt position: Vec2, halfExtents: Vec2,
                             frame: PocketViewFrame) -> PocketViewLabel {
        let depth = position.dot(frame.forward)
        let lateral = position.dot(frame.right)
        let isCorner = abs(position.x) > halfExtents.x * 0.5
            && abs(position.y) > halfExtents.y * 0.5
        let depthName: PocketViewLabel.Depth = depth < 0 ? .near : .far
        let lateralName: PocketViewLabel.Lateral = lateral < 0 ? .left : .right
        if isCorner {
            // Seen from a table corner the table is a diamond, and two
            // corners would both read "far-right". When one offset is
            // much smaller than the other, drop it: "far corner" and
            // "right corner" are what a player there would say.
            let ahead = abs(depth), aside = abs(lateral)
            if aside < Self.diamondRatio * ahead { return PocketViewLabel(place: .cornerAhead(depthName)) }
            if ahead < Self.diamondRatio * aside { return PocketViewLabel(place: .cornerAside(lateralName)) }
            return PocketViewLabel(place: .corner(depthName, lateralName))
        }
        // A side pocket sits halfway along a long rail. Seen end-on it is
        // off to one side; seen from that rail it is straight ahead or
        // behind. Whichever offset is bigger is the one a player would say.
        return abs(lateral) >= abs(depth)
            ? PocketViewLabel(place: .sideAcross(lateralName))
            : PocketViewLabel(place: .sideAlong(depthName))
    }

    /// Every pocket of `table`, named.
    public static func names(for table: Table, frame: PocketViewFrame) -> [PocketID: String] {
        var out: [PocketID: String] = [:]
        for pocket in table.pockets {
            out[pocket.id] = label(forPocketAt: pocket.position, halfExtents: table.halfExtents,
                                   frame: frame).name
        }
        return out
    }
}

// MARK: - Balls

public enum BallNaming {

    /// Colours of a standard set, solids 1...7. Stripes 9...15 repeat them.
    private static let setColours = ["yellow", "blue", "red", "purple", "orange", "green", "maroon"]

    /// What a player calls this ball: "Blue ball", "Yellow stripe",
    /// "8-ball", "Cue ball", or just "Ball" when nothing is known.
    ///
    /// - Parameters:
    ///   - kind: what the tracker decided the ball is.
    ///   - colour: the colour family the tracker measured, when it has one
    ///     (`ColorFamily.rawValue`). Preferred to the colour implied by the
    ///     number, because it is what was actually seen.
    public static func name(kind: Ball.Kind, colour: String? = nil) -> String {
        switch kind {
        case .cue: return "Cue ball"
        case .eight: return "8-ball"
        case .solid(let number):
            return word(colour ?? colourOfSolid(number), noun: "ball")
        case .stripe(let number):
            return word(colour ?? colourOfSolid(number - 8), noun: "stripe")
        case .unknown:
            guard let colour, colour != "black" else { return "Ball" }
            return colour == "white" ? "Cue ball" : word(colour, noun: "ball")
        }
    }

    private static func colourOfSolid(_ number: Int) -> String? {
        guard (1...setColours.count).contains(number) else { return nil }
        return setColours[number - 1]
    }

    private static func word(_ colour: String?, noun: String) -> String {
        guard let colour, !colour.isEmpty else { return noun == "stripe" ? "Striped ball" : "Ball" }
        return "\(colour.prefix(1).uppercased())\(colour.dropFirst()) \(noun)"
    }
}

// MARK: - The call

/// The shot in the player's words: which ball, into which pocket.
public struct ShotCall: Sendable, Equatable {
    /// "Blue ball".
    public let ball: String
    /// "right side pocket", or nil while the view of the table is unknown.
    /// Never the table-axis name: a wrong direction is worse than none.
    public let pocket: String?

    public init(ball: String, pocket: String?) {
        self.ball = ball
        self.pocket = pocket
    }

    /// The card's line: "Blue ball → right side pocket".
    public var line: String {
        pocket.map { "\(ball) → \($0)" } ?? ball
    }

    /// The same, to be heard: "Blue ball into the right side pocket".
    public var spoken: String {
        pocket.map { "\(ball) into the \($0)" } ?? ball
    }
}

// MARK: - Difficulty as a word

extension ShotRating.Difficulty {
    /// The word the player sees. Three tiers, because a percentage that
    /// moves with calibration drift is not a make probability and should
    /// not read like one.
    public var tierWord: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Fair"
        case .hard, .longShot: "Hard"
        case .blocked: "Blocked"
        }
    }

    /// Same word, to be heard in a sentence.
    public var spokenTier: String { tierWord.lowercased() }
}

/// Holds the difficulty word steady.
///
/// The bands are cut from a probability that wanders a few points as
/// calibration drifts, so a shot sitting on a boundary would flip between
/// "Easy" and "Fair" while nothing on the table moved. A new word has to
/// persist for `dwell` seconds before it replaces the one shown. A
/// different shot, or a block, is shown at once: those are facts, not noise.
public struct DifficultyHold: Sendable, Equatable {
    public var dwell: TimeInterval
    private var shown: ShotRating.Difficulty?
    private var shotKey: String?
    private var pending: ShotRating.Difficulty?
    private var pendingSince: TimeInterval = 0

    public init(dwell: TimeInterval = 1.5) {
        self.dwell = dwell
    }

    /// The difficulty to show for this shot at `now` (monotonic seconds).
    public mutating func resolve(_ shot: ShotRating, at now: TimeInterval) -> ShotRating.Difficulty {
        let key = "\(shot.ball.rawValue).\(shot.pocket.rawValue)"
        let current = shot.difficulty
        guard key == shotKey, let held = shown, current != .blocked, held != .blocked else {
            shotKey = key
            shown = current
            pending = nil
            return current
        }
        guard current != held else {
            pending = nil
            return held
        }
        if pending != current {
            pending = current
            pendingSince = now
        }
        if now - pendingSince >= dwell {
            shown = current
            pending = nil
            return current
        }
        return held
    }

    /// Forget everything, e.g. when the table is cleared.
    public mutating func reset() {
        shown = nil
        shotKey = nil
        pending = nil
    }
}
