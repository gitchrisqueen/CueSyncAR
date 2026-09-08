//
//  SessionModel+Settings.swift
//  CueSync AR
//
//  M4-04: the app-side wiring for CoachKit's `SettingsModel`. All of the
//  persistence, ranges, defaults and corrupt-store handling live in the
//  package (tested on Linux); this file is only the plumbing that stores a
//  change, applies it to the running session, and publishes it to the
//  debug mirror.
//

import CoachKit
import Foundation
import PerceptionKit

/// Where settings live on device. `SettingsModel` owns the key names —
/// including `debugMirrorEnabled` and `practiceMode`, which the HUD has
/// been writing since M3/M6-01, so existing installs keep their choices.
let appSettingsStore = UserDefaultsSettingsStore()

extension SessionModel {
    /// Mutate, persist, and apply settings in one step. This is the ONLY
    /// supported way to change a setting: writing `settings` directly
    /// would leave the store and the running session behind.
    ///
    /// - Parameter mutate: applied to a copy; validation (clamping) runs
    ///   inside `SettingsModel`, so the closure may pass raw slider or
    ///   remote-command values straight through.
    func updateSettings(_ mutate: (inout SettingsModel) -> Void) {
        let previous = settings
        var updated = settings
        mutate(&updated)
        guard updated != previous else { return }
        settings = updated
        updated.persist(to: appSettingsStore)
        applySettings(previous: previous)
    }

    /// Push the current settings into the running session.
    ///
    /// - Parameter previous: the settings in force before the change, used
    ///   to decide whether the perception pipeline has to be rebuilt (a
    ///   detector swap or tracker retune) rather than merely re-read. Pass
    ///   nil to apply without restarting anything.
    func applySettings(previous: SettingsModel? = nil) {
        applyDebugMirrorSetting()
        // Guide speed feeds the solver: force a re-solve so a new speed
        // shows up even when the aim itself sits inside the deadband.
        shotPlanner.guideSpeed = settings.guideSpeed
        shotPlanner.invalidate()
        if let previous, isLiveTracking,
           settings.requiresPipelineRestart(comparedTo: previous) {
            resetBallTracking()
        }
    }

    /// Tracker tuning derived from settings.
    ///
    /// `visibleMissGrace` — how long a ball that is in view but undetected
    /// keeps its track — is the knob this exists for, but the matching
    /// `TrackerConfig` property is still in flight in PerceptionKit (branch
    /// `claude/B1-phantom-track`, not yet on `main`). The setting is
    /// exposed, persisted and mirrored today; connecting it is the single
    /// commented line below.
    func trackerConfigFromSettings() -> TrackerConfig {
        let config = TrackerConfig.default
        // CONNECT ME once TrackerConfig has `visibleMissGrace` (make the
        // binding above `var`):
        // config.visibleMissGrace = settings.visibleMissGrace
        return config
    }

    /// The settings block served in the mirror's `/state.json`, so the
    /// owner can confirm from a browser that a change took effect while
    /// the device stays propped at the table.
    func settingsMirrorState() -> [String: Any] {
        var payload: [String: Any] = [:]
        for (key, value) in settings.snapshot {
            switch value {
            case .bool(let flag): payload[key] = flag
            case .double(let number): payload[key] = (number * 100).rounded() / 100
            case .string(let text): payload[key] = text
            }
        }
        // What the session actually resolved to, which can differ from the
        // request: the hosted adapter needs a key AND a selected model.
        payload["effectiveDetection"] = effectiveDetectionProviderTitle
        payload["hostedDetectionAvailable"] = hasRoboflowKey
        // Restated plainly: the tracker knob is not connected yet.
        payload["visibleMissGraceConnected"] = false
        return payload
    }

    /// True when the hosted adapter can actually be used (key present).
    var canUseHostedDetection: Bool { hasRoboflowKey }

    /// What live tracking is running on right now, in words.
    var effectiveDetectionProviderTitle: String {
        guard isLiveTracking else { return "idle" }
        return usingOnDeviceDetection
            ? DetectionProviderSetting.onDevice.rawValue
            : DetectionProviderSetting.hosted.rawValue
    }
}
