//
//  OverlayLayout.swift
//  ARExperience
//
//  Task M3-04 (logic): converts a ShotPrediction into placement data for
//  RealityKit entities — one strip per trajectory segment (midpoint, length,
//  rotation about the plane normal), the ghost ball, and pocket highlights.
//  Pure and unit-tested; OverlayRenderer (ARKit/RealityKit-gated) turns
//  these into entities 1:1.
//

import CueSyncCore
import Foundation
import TableSpace

public struct OverlayLayout: Sendable, Equatable {
    public struct Strip: Sendable, Equatable {
        public var ballID: BallID
        /// Strip center in world space, lying on the cloth.
        public var midpoint: Vec3
        public var length: Double
        /// Rotation about the plane normal, radians, measured from the
        /// table-space +x axis to the strip direction.
        public var angle: Double
        public var dashed: Bool
        public var color: UInt32 // 0xRRGGBB token value
    }

    public struct Marker: Sendable, Equatable {
        public var position: Vec3
        public var radius: Double
    }

    public var strips: [Strip]
    public var ghostBall: Marker?
    public var highlightedPockets: [Marker]

    /// Colors mirror TableScene's path styling rules (05-UX-DESIGN).
    public static func compose(state: TableState,
                               prediction: ShotPrediction,
                               calibration: TableCalibration,
                               aimColor: UInt32 = 0xF5A623,
                               objectColor: UInt32 = 0x2FA36B,
                               cueAfterColor: UInt32 = 0x4A90D9,
                               scratchColor: UInt32 = 0xE8604C) -> OverlayLayout {
        let cueID = state.cueBall?.id
        let contact = prediction.firstContact?.contact
        let cueScratched = cueID.map { prediction.pocketedBalls.contains($0) } ?? false

        var seenContact = false
        let strips = prediction.segments.compactMap { segment -> Strip? in
            let vector = segment.end - segment.start
            guard vector.length > 1e-6 else { return nil }
            let isCue = segment.ballID == cueID
            let afterContact: Bool
            if isCue, let contact {
                if seenContact {
                    afterContact = true
                } else if segment.end == contact {
                    seenContact = true
                    afterContact = false
                } else {
                    afterContact = false
                }
            } else {
                afterContact = false
            }

            let color: UInt32
            let dashed: Bool
            if isCue {
                if afterContact {
                    color = cueScratched ? scratchColor : cueAfterColor
                    dashed = true
                } else {
                    color = aimColor
                    dashed = false
                }
            } else {
                color = objectColor
                dashed = false
            }

            let mid = (segment.start + segment.end) * 0.5
            return Strip(ballID: segment.ballID,
                         midpoint: calibration.tableToWorld(mid),
                         length: vector.length,
                         angle: atan2(vector.y, vector.x),
                         dashed: dashed,
                         color: color)
        }

        var ghost: Marker?
        if let contact = prediction.firstContact?.contact {
            let radius = state.cueBall?.radius ?? Ball.standardRadius
            ghost = Marker(position: calibration.tableToWorld(contact), radius: radius)
        }

        var litPockets: Set<PocketID> = []
        for event in prediction.events {
            if case let .pocket(_, pocket) = event { litPockets.insert(pocket) }
        }
        let highlights = state.table.pockets
            .filter { litPockets.contains($0.id) }
            .map { Marker(position: calibration.tableToWorld($0.position),
                          radius: $0.captureRadius) }

        return OverlayLayout(strips: strips, ghostBall: ghost,
                             highlightedPockets: highlights)
    }
}
