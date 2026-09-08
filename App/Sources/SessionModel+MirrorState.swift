//
//  SessionModel+MirrorState.swift
//  CueSync AR
//
//  The `/state.json` payload the debug mirror serves — moved out of
//  SessionModel.swift (SwiftLint file_length) when the recording block
//  joined it. Read-only over the model; nothing here mutates state.
//

import CueSyncCore
import Foundation

extension SessionModel {
    func mirrorStateJSON() -> Data? {
        var state: [String: Any] = [
            "build": AppBuild.json,
            // T1.3: which compute units the bundled detector loaded with,
            // and whether the Neural Engine probe passed, fell back, or
            // was never attempted (see SessionModel+Providers.swift).
            "detectorCompute": DetectorCompute.mirrorState,
            "liveTracking": isLiveTracking,
            "onDeviceDetection": usingOnDeviceDetection,
            "calibrationLocked": calibration.isLocked,
            "designatedCueBall": designatedCueBallID != nil,
            // Which surface is on top and therefore receiving taps. When
            // the calibration overlay is visible it covers the whole
            // screen, and its tap handler ignores everything unless the
            // flow is in .planeFound — so a stuck `true` here silently
            // swallows every pocket call and cue-ball designation.
            "calibrationVisible": calibrationVisible,

            "aimSource": String(describing: aimSource),
            "calledShotOnLine": calledShotOnLine
        ]
        if let calibration = tableCalibration {
            let size = calibration.size
            state["tableSize"] = String(format: "%.2f x %.2f m",
                                        size.playField.width, size.playField.height)
            state["sizeVsStandard"] = calibration.standardSizeComparison.summary
        }
        if let relocalizationSeconds {
            state["relocalizationSeconds"] = (relocalizationSeconds * 10).rounded() / 10
        }
        if let diag = frameDiagnostics {
            state["frameDiag"] = [
                "seen": diag.framesSeen,
                "delivered": diag.framesDelivered,
                "copyFailures": diag.copyFailures,
                "snapshots": diag.snapshotsCompleted,
                "snapshotAvgMs": Int(diag.averageSnapshotMilliseconds),
                "snapshotsInFlight": diag.snapshotsInFlight
            ]
        }
        if let balls = tableState?.balls {
            state["ballCount"] = balls.count
            state["balls"] = balls.map { ball -> [String: Any] in
                ["kind": String(describing: ball.kind),
                 "x": (ball.position.x * 100).rounded() / 100,
                 "y": (ball.position.y * 100).rounded() / 100,
                 "confidence": (ball.confidence * 100).rounded() / 100]
            }
        }
        if let quad = stickQuad {
            // Raw stick footprint (table space) — lets a remote observer
            // debug why StickAim accepts/rejects without the Xcode console.
            state["stickQuad"] = quad.map { [($0.x * 100).rounded() / 100,
                                            ($0.y * 100).rounded() / 100] }
        }
        if let guide = shotGuide {
            state["shotGuide"] = guide.headline
        }
        if !latestDetectionLabels.isEmpty {
            state["rawDetections"] = latestDetectionLabels
        }
        if let pockets = tableState?.table.pockets {
            state["pockets"] = pockets.map { String(describing: $0.id) }
        }
        state["guideSpeed"] = guideSpeed
        // B3 anchor following: the A/B switch and how far the table anchor
        // has moved since lock — the measurement the next table run reads.
        state["followsTableAnchor"] = followsTableAnchor
        if let anchorDriftMillimeters {
            state["anchorDriftMm"] = (anchorDriftMillimeters * 10).rounded() / 10
        }
        state["mode"] = practiceMode.rawValue
        state["settings"] = settingsMirrorState()
        state["hasPrediction"] = shotPrediction != nil
        if let prediction = shotPrediction, !prediction.segments.isEmpty {
            state["prediction"] = Self.predictionMirrorState(prediction)
        }
        state["recording"] = recordingMirrorState()
        if let calledPocket { state["calledPocket"] = String(describing: calledPocket) }
        if let sessionEvent { state["sessionEvent"] = sessionEvent }
        if let error = previewStats.lastError { state["lastError"] = error }
        if let tapFeedback { state["tapFeedback"] = tapFeedback }
        return try? JSONSerialization.data(withJSONObject: state,
                                           options: [.sortedKeys])
    }

    /// Predicted path + events in table space — makes bank-line ground
    /// truth (T1.1) numerically loggable from the mirror, no eyeballing
    /// the rendered frame. Rounded to cm.
    private static func predictionMirrorState(_ prediction: ShotPrediction) -> [String: Any] {
        func pt(_ v: Vec2) -> [Double] {
            [(v.x * 100).rounded() / 100, (v.y * 100).rounded() / 100]
        }
        var path = [pt(prediction.segments[0].start)]
        path.append(contentsOf: prediction.segments.map { pt($0.end) })
        var predictionDict: [String: Any] = ["path": path]
        let cushions = prediction.events.compactMap { event -> [Double]? in
            if case .cushion(_, let point) = event { return pt(point) }
            return nil
        }
        if !cushions.isEmpty { predictionDict["cushions"] = cushions }
        if let rest = prediction.events.compactMap({ event -> [Double]? in
            if case .rest(_, let point) = event { return pt(point) }
            return nil
        }).first { predictionDict["rest"] = rest }
        if let pocket = prediction.events.compactMap({ event -> String? in
            if case .pocket(_, let pocket) = event { return String(describing: pocket) }
            return nil
        }).first { predictionDict["pocketed"] = pocket }
        return predictionDict
    }

    /// The recorder as the mirror sees it: what is running, what it has
    /// captured, why it cannot start — and the last finished bundle, so a
    /// browser can confirm a save without a hand on the device.
    private func recordingMirrorState() -> [String: Any] {
        var block: [String: Any] = [
            "active": isRecording,
            "capSeconds": SessionRecorder.capSeconds,
            "sizeSummary": SessionRecorder.sizeSummary
        ]
        if let blocker = recordingBlocker, !isRecording { block["blocker"] = blocker }
        if let status = recordingStatus {
            block["sessionID"] = status.sessionID
            block["frames"] = status.frames
            block["detectionFrames"] = status.detectionFrames
            block["videoFrames"] = status.videoFrames
            block["videoDropped"] = status.videoDropped
            block["snapshots"] = status.snapshots
            block["events"] = status.events
            block["seconds"] = (status.seconds * 10).rounded() / 10
            block["estimatedMB"] = status.estimatedMegabytes.rounded()
            if let error = status.lastError { block["error"] = error }
        }
        if let last = lastRecordingSummary {
            block["last"] = [
                "sessionID": last.sessionID,
                "frames": last.frames,
                "videoFrames": last.videoFrames,
                "videoDropped": last.videoDropped,
                "seconds": (last.seconds * 10).rounded() / 10,
                "bytes": last.bytesOnDisk,
                "stopReason": last.stopReason
            ]
        }
        return block
    }
}
