//
//  SessionModel+PerceptionDiagnostics.swift
//  CueSync AR
//
//  The window onto what the perception pipeline does with each frame, and
//  the one live knob on it: `/cmd?action=confidenceFloor&v=0.25`.
//
//  What is here is wiring. The counting, the stage timing and the command
//  parsing live in PerceptionKit (`PipelineDiagnostics.swift`), where the
//  package tests cover them; this app target has no unit tests.
//
//  Hooks in SessionModel.swift, each one line replaced for one line:
//  - `startLiveTrackingIfReady` passes `Self.perceptionControls` to the
//    pipeline;
//  - the pipeline output loop calls `recomputeRankingTimed(after:)` where it
//    called `recomputeRanking()` (which also signals the overlay to draw,
//    see SessionModel+OverlayTiming);
//  - `handleMirrorCommand` lists `handlePerceptionMirrorCommand`.
//

import ARExperience
import CueSyncCore
import Foundation
import PerceptionKit

extension SessionModel {

    /// Shared with the pipeline actor: the confidence-floor override and the
    /// newest counters and timings. One object for the app's lifetime; the
    /// pipeline clears its readings (not the floor) whenever it is rebuilt.
    static let perceptionControls = PerceptionControls()

    /// `GET /cmd?action=confidenceFloor&v=0.25`: lower or raise the
    /// pipeline's confidence floor on the running pipeline, no rebuild. The
    /// shipped default is 0.35 and `v=default` restores it. Anything outside
    /// 0.05...0.9 is refused and changes nothing.
    ///
    /// Returns false for every other action, so the next handler gets it.
    func handlePerceptionMirrorCommand(_ params: [String: String]) -> Bool {
        guard params["action"] == "confidenceFloor" else { return false }
        switch Self.perceptionControls.applyFloorCommand(params["v"]) {
        case .set(let floor):
            Self.log.notice("confidenceFloor set to \(floor, privacy: .public) by mirror command")
            showRemoteFeedback(String(format: "Confidence floor %.2f (default 0.35)", floor))
        case .cleared:
            Self.log.notice("confidenceFloor override cleared by mirror command")
            showRemoteFeedback("Confidence floor back to 0.35")
        case .refused:
            let given = params["v"] ?? "nothing"
            Self.log.notice("confidenceFloor refused: \(given, privacy: .public)")
            showRemoteFeedback("Confidence floor needs 0.05 to 0.9")
        }
        return true
    }

    /// Re-rank, timing it, and time how long this output took from the
    /// pipeline handing it over to the ranking finishing. Both are main-
    /// actor costs that the pipeline's own stage timings cannot see, and
    /// they are the first suspects when the pipeline rate falls as balls
    /// are added. Behaviour is `recomputeRanking()` plus the timings and the
    /// signal to draw.
    ///
    /// `handoff` is produced -> ranking finished, which is three things: the
    /// wait for the main actor to start the output handler (`hop`, in
    /// `health.latency`), the handler's own work before this call
    /// (`prework`), and the ranking itself (`ranking`).
    func recomputeRankingTimed(after output: PerceptionOutput) {
        let started = ProcessInfo.processInfo.systemUptime
        if let arrived = LatencyLedger.shared.arrivedAt() {
            Self.perceptionControls.noteAppStage("prework", milliseconds: (started - arrived) * 1000)
        }
        recomputeRanking()
        let finished = ProcessInfo.processInfo.systemUptime
        Self.perceptionControls.noteAppStage("ranking", milliseconds: (finished - started) * 1000)
        if let producedAt = output.producedAt {
            Self.perceptionControls.noteAppStage("handoff", milliseconds: (finished - producedAt) * 1000)
        }
        // Draw the overlay for this state now. The signal is consumed after
        // the output handler returns, so the draw sees the whole state: the
        // stick quad and detection labels assigned right after this call.
        Self.overlaySignal.signal()
    }

    /// Extra entries for the `detection` block of `/state.json`: what became
    /// of every raw detection, and the tracker's counters. Empty when no
    /// pipeline is running or it has not finished a frame.
    func perceptionDiagnosticsMirrorEntries() -> [String: Any] {
        guard isLiveTracking, let latest = Self.perceptionControls.latestDiagnostics else { return [:] }
        return latest.mirrorEntries
    }

    /// `health.stageMs`: rolling mean milliseconds per stage. Pipeline
    /// stages are `detect`, `project`, `track`, `appearance`,
    /// `appearanceRun`, `other` and `total`; the app adds `prework`,
    /// `ranking` and `handoff`. Empty when no pipeline is running.
    func perceptionStageMilliseconds() -> [String: Double] {
        guard isLiveTracking else { return [:] }
        return Self.perceptionControls.stageMilliseconds
    }
}
