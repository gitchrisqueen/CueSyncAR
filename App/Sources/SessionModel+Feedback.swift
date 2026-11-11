//
//  SessionModel+Feedback.swift
//  CueSync AR
//
//  Wiring for the arcade feel layer: it reads what the session already
//  knows, hands it to CoachKit's pure watcher and outcome detector, and
//  posts whatever they decide to the FeedbackCenter.
//
//  Two feeds:
//   - a 4 Hz sample of the HUD's own facts (lock, tracking, ball count, the
//     shot on offer), debounced by `FeedbackWatcher`;
//   - every tracked frame, from `recomputeRanking`, into
//     `ShotOutcomeDetector`, which decides made / missed / scratch.
//
//  Nothing is decided here.
//

import CoachKit
import CueSyncCore
import Foundation

extension SessionModel {

    var feedbackPrefs: FeedbackCenter.Prefs {
        .init(sounds: settings.soundsEnabled, haptics: settings.hapticsEnabled)
    }

    /// Post one event through the throttle, with the player's settings.
    func postFeedback(_ event: FeedbackEvent, detail: String? = nil, force: Bool = false) {
        let speak: ((String) -> Void)? = settings.speechVerbosity.isOn ? { [narrator] in narrator.say($0) } : nil
        feedback.post(event, detail: detail, now: clock(), prefs: feedbackPrefs,
                      speak: speak, voiceBusy: narrator.isSpeaking, force: force)
    }

    // MARK: - The 4 Hz sample

    /// Start the sampler. Idempotent; called once at launch.
    func startFeedbackSampling() {
        feedback.startSampling { [weak self] in self?.feedbackTick() }
    }

    func feedbackTick() {
        for item in feedback.ingest(feedbackObservation()) {
            var detail = item.detail
            if item.event == .tableLocked {
                detail = tableCalibration.map { RootView.sizeBadge(for: $0.size) }
                feedback.resetScore() // a new table lock is a new session
                feedback.resetShotTracking()
            }
            postFeedback(item.event, detail: detail)
        }
    }

    func feedbackObservation() -> FeedbackObservation {
        FeedbackObservation(
            time: clock(),
            locked: calibration.isLocked,
            refusal: calibrationVisible ? calibration.lastError.map { String(describing: $0) } : nil,
            live: isLiveTracking,
            degraded: trackingCondition.degradedReason != nil,
            ballCount: tableState?.balls.count ?? 0,
            shot: activeShot.map { "\($0.ball.rawValue).\($0.pocket.rawValue)" },
            shotChosenByPlayer: targetIsPlayerChosen,
            noCleanShot: shotEmptyState == .noCleanShot,
            recording: isRecording)
    }

    // MARK: - Every frame: did the shot go in?

    /// Feed one tracked frame to the outcome detector. Called from
    /// `recomputeRanking`, which runs on every pipeline output.
    func noteShotFrame(_ state: TableState) {
        guard feedback.shouldFeed(timestamp: state.timestamp) else { return }
        let advised = activeShot.flatMap {
            $0.blocker == nil ? AdvisedShot(ball: $0.ball, pocket: $0.pocket) : nil
        }
        if let advised, feedback.advisedName?.id != advised.ball {
            feedback.advisedName = (advised.ball, ballName(for: advised.ball))
        }
        let wasInFlight = feedback.detector.isShotInFlight
        let outcome = feedback.detector.observe(state, advised: advised)
        if !wasInFlight, feedback.detector.isShotInFlight {
            // The shot is on its way: the outcome is a second or more off,
            // time enough to wake the Taptic Engine and the sound engine.
            feedback.warm(voiceBusy: narrator.isSpeaking)
        }
        guard let outcome else { return }
        noteShotOutcome(outcome)
    }

    func noteShotOutcome(_ outcome: ShotOutcome) {
        var detail: String?
        var pocket: PocketID?
        switch outcome {
        case .madeAsAdvised(let ball, let into), .madeOther(let ball, let into):
            pocket = into
            detail = feedback.advisedName.flatMap { $0.id == ball ? $0.name : nil }
        case .scratch(let into):
            pocket = into
        case .missed:
            break
        }
        Self.log.info("shot outcome: \(String(describing: outcome), privacy: .public)")
        feedback.recordOutcome(outcome, pocket: pocket)
        postFeedback(outcome.event, detail: detail)
    }

    // MARK: - Settings

    /// Proof of life when sounds are switched on.
    func previewFeedbackSound() {
        feedback.previewSound(.lock, voiceBusy: narrator.isSpeaking)
    }

    // MARK: - Debug mirror

    /// `feedbackPrefs`: sounds / haptics / scoreboard = 0 or 1. And
    /// `feedbackScoreReset`. True when the action was one of these.
    func handleFeedbackMirrorCommand(_ params: [String: String]) -> Bool {
        switch params["action"] {
        case "feedbackPrefs":
            updateSettings {
                if let v = params["sounds"].flatMap(Int.init) { $0.soundsEnabled = v != 0 }
                if let v = params["haptics"].flatMap(Int.init) { $0.hapticsEnabled = v != 0 }
                if let v = params["scoreboard"].flatMap(Int.init) { $0.showScoreboard = v != 0 }
            }
        case "feedbackScoreReset":
            feedback.resetScore()
        default:
            return false
        }
        return true
    }

    /// The `feedback` block in /state.json.
    func feedbackMirrorState() -> [String: Any] {
        var state = feedback.mirrorState(prefs: feedbackPrefs)
        state["scoreboard"] = settings.showScoreboard
        return state
    }
}
