//
//  OverlayPrimitives.swift
//  ARExperience
//
//  What is on the cloth, as a flat list the renderer can DIFF.
//
//  The renderer used to throw every entity away and build them again on every
//  changed layout: a fresh ModelEntity per ring, a freshly generated mesh for
//  every strip and every ghost sphere. On the iPad that was 48.7 ms per draw
//  (the `render` stage of `LatencyLedger`), and because a ball's tracked
//  position jitters by a millimetre or two from frame to frame, the layout
//  "changed" on every frame.
//
//  Now:
//   - every thing on the cloth is an `OverlayPrimitive` with a stable key;
//   - meshes are unit shapes (a 1 m box, a unit sphere, a unit disc) shared by
//     every entity and sized by the entity's scale, so a strip that gets
//     longer is a scale change, not a new mesh;
//   - `OverlayDiff.plan` compares the new list with what is already in the
//     scene and says which primitives to build (new, or looking different),
//     which to move (the same thing in a slightly different place), and
//     which to remove. A primitive that moved by less than
//     `OverlayDiff.tolerance` is left exactly where it is.
//
//  The tolerance is 1 mm. At the iPad's nearest rail a millimetre on the
//  cloth is about one screen pixel (1.5 m away, about 1600 px focal length),
//  so a move below it cannot be seen; it is also the size of the tracker's
//  frame-to-frame jitter on a ball that has not moved, which is the case that
//  must not redraw. The comparison is against what is DRAWN, not against the
//  last frame, so a slow drift still shows up once it adds up to a millimetre.
//
//  Pure: tested on Linux. The RealityKit half is `OverlayRenderer`.
//

import CueSyncCore
import Foundation

public struct OverlayPrimitive: Sendable, Equatable {
    /// Which layer it belongs to. The hero group is the suggested shot, which
    /// cross-fades as a unit when the suggestion changes (`HeroTransition`).
    public enum Group: String, Sendable {
        case base
        case hero
    }

    /// The unit shape an entity uses. Sizes ride on the entity's scale, except
    /// a ring, whose radii are part of its mesh and so part of its look.
    public enum Shape: Sendable, Hashable {
        /// A flat annulus, radii in micrometres so the shape is hashable.
        case ring(innerMicrometres: Int, outerMicrometres: Int)
        /// A box 1 m long, 1 m high, 1 m deep, scaled to (length, height, width).
        case box
        /// A sphere of radius 1 m, scaled to the ball's radius.
        case sphere
        /// A cylinder of radius 1 m and height 1 m, scaled to (r, thickness, r).
        case disc
    }

    /// Everything that decides which mesh and which material an entity
    /// needs. A change here is a rebuild; anything else is a move.
    public struct Look: Sendable, Hashable {
        public var shape: Shape
        /// Design-palette colour, 0xRRGGBB.
        public var colour: UInt32
        /// The colour it takes in the opaque metric palette of a recording.
        public var metricMarker: MetricPalette.Marker
        /// Opacity in thousandths, so the look is hashable.
        public var opacityPermille: Int

        public var opacity: Double { Double(opacityPermille) / 1000 }
    }

    /// Stable across frames for "the same thing": `base.ring.3`, `hero.pocket`.
    public var key: String
    public var group: Group
    public var look: Look
    /// World position, lift above the cloth included.
    public var position: Vec3
    /// Entity scale: (length, height, width) for a box, (r, r, r) for a
    /// sphere, (r, thickness, r) for a disc, (1, 1, 1) for a ring.
    public var scale: Vec3
    /// A strip's direction along the cloth; nil for everything else.
    public var heading: Vec3?

    /// A dark edge laid under a mark. The recorder's opaque metric palette
    /// leaves these out: they would only darken the edges of the keyed colours.
    public var isCasing: Bool { look.metricMarker == .casing }
}

public enum OverlayDiff {
    /// Smaller moves than this are not drawn. See the file header.
    public static let tolerance = 0.001

    public enum Change: Sendable, Equatable {
        case none
        case move
        case rebuild
    }

    /// What it takes to turn `old` (what is drawn) into `new`.
    public static func change(from old: OverlayPrimitive, to new: OverlayPrimitive,
                              tolerance: Double = tolerance) -> Change {
        if old.look != new.look || old.group != new.group { return .rebuild }
        if old.position.distance(to: new.position) > tolerance { return .move }
        if abs(old.scale.x - new.scale.x) > tolerance
            || abs(old.scale.y - new.scale.y) > tolerance
            || abs(old.scale.z - new.scale.z) > tolerance {
            return .move
        }
        switch (old.heading, new.heading) {
        case (nil, nil):
            return .none
        case let (a?, b?):
            // How far the strip's far end swings, in metres: the angle
            // matters in proportion to how long the strip is.
            let swing = (a - b).length * Swift.max(old.scale.x, new.scale.x)
            return swing > tolerance ? .move : .none
        default:
            return .move
        }
    }

    public struct Plan: Sendable, Equatable {
        /// New primitives, and ones that look different from what is drawn
        /// (their old entity is removed first).
        public var build: [OverlayPrimitive] = []
        /// Primitives that are the same thing in a different place.
        public var move: [OverlayPrimitive] = []
        /// Primitives that are already drawn where they should be.
        public var keep = 0
        /// Keys that are drawn and no longer wanted.
        public var remove: [String] = []

        /// True when the scene does not change at all.
        public var isEmpty: Bool { build.isEmpty && move.isEmpty && remove.isEmpty }
    }

    /// Compare what is drawn with what is wanted.
    public static func plan(drawn: [String: OverlayPrimitive], wanted: [OverlayPrimitive],
                            tolerance: Double = tolerance) -> Plan {
        var plan = Plan()
        var wantedKeys: Set<String> = []
        for primitive in wanted {
            wantedKeys.insert(primitive.key)
            guard let old = drawn[primitive.key] else {
                plan.build.append(primitive)
                continue
            }
            switch change(from: old, to: primitive, tolerance: tolerance) {
            case .none: plan.keep += 1
            case .move: plan.move.append(primitive)
            case .rebuild: plan.build.append(primitive)
            }
        }
        plan.remove = drawn.keys.filter { !wantedKeys.contains($0) }.sorted()
        return plan
    }
}

extension OverlayLayout {
    /// Every mark on the cloth for this layout, in a stable order, each with a
    /// stable key. The renderer draws exactly these and nothing else.
    public var primitives: [OverlayPrimitive] {
        var list: [OverlayPrimitive] = []
        let lift = OverlayStyle.markerLift

        func permille(_ opacity: Double) -> Int { Int((opacity * 1000).rounded()) }
        func micrometres(_ metres: Double) -> Int { Int((metres * 1e6).rounded()) }
        func lifted(_ point: Vec3, _ height: Double) -> Vec3 { Vec3(point.x, point.y + height, point.z) }
        /// How a ring looks: its radii, colour, metric marker, opacity and lift.
        struct RingSpec {
            var radii: (inner: Double, outer: Double)
            var colour: UInt32
            var marker: MetricPalette.Marker
            var opacity: Double
            var lift: Double
        }
        func ring(_ key: String, _ group: OverlayPrimitive.Group, at point: Vec3,
                  _ spec: RingSpec) -> OverlayPrimitive {
            OverlayPrimitive(
                key: key, group: group,
                look: .init(shape: .ring(innerMicrometres: micrometres(spec.radii.inner),
                                         outerMicrometres: micrometres(spec.radii.outer)),
                            colour: spec.colour, metricMarker: spec.marker,
                            opacityPermille: permille(spec.opacity)),
                position: lifted(point, spec.lift), scale: Vec3(1, 1, 1), heading: nil)
        }
        func strip(_ key: String, _ group: OverlayPrimitive.Group, _ strip: Strip) -> OverlayPrimitive {
            let tier = OverlayStyle.tier(of: strip)
            let width = OverlayStyle.width(tier)
            return OverlayPrimitive(
                key: key, group: group,
                look: .init(shape: .box, colour: strip.color,
                            metricMarker: MetricPalette.stripMarker(forDesignColor: strip.color),
                            opacityPermille: permille(OverlayStyle.opacity(tier))),
                position: lifted(strip.midpoint, OverlayStyle.lift(tier)),
                scale: Vec3(strip.length, width / 2, width), heading: strip.direction)
        }

        // Rings, never plates: see OverlayStyle. The ring on the target ball
        // belongs to the hero, so it fades with the shot it is part of.
        for (index, ball) in balls.enumerated() {
            let involved = ball.isCue || ball.isTarget
            let group: OverlayPrimitive.Group = ball.isTarget ? .hero : .base
            list.append(ring("\(group.rawValue).ring.\(index)", group, at: ball.position, RingSpec(
                radii: OverlayStyle.ballRing(ballRadius: ball.radius),
                colour: ball.isCue ? OverlayStyle.cueRingColor
                    : ball.isTarget ? OverlayStyle.targetRingColor : OverlayStyle.ballRingColor,
                marker: ball.isCue ? .cueBall : ball.isTarget ? .pocket : .ball,
                opacity: involved ? OverlayStyle.involvedRingOpacity : OverlayStyle.ballRingOpacity,
                lift: lift)))
        }
        for (index, line) in strips.enumerated() { list.append(strip("base.strip.\(index)", .base, line)) }
        // The suggested shot's lines sit on a dark casing, so they read on
        // any cloth (OverlayPalette). The casing comes first in the list and
        // floats a little below its line.
        for (index, line) in targetStrips.enumerated() {
            let tier = OverlayStyle.tier(of: line)
            if tier == .hero || tier == .lead {
                let width = OverlayStyle.width(tier) + OverlayStyle.casingExtraWidth
                list.append(OverlayPrimitive(
                    key: "hero.casing.\(index)", group: .hero,
                    look: .init(shape: .box, colour: OverlayStyle.casingColor, metricMarker: .casing,
                                opacityPermille: permille(OverlayStyle.casingOpacity)),
                    position: lifted(line.midpoint, OverlayStyle.lift(tier) - OverlayStyle.casingDrop),
                    scale: Vec3(line.length, OverlayStyle.width(tier) / 2, width), heading: line.direction))
            }
            list.append(strip("hero.strip.\(index)", .hero, line))
        }

        if let ghostBall {
            list.append(OverlayPrimitive(
                key: "base.ghost", group: .base,
                look: .init(shape: .sphere, colour: OverlayStyle.shotColor, metricMarker: .ghostBall,
                            opacityPermille: permille(OverlayStyle.liveGhostOpacity)),
                position: lifted(ghostBall.position, ghostBall.radius),
                scale: Vec3(repeating: ghostBall.radius), heading: nil))
        }
        for (index, pocket) in highlightedPockets.enumerated() {
            list.append(ring("base.pocket.\(index)", .base, at: pocket.position, RingSpec(
                radii: OverlayStyle.pocketRing(captureRadius: pocket.radius),
                colour: OverlayStyle.pocketRingColor, marker: .pocket,
                opacity: OverlayStyle.liveFlatMarkerOpacity, lift: lift)))
        }
        if let calledPocket {
            let satisfied = calledPocketSatisfied
            list.append(OverlayPrimitive(
                key: "base.called", group: .base,
                look: .init(shape: .disc, colour: OverlayStyle.calledPocketColor,
                            metricMarker: satisfied ? .calledPocketOnLine : .calledPocket,
                            opacityPermille: permille(satisfied ? OverlayStyle.calledPocketOnLineOpacity
                                : OverlayStyle.calledPocketOpacity)),
                position: lifted(calledPocket.position, lift * 2),
                scale: Vec3(calledPocket.radius, OverlayStyle.markerThickness, calledPocket.radius),
                heading: nil))
        }
        if let targetPocket {
            // The pocket to hit: a thick ring 1.5 capture radii out, on its
            // own casing (OverlayStyle explains the size).
            list.append(ring("hero.pocket.casing", .hero, at: targetPocket.position, RingSpec(
                radii: OverlayStyle.targetPocketCasing(captureRadius: targetPocket.radius),
                colour: OverlayStyle.casingColor, marker: .casing,
                opacity: OverlayStyle.casingOpacity, lift: lift * 1.5)))
            list.append(ring("hero.pocket", .hero, at: targetPocket.position, RingSpec(
                radii: OverlayStyle.targetPocketRing(captureRadius: targetPocket.radius),
                colour: OverlayStyle.pocketRingColor, marker: .pocket,
                opacity: OverlayStyle.pocketRingOpacity, lift: lift * 1.6)))
        }
        if let targetGhostBall {
            list.append(OverlayPrimitive(
                key: "hero.ghost", group: .hero,
                look: .init(shape: .sphere, colour: OverlayStyle.shotColor, metricMarker: .ghostBall,
                            opacityPermille: permille(OverlayStyle.targetGhostOpacity)),
                position: lifted(targetGhostBall.position, targetGhostBall.radius),
                scale: Vec3(repeating: targetGhostBall.radius), heading: nil))
        }
        return list
    }
}

/// What the renderer's calls have done to the scene, for `/state.json`: how
/// much of each render was building, moving, keeping, removing.
public struct OverlayRenderStats: Sendable, Equatable {
    /// Calls to `render`, and how many of them changed the scene at all.
    public private(set) var renders = 0
    public private(set) var redraws = 0
    /// Totals over every render.
    public private(set) var built = 0
    public private(set) var moved = 0
    public private(set) var removed = 0
    /// The most recent render.
    public private(set) var lastBuilt = 0
    public private(set) var lastMoved = 0
    public private(set) var lastKept = 0
    public private(set) var lastRemoved = 0

    public init() {}

    public mutating func note(built: Int, moved: Int, kept: Int, removed: Int) {
        renders += 1
        if built + moved + removed > 0 { redraws += 1 }
        self.built += built
        self.moved += moved
        self.removed += removed
        lastBuilt = built
        lastMoved = moved
        lastKept = kept
        lastRemoved = removed
    }
}
