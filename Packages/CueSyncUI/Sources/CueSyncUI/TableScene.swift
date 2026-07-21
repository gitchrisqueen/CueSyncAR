//
//  TableScene.swift
//  CueSyncUI
//
//  Pure composer: turns TableState + ShotPrediction + a viewport size into
//  view-space draw primitives. The SwiftUI Canvas (TableSceneView) and any
//  future renderer (external display, mini-map) draw exactly these
//  primitives, so all layout/styling rules are testable on Linux.
//
//  View space: origin top-left, y down, points. Table space: origin center,
//  y up, meters — the composer flips y.
//

import CueSyncCore
import Foundation

public struct TableScene: Sendable, Equatable {
    public struct Mark: Sendable, Equatable {
        public var center: Vec2
        public var radius: Double
        public var style: BallStyle
        /// Ghost balls render as outlines only.
        public var isGhost: Bool
    }

    public struct PocketMark: Sendable, Equatable {
        public var id: PocketID
        public var center: Vec2
        public var radius: Double
        public var highlighted: Bool
    }

    public struct PathMark: Sendable, Equatable {
        public enum Style: Sendable, Equatable {
            /// Cue-ball path before first contact.
            case aim
            /// Object-ball path after being struck.
            case object
            /// Cue-ball path after contact.
            case cueAfterContact
            /// Cue-ball path that ends in a pocket.
            case scratch
        }

        public var ballID: BallID
        public var points: [Vec2]
        public var style: Style

        public var color: ColorToken {
            switch style {
            case .aim: Theme.cueAmber
            case .object: Theme.feltGreen
            case .cueAfterContact: Theme.chalkBlue
            case .scratch: Theme.warnCoral
            }
        }

        public var dashed: Bool { style == .cueAfterContact || style == .scratch }
    }

    /// Outer wood rail rectangle (x, y, width, height) in view points.
    public var railFrame: (x: Double, y: Double, width: Double, height: Double)
    /// Cloth rectangle in view points.
    public var feltFrame: (x: Double, y: Double, width: Double, height: Double)
    public var pockets: [PocketMark]
    public var balls: [Mark]
    public var ghostBall: Mark?
    public var paths: [PathMark]
    /// Points-per-meter scale used for the mapping (exposed for labels).
    public var scale: Double

    public static func == (lhs: TableScene, rhs: TableScene) -> Bool {
        lhs.railFrame == rhs.railFrame && lhs.feltFrame == rhs.feltFrame
            && lhs.pockets == rhs.pockets && lhs.balls == rhs.balls
            && lhs.ghostBall == rhs.ghostBall && lhs.paths == rhs.paths
            && lhs.scale == rhs.scale
    }

    // MARK: - Composition

    /// Rail width in meters (visual only).
    public static let railWidth = 0.05

    public static func compose(state: TableState,
                               prediction: ShotPrediction? = nil,
                               viewportWidth: Double,
                               viewportHeight: Double,
                               padding: Double = 16) -> TableScene {
        let (tableW, tableH) = state.table.size.playField
        let outerW = tableW + 2 * railWidth
        let outerH = tableH + 2 * railWidth
        let usableW = Swift.max(1, viewportWidth - 2 * padding)
        let usableH = Swift.max(1, viewportHeight - 2 * padding)
        let scale = Swift.min(usableW / outerW, usableH / outerH)
        let cx = viewportWidth / 2
        let cy = viewportHeight / 2

        func map(_ p: Vec2) -> Vec2 {
            Vec2(cx + p.x * scale, cy - p.y * scale)
        }

        let railFrame = (x: cx - outerW * scale / 2, y: cy - outerH * scale / 2,
                         width: outerW * scale, height: outerH * scale)
        let feltFrame = (x: cx - tableW * scale / 2, y: cy - tableH * scale / 2,
                         width: tableW * scale, height: tableH * scale)

        // Pockets — highlighted when the prediction sends any ball there.
        var litPockets: Set<PocketID> = []
        if let prediction {
            for event in prediction.events {
                if case let .pocket(_, pocket) = event { litPockets.insert(pocket) }
            }
        }
        let pockets = state.table.pockets.map { pocket in
            PocketMark(id: pocket.id,
                       center: map(pocket.position),
                       radius: pocket.captureRadius * scale,
                       highlighted: litPockets.contains(pocket.id))
        }

        let balls = state.balls.map { ball in
            Mark(center: map(ball.position),
                 radius: ball.radius * scale,
                 style: Theme.ballStyle(for: ball.kind),
                 isGhost: false)
        }

        var ghost: Mark?
        var paths: [PathMark] = []
        if let prediction {
            if let contact = prediction.firstContact {
                let radius = (state.ball(contact.moving)?.radius ?? Ball.standardRadius) * scale
                ghost = Mark(center: map(contact.contact), radius: radius,
                             style: Theme.ballStyle(for: .cue), isGhost: true)
            }
            paths = composePaths(state: state, prediction: prediction, map: map)
        }

        return TableScene(railFrame: railFrame, feltFrame: feltFrame,
                          pockets: pockets, balls: balls, ghostBall: ghost,
                          paths: paths, scale: scale)
    }

    /// Styling rules (05-UX-DESIGN): cue pre-contact = aim (amber); cue
    /// post-contact = chalk blue, or coral when the cue scratches; every
    /// other ball = felt green. Consecutive segments merge into polylines,
    /// split at the first contact for the cue ball.
    private static func composePaths(state: TableState,
                                     prediction: ShotPrediction,
                                     map: (Vec2) -> Vec2) -> [PathMark] {
        var paths: [PathMark] = []
        let cueID = state.cueBall?.id
        let contactPoint = prediction.firstContact?.contact

        var grouped: [BallID: [TrajectorySegment]] = [:]
        var order: [BallID] = []
        for segment in prediction.segments {
            if grouped[segment.ballID] == nil { order.append(segment.ballID) }
            grouped[segment.ballID, default: []].append(segment)
        }

        for ballID in order {
            let segments = grouped[ballID] ?? []
            guard let first = segments.first else { continue }
            let scratched = prediction.pocketedBalls.contains(ballID) && ballID == cueID

            if ballID == cueID, let contactPoint {
                // Split at the contact: aim line up to the ghost ball, then
                // the post-contact tangent path.
                var pre: [Vec2] = [first.start]
                var post: [Vec2] = []
                var reachedContact = false
                for segment in segments {
                    if reachedContact {
                        post.append(segment.end)
                    } else if segment.end == contactPoint {
                        pre.append(segment.end)
                        reachedContact = true
                        post.append(segment.end)
                    } else {
                        pre.append(segment.end)
                    }
                }
                paths.append(PathMark(ballID: ballID, points: pre.map(map), style: .aim))
                if post.count > 1 {
                    paths.append(PathMark(ballID: ballID, points: post.map(map),
                                          style: scratched ? .scratch : .cueAfterContact))
                }
            } else {
                var points: [Vec2] = [first.start]
                points.append(contentsOf: segments.map(\.end))
                let style: PathMark.Style
                if ballID == cueID {
                    style = scratched ? .scratch : .aim
                } else {
                    style = .object
                }
                paths.append(PathMark(ballID: ballID, points: points.map(map), style: style))
            }
        }
        return paths
    }
}
