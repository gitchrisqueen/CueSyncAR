//
//  DetectionProjector.swift
//  PerceptionKit
//
//  Raw detections in, tracker observations out, and a count of what
//  happened to every detection that did not make it.
//
//  Lifted out of `PerceptionPipeline.process` so the drop points can be
//  counted and tested on their own. The rules are exactly the ones the
//  pipeline had inline: a stick is not a ball, a ball under the confidence
//  floor is ignored, a ray that misses the plane is ignored, a position
//  outside the playing-surface band is rejected, anything else is an
//  observation. Only the counting is new.
//

import CueSyncCore
import Foundation
import TableSpace

struct ProjectionResult {
    var observations: [BallObservation] = []
    var located: [LocatedDetection] = []
    var counts = DetectionCounts()
    /// Observations the gate pulled back onto the playing surface.
    var clamped = 0
}

/// What a detector class label means, remembered per label.
///
/// `Detection2D.isCueStick` and `Detection2D.ballKind` parse the label
/// string every call (lowercasing plus five `replacingOccurrences`), about
/// 10 to 20 microseconds each. The projector used to call `ballKind` twice
/// per detection, and that parsing was the largest per-ball cost after
/// detection (measured: PipelineCostBenchmarkTests). The same few labels
/// repeat every frame, so each is parsed once, by the very same two
/// properties, so the answer cannot differ from the uncached one.
struct LabelCache {
    struct Info {
        var isStick: Bool
        var kind: Ball.Kind
    }

    /// A model has a handful of classes. The bound only matters to a
    /// provider that invents labels, and it keeps the cache from growing.
    private static let limit = 64
    private var entries: [String: Info] = [:]

    mutating func info(for detection: Detection2D) -> Info {
        if let known = entries[detection.classLabel] { return known }
        let info = Info(isStick: detection.isCueStick, kind: detection.ballKind)
        if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[detection.classLabel] = info
        return info
    }
}

struct DetectionProjector {
    let raycaster: any PlaneRaycasting
    let calibration: TableCalibration
    let surface: PlayingSurfaceGate

    /// Project one frame's detections.
    ///
    /// Locates each ball by its SPHERE CENTER: box center ray, plane lifted
    /// one ball radius, dropped to cloth. The box FOOT point is biased
    /// short (boxes include the contact shadow) and the bias direction
    /// follows the camera.
    func project(_ detections: [Detection2D],
                 frame: CapturedFrame,
                 confidenceFloor: Double,
                 labels: inout LabelCache) -> ProjectionResult {
        var result = ProjectionResult()
        result.counts.rawCount = detections.count
        result.counts.confidenceFloor = confidenceFloor
        var tablePositions: [Vec2?] = []
        tablePositions.reserveCapacity(detections.count)

        for detection in detections {
            let box = detection.boundingBox
            let center = Vec2(box.x + box.width / 2, box.y + box.height / 2)
            let world = raycaster.raycastToTablePlane(
                imagePoint: center, frame: frame, planeHeightOffset: Ball.standardRadius)
            let table = world.map(calibration.worldToTable)
            tablePositions.append(table)

            let label = labels.info(for: detection)
            // Cue-stick detections are not balls — feeding them to the
            // tracker corrupts the cue-ball estimate (stick boxes span half
            // the table). They drive stick-based aiming instead.
            if label.isStick {
                result.counts.stickCount += 1
                continue
            }
            guard detection.confidence >= confidenceFloor else {
                result.counts.belowFloor += 1
                result.counts.belowFloorByLabel[detection.classLabel, default: 0] += 1
                let best = result.counts.maxSubFloorConfidence ?? -Double.infinity
                result.counts.maxSubFloorConfidence = Swift.max(best, detection.confidence)
                continue
            }
            guard let table else {
                result.counts.noRay += 1
                continue
            }
            // Playing-surface gate: a detection whose box is clipped by the
            // frame edge, or that matches something OFF the table (window
            // reflections, balls on a shelf), unprojects to a point far
            // outside the cloth. A ball CAN sit against a cushion with its
            // centre one radius inside the nose line, and calibration is
            // never exact, so the gate admits a small band beyond that and
            // pulls those observations back onto it. Anything further is
            // not a ball on this table and must never seed a track.
            guard let position = surface.admit(table) else {
                result.counts.rejected += 1
                continue
            }
            result.counts.projected += 1
            if position != table { result.clamped += 1 }
            result.located.append(LocatedDetection(position: position, box: box,
                                                   kind: label.kind))
            result.observations.append(BallObservation(kind: label.kind,
                                                       position: position,
                                                       confidence: detection.confidence))
        }
        result.counts.rawLabelsAll = Self.rawEntries(detections, tablePositions: tablePositions)
        return result
    }

    /// Every detection as a number-only entry, in a TOTAL order
    /// (confidence desc, label asc, detector order asc) so equal
    /// confidences never depend on sort stability.
    private static func rawEntries(_ detections: [Detection2D],
                                   tablePositions: [Vec2?]) -> [RawDetectionEntry] {
        detections.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.confidence != rhs.element.confidence {
                    return lhs.element.confidence > rhs.element.confidence
                }
                if lhs.element.classLabel != rhs.element.classLabel {
                    return lhs.element.classLabel < rhs.element.classLabel
                }
                return lhs.offset < rhs.offset
            }
            .map { index, detection in
                RawDetectionEntry(label: detection.classLabel,
                                  confidence: Self.roundedConfidence(detection.confidence),
                                  tableCentimetres: Self.centimetres(tablePositions[index]))
            }
    }

    private static func roundedConfidence(_ value: Double) -> Double {
        value.isFinite ? (value * 100).rounded() / 100 : 0
    }

    /// Whole centimetres, or nil for a position that is not a finite
    /// number: `/state.json` goes through JSONSerialization, which traps
    /// on NaN, and `Int(_:)` traps on it too.
    private static func centimetres(_ position: Vec2?) -> (x: Int, y: Int)? {
        guard let position, position.x.isFinite, position.y.isFinite,
              abs(position.x) < 1e6, abs(position.y) < 1e6 else { return nil }
        return (Int((position.x * 100).rounded()), Int((position.y * 100).rounded()))
    }
}
