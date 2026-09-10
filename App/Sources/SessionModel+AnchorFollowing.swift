//
//  SessionModel+AnchorFollowing.swift
//  CueSync AR
//
//  B3: keep every consumer of the table calibration (perception pipeline,
//  overlay layout, aim, pocket/designation taps, mirror) in the SAME world
//  frame as ARKit's current camera poses. ARKit refines the table anchor
//  as its map improves; a calibration frozen at lock time is then offset
//  from the physical cloth by exactly that refinement. The pipeline
//  re-derives its own copy per frame (PerceptionPipeline.followTableAnchor);
//  this mirrors that for the app layer and records the drift magnitude so
//  a device run can size the effect. Split out of SessionModel.swift for
//  SwiftLint's file_length limit.
//

import CueSyncCore
import Foundation
import TableSpace

extension SessionModel {
    /// Re-express the lock-time calibration in the anchor's current world
    /// frame — the same value the pipeline derives for this frame — and
    /// record how far the anchor has moved since lock. No-op when the
    /// switch is off, no anchor transform is available yet, or nothing is
    /// locked.
    func followTableAnchor(_ transform: Transform3D?) {
        guard followsTableAnchor, let transform, let lock = lockAnchorTransform,
              let locked = calibration.calibration else { return }
        anchorDriftMillimeters = transform.translation.distance(to: lock.translation) * 1000
        let refreshed = AnchoredCalibration(calibration: locked, anchorTransform: lock)
            .worldCalibration(anchorTransform: transform)
        if refreshed != anchorFollowedCalibration { anchorFollowedCalibration = refreshed }
    }

    /// A/B switch for the table: ON re-derives the calibration from the
    /// anchor each tick (default); OFF pins it at lock time (pre-B3). The
    /// pipeline is rebuilt so its config matches — tracks re-acquire in a
    /// few frames; a cue-ball designation must be re-tapped.
    func setFollowsTableAnchor(_ on: Bool) {
        followsTableAnchor = on
        if isLiveTracking { resetBallTracking() }
        Self.log.notice("anchor following \(on ? "ON" : "OFF", privacy: .public) (remote)")
        showRemoteFeedback(on ? "Following table anchor"
                              : "Calibration frozen at lock")
    }
}
