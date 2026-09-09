//
//  SessionModel+Speech.swift
//  CueSync AR
//
//  Wiring for spoken guidance: it turns what the app already knows into
//  `CoachKit.SpokenGuidance.Situation`, offers it to the narrator, and
//  exposes the level to Settings and to the debug mirror.
//
//  Nothing is decided here. The words and the silences are the pure type's
//  (Packages/CoachKit/.../SpokenGuidance.swift); the pronunciation is
//  SpeechNarrator's. This file is the translation between the app's
//  vocabulary and theirs, and it is deliberately the ONLY translation —
//  the stage comes straight off the HUD's own status, so the voice cannot
//  develop a private description of the session that the screen disagrees
//  with.
//

import ARExperience
import CoachKit
import CueSyncUI
import Foundation

extension SessionModel {

    // MARK: - Feeding the narrator

    /// The HUD's status, pushed in by RootView (which owns the decision
    /// tree). Kept as the whole value, not just its label, because the
    /// voice needs the same state the capsule is showing.
    func noteHUDStatus(_ status: HUDStatus) {
        hudStatus = status
        hudStatusLabel = status.label
        narrateIfNeeded()
    }

    /// Offer the current situation to the narrator. Called wherever the
    /// situation can change — the HUD status, the ranking, the aim — and
    /// cheap enough to call on every frame: almost every call ends in
    /// silence, decided by `SpokenGuidance`.
    func narrateIfNeeded() {
        guard settings.speechVerbosity.isOn else { return }
        narrator.consider(spokenSituation(), at: clock())
    }

    /// What the voice is being asked to describe.
    private func spokenSituation() -> SpokenGuidance.Situation {
        SpokenGuidance.Situation(
            stage: hudStatus.map(SessionModel.guidanceStage) ?? .starting,
            shot: activeShot,
            chosenByPlayer: targetIsPlayerChosen,
            nudge: targetCorrection.map(SessionModel.aimNudge))
    }

    /// The HUD's status in the voice's terms.
    ///
    /// `.tracking` and `.onLine` both collapse to `.tracking`: the ball
    /// count is not worth saying, and "on line" is decided from the aim
    /// correction rather than the capsule, so that it is said about the
    /// shot the player is actually aiming at.
    static func guidanceStage(_ status: HUDStatus) -> GuidanceStage {
        switch status {
        case .launching: .starting
        case .findingTable: .findingTable
        case .placingCorners(let placed): .placingCorners(placed: placed)
        case .confirmingRails: .confirmingRails
        case .needsCalibration: .needsCalibration
        case .awaitingCueBall: .awaitingCueBall
        case .tracking, .onLine: .tracking
        case .degraded(.fastMotion): .degraded(.fastMotion)
        case .degraded(.lowLight): .degraded(.lowLight)
        case .degraded(.trackingLost): .degraded(.trackingLost)
        }
    }

    /// The aim correction in the voice's terms. Same values, restated so
    /// CoachKit never has to see ARExperience.
    static func aimNudge(_ correction: TargetGuide.Correction) -> AimNudge {
        switch correction {
        case .onLine: .onLine
        case .left(let degrees): .left(degrees: degrees)
        case .right(let degrees): .right(degrees: degrees)
        }
    }

    // MARK: - The level

    /// Push the persisted level into the narrator. Called from
    /// `applySettings`, so Settings, the mirror and a fresh launch all go
    /// through one path.
    func applySpeechSetting() {
        narrator.setVerbosity(settings.speechVerbosity)
    }

    /// Change the level and say so, so the player hears that it worked.
    func setSpeechVerbosity(_ level: SpeechVerbosity) {
        guard settings.speechVerbosity != level else { return }
        updateSettings { $0.speechVerbosity = level }
        showTapFeedback("Voice: \(level.title)")
        // Proof of life. Turning a voice on and hearing nothing until the
        // next shot is indistinguishable from a broken build — this is the
        // same reasoning as the tap-feedback rule.
        if level.isOn { narrator.say("Voice guidance on. \(level.detail)") }
    }

    // MARK: - Debug mirror

    /// Speech commands from the mirror, so the level can be changed and a
    /// line triggered with the device propped at the table and untouched.
    /// Returns false for anything it does not recognise.
    func handleSpeechMirrorCommand(_ params: [String: String]) -> Bool {
        switch params["action"] {
        case "speech":
            guard let raw = params["level"], let level = SpeechVerbosity(rawValue: raw) else {
                return false
            }
            setSpeechVerbosity(level)
            showTapFeedback("Voice: \(level.title) (remote)")
        case "say":
            // The audibility check: does this device actually make a sound,
            // at this volume, over whatever is playing in the room.
            narrator.say(params["text"] ?? "CueSync AR can hear itself think.")
        case "speechStop":
            narrator.stop()
            showTapFeedback("Voice stopped (remote)")
        default:
            return false
        }
        return true
    }

    /// The speech block in `/state.json`.
    func speechMirrorState() -> [String: Any] {
        ["level": settings.speechVerbosity.rawValue,
         "speaking": narrator.isSpeaking,
         "spokenCount": narrator.spokenCount,
         "lastSpoken": narrator.lastSpoken ?? ""]
    }
}
