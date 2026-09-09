//
//  SessionModel+MirrorState.swift
//  CueSync AR
//
//  The `/state.json` payload the debug mirror serves — moved out of
//  SessionModel.swift (SwiftLint file_length) when the recording block
//  joined it. Read-only over the model; nothing here mutates state.
//

import CoachKit
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
            // Sticky tap instrumentation — see SessionModel.noteRawTap.
            "rawTapCount": rawTapCount,
            "rootTapCount": rootTapCount,
            "tapCatcherMounted": tapCatcherMounted,
            "lastTapNote": lastTapNote ?? "",

            "aimSource": String(describing: aimSource),
            "calledShotOnLine": calledShotOnLine,
            // The HUD capsule's text. `/frame.jpg` is an ARView snapshot
            // with no SwiftUI in it, so this is the only way to read the
            // HUD from a browser.
            "hudStatus": hudStatusLabel
        ]
        // Whether the cue the detector can see has been sitting still long
        // enough to be furniture rather than an aim.
        state["stickResting"] = shotPlanner.stickIsResting
        // Why nothing is drawn, when nothing is drawn.
        if let noGuideReason { state["noGuideReason"] = noGuideReason }
        // How long the aim source has held. A source that flips every
        // second is the "guides move in weird formations" symptom as a
        // number rather than an impression.
        if let run = aimSourceRunSeconds {
            state["aimSourceRunSeconds"] = (run * 10).rounded() / 10
        }
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
            state["balls"] = balls.map(mirrorBallEntry)
        }
        if let fit = lastPocketFit {
            // Sticky: the number that says whether the calibration can be
            // trusted must outlive the 2.5 s toast that announced it.
            state["pocketFit"] = fit
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
        // Spoken guidance: the level, whether it is talking right now, and
        // the last line said. Without the last line there is no way to tell
        // "the voice is off" from "the voice is on and had nothing to say".
        state["speech"] = speechMirrorState()
        // B3 anchor following: the A/B switch and how far the table anchor
        // has moved since lock — the measurement the next table run reads.
        state["followsTableAnchor"] = followsTableAnchor
        state["calibrationState"] = String(describing: calibration.state).prefix(40).description
        if let plane = estimateClothPlane() {
            state["clothFromBalls"] = [
                "height": (plane.height * 1000).rounded() / 1000,
                "samples": plane.sampleCount,
                "spreadMm": Int((plane.spread * 1000).rounded()),
                "nearestM": (plane.nearestRange * 100).rounded() / 100,
                "furthestM": (plane.furthestRange * 100).rounded() / 100
            ]
        }
        state["pendingCorners"] = pendingCorners.count
        if let cal = tableCalibration {
            let field = cal.size.playField
            let comparison = cal.standardSizeComparison
            state["calibration"] = [
                "widthM": (field.width * 1000).rounded() / 1000,
                "heightM": (field.height * 1000).rounded() / 1000,
                "sizeName": String(describing: cal.size),
                "vsStandard": comparison.summary,
                "maxDeltaMm": Int((comparison.maxDelta * 1000).rounded()),
                "corners": cal.worldCorners.map {
                    [($0.x * 1000).rounded() / 1000,
                     ($0.y * 1000).rounded() / 1000,
                     ($0.z * 1000).rounded() / 1000]
                }
            ]
        }
        if let anchorDriftMillimeters {
            state["anchorDriftMm"] = (anchorDriftMillimeters * 10).rounded() / 10
        }
        state["mode"] = practiceMode.rawValue
        state["settings"] = settingsMirrorState()
        state["hasPrediction"] = shotPrediction != nil
        if let prediction = shotPrediction, !prediction.segments.isEmpty {
            state["prediction"] = Self.predictionMirrorState(prediction)
            // Length and event count size the guide directly: a 5 m,
            // 10-segment polyline is the thing that sweeps metres across
            // the cloth when the aim moves a degree.
            let length = prediction.segments.reduce(0.0) {
                $0 + $1.start.distance(to: $1.end)
            }
            state["predictionLengthM"] = (length * 100).rounded() / 100
            state["predictionEvents"] = prediction.events.count
            state["predictionSegments"] = prediction.segments.count
        }
        state["ranking"] = rankingMirrorState()
        state["recording"] = recordingMirrorState()
        if let calledPocket { state["calledPocket"] = String(describing: calledPocket) }
        if let sessionEvent { state["sessionEvent"] = sessionEvent }
        if let error = previewStats.lastError { state["lastError"] = error }
        if let tapFeedback { state["tapFeedback"] = tapFeedback }
        return try? JSONSerialization.data(withJSONObject: state,
                                           options: [.sortedKeys])
    }

    /// One ball's row in `/state.json`.
    ///
    /// Split out of `mirrorStateJSON` because it publishes the
    /// classifier's working, not just its answer: at the table the
    /// useful question is never "what did it say" but "on how many
    /// looks, and how close was the runner-up".
    private func mirrorBallEntry(_ ball: Ball) -> [String: Any] {
        var entry: [String: Any] = [
            "id": ball.id.rawValue,
            "kind": String(describing: ball.kind),
            "x": (ball.position.x * 100).rounded() / 100,
            "y": (ball.position.y * 100).rounded() / 100,
            "confidence": (ball.confidence * 100).rounded() / 100
        ]
        if let group = ballIdentity.group(for: ball.id) {
            entry["group"] = group.rawValue
        }
        if let colour = ballIdentity.family(for: ball.id) {
            entry["colour"] = colour.family.rawValue
            entry["colourConfidence"] = (colour.confidence * 100).rounded() / 100
        }
        if let record = ballIdentity.record(for: ball.id) {
            entry["looks"] = record.observations.count
            if let spread = record.peakHueSpread {
                entry["hueSpread"] = (spread * 10).rounded() / 10
            }
            entry["peakWhite"] = (record.peakWhiteFraction * 100).rounded() / 100
            if record.override != nil { entry["corrected"] = true }
        }
        entry["tentative"] = ballIdentity.isTentative(for: ball.id)
        return entry
    }

    /// The ranked shots, the app's suggestion and the player's override.
    /// Positions are included so a browser at the table can click a ball
    /// straight into `/cmd?action=target`, without guessing screen points.
    private func rankingMirrorState() -> [String: Any] {
        func cm(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var out: [String: Any] = [
            "group": ballGroup.rawValue,
            "skill": settings.skillLevel.rawValue,
            "playerChose": targetIsPlayerChosen
        ]
        let positions = Dictionary(uniqueKeysWithValues:
            (tableState?.balls ?? []).map { ($0.id, $0.position) })
        out["shots"] = shotRanking.prefix(8).map { rating -> [String: Any] in
            var row: [String: Any] = [
                "ball": rating.ball.rawValue,
                "pocket": rating.pocket.rawValue,
                "percent": rating.percentage,
                "cutDeg": (rating.cutAngleDegrees * 10).rounded() / 10,
                "cueTravelM": cm(rating.cueTravel),
                "objectTravelM": cm(rating.objectTravel),
                "difficulty": rating.difficulty.rawValue
            ]
            if let p = positions[rating.ball] { row["at"] = [cm(p.x), cm(p.y)] }
            if let blocker = rating.blocker { row["blocked"] = String(describing: blocker) }
            return row
        }
        if let active = activeShot {
            var row: [String: Any] = ["ball": active.ball.rawValue,
                                      "pocket": active.pocket.rawValue,
                                      "percent": active.percentage,
                                      "headline": active.headline,
                                      "ghost": [cm(active.ghostBall.x), cm(active.ghostBall.y)]]
            // The gap between where the player is aiming and where they
            // should be: the number this whole feature exists to shrink.
            if let correction = targetCorrection {
                row["correction"] = correction.side ?? "onLine"
                row["advice"] = correction.advice
            }
            if let error = targetAimErrorDegrees { row["aimErrorDeg"] = (error * 10).rounded() / 10 }
            row["planSegments"] = targetOverlay?.prediction.segments.count ?? 0
            out["active"] = row
        }
        return out
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
