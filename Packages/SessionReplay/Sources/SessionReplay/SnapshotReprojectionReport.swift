//
//  SnapshotReprojectionReport.swift
//  CueSync AR
//
//  "Do the rings sit on the balls?" — asked offline.
//
//  Row 6 of docs/device-checklist.md names this report as its proxy and it
//  did not exist, so that row could not be scored even with unlimited
//  device time. This is the piece that lets a perception change be judged
//  against a recording instead of against a memory of last night.
//
//  IT MEASURES CONSISTENCY, NOT ACCURACY. It asks whether the overlay's
//  projection of a ball agrees with where the DETECTOR put that ball in the
//  same frame. Both could be wrong together and this report would be
//  happy. Real accuracy needs a tape measure and a truth.json.
//
//  The convention matters and is the reason an earlier version of this
//  number was an artefact: an overlay marker is a CLOTH-CONTACT point,
//  while a detection box is centred on the SPHERE. Comparing them directly
//  measures one ball radius of parallax and calls it error — at 2.47 m
//  that is 15.07 px, which is exactly the "measured" p50 someone once
//  reported. So markers are lifted by one radius along the plane normal
//  before anything is compared.
//

import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

/// How closely the overlay's projection agrees with the detector's boxes.
public struct SnapshotReprojectionReport: Sendable, Equatable {

    /// Marker/box pairs that were close enough to be the same ball.
    public var samples: Int
    /// Markers with no detection near them in that frame. Not an error —
    /// the detector drops balls constantly — but a big number means the
    /// percentiles rest on very little.
    public var unmatched: Int
    /// Pixel distance between the lifted marker's reprojection and the
    /// nearest box centre.
    public var p50: Double
    public var p95: Double
    public var maximum: Double

    /// Stated in the report itself so a number can never be read without
    /// the convention that produced it.
    public var convention: String {
        "marker lifted one ball radius along the plane normal, then reprojected; "
            + "compared to the nearest detection box centre in image pixels"
    }

    public var summary: String {
        guard samples > 0 else { return "reprojection: no matched markers" }
        return String(format: "reprojection: n=%d p50=%.1fpx p95=%.1fpx max=%.1fpx unmatched=%d",
                      samples, p50, p95, maximum, unmatched)
    }

    /// Compute over a whole bundle.
    ///
    /// - Parameter matchRadius: how far a box centre may sit from a lifted
    ///   marker and still be taken for the same ball, in pixels. Generous
    ///   on purpose: a wrong pairing produces a huge distance and would
    ///   dominate the percentiles, so it is better to leave a marker
    ///   unmatched and say so.
    public static func compute(bundle: SessionBundle,
                               ballRadius: Double = Ball.standardRadius,
                               matchRadius: Double = 120) -> SnapshotReprojectionReport {
        guard let calibration = try? bundle.calibration.tableCalibration() else {
            return SnapshotReprojectionReport(samples: 0, unmatched: 0,
                                              p50: 0, p95: 0, maximum: 0)
        }
        let framesByIndex = Dictionary(bundle.frames.map { ($0.index, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let detectionsByIndex = Dictionary(bundle.detections.map { ($0.frame, $0) },
                                           uniquingKeysWith: { first, _ in first })
        let raycaster = PlaneGeometryRaycaster(calibration: calibration)
        var errors: [Double] = []
        var unmatched = 0

        for snapshot in bundle.snapshots {
            guard let meta = framesByIndex[snapshot.frame],
                  let recorded = meta.intrinsics,
                  let frame = try? meta.capturedFrame(),
                  let boxes = detectionsByIndex[snapshot.frame]?.detections
            else { continue }
            let width = recorded.imageWidth
            let height = recorded.imageHeight
            let centres = boxes.compactMap { detection -> Vec2? in
                let value = detection.detection2D
                guard !value.isCueStick else { return nil }
                let box = value.boundingBox
                return Vec2((box.x + box.width / 2) * width,
                            (box.y + box.height / 2) * height)
            }
            guard !centres.isEmpty else { continue }

            for marker in snapshot.markers where marker.kind == "ball" {
                let contact = Vec3(marker.world[0], marker.world[1], marker.world[2])
                // THE LIFT. Without it this whole report measures parallax.
                let centre = contact + calibration.normal * ballRadius
                guard let projected = raycaster.projectToImage(worldPoint: centre,
                                                               frame: frame) else { continue }
                let pixel = Vec2(projected.x * width, projected.y * height)
                let nearest = centres
                    .map { ($0 - pixel).length }
                    .min() ?? .infinity
                if nearest <= matchRadius { errors.append(nearest) } else { unmatched += 1 }
            }
        }

        let sorted = errors.sorted()
        return SnapshotReprojectionReport(
            samples: sorted.count,
            unmatched: unmatched,
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            maximum: sorted.last ?? 0)
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[max(0, min(sorted.count - 1, index))]
    }
}
