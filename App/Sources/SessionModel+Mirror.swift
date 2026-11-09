//
//  SessionModel+Mirror.swift
//  CueSync AR
//
//  Debug-mirror state snapshot (state.json), split out of SessionModel to
//  keep that file under the SwiftLint length limits.
//

import CueSyncCore
import Foundation

extension SessionModel {
    /// JSON for `GET /state.json` on the debug mirror.
    func mirrorStateJSON() -> Data? {
        var state: [String: Any] = [
            "liveTracking": isLiveTracking,
            "onDeviceDetection": usingOnDeviceDetection,
            "calibrationLocked": calibration.isLocked,
            "designatedCueBall": designatedCueBallID != nil,
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
        state.merge(advisor.mirrorState) { _, new in new }
        if !latestDetectionLabels.isEmpty {
            state["rawDetections"] = latestDetectionLabels
        }
        if let pockets = tableState?.table.pockets {
            state["pockets"] = pockets.map { String(describing: $0.id) }
        }
        state["guideSpeed"] = guideSpeed
        state["mode"] = practiceMode.rawValue
        state["hasPrediction"] = shotPrediction != nil
        if let prediction = shotPrediction, !prediction.segments.isEmpty {
            // Predicted path + events in table space — makes bank-line
            // ground truth (T1.1) numerically loggable from the mirror,
            // no eyeballing the rendered frame. Rounded to cm.
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
            state["prediction"] = predictionDict
        }
        if let calledPocket { state["calledPocket"] = String(describing: calledPocket) }
        if let sessionEvent { state["sessionEvent"] = sessionEvent }
        if let error = previewStats.lastError { state["lastError"] = error }
        if let tapFeedback { state["tapFeedback"] = tapFeedback }
        return try? JSONSerialization.data(withJSONObject: state,
                                           options: [.sortedKeys])
    }
}
