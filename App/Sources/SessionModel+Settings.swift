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

import ARExperience
import BilliardsPhysics
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
        applySpeechSetting()
        // Guide speed feeds the solver: force a re-solve so a new speed
        // shows up even when the aim itself sits inside the deadband.
        shotPlanner.guideSpeed = settings.guideSpeed
        shotPlanner.invalidate()
        // `ShotPlanner.config` is immutable, so a parked-mode change means a
        // fresh planner. Only on an actual change: rebuilding drops the
        // current plan and the stick hold with it.
        if previous == nil || previous?.deviceParked != settings.deviceParked {
            rebuildShotPlanner()
        }
        if let previous, isLiveTracking,
           settings.requiresPipelineRestart(comparedTo: previous) {
            resetBallTracking()
        }
    }

    /// Rebuild the planner around the current settings, preserving the
    /// guide speed. Parked mode lives in `AimResolver.Config`, which the
    /// planner holds as a `let`.
    func rebuildShotPlanner() {
        let resolver = AimResolver.Config(allowDevicePose: !settings.deviceParked)
        shotPlanner = ShotPlanner(
            solver: AnalyticSolver(),
            guideSpeed: settings.guideSpeed,
            config: ShotPlanner.Config(resolver: resolver))
    }

    /// Tracker tuning derived from settings.
    ///
    /// `visibleMissGrace` — how long a ball that is in view but undetected
    /// keeps its track — is the knob this exists for. It landed in
    /// `TrackerConfig` with #7; the wiring below is what was missing, so
    /// the Settings slider and the mirror's `missGrace` command moved a
    /// number that nothing read.
    func trackerConfigFromSettings() -> TrackerConfig {
        var config = TrackerConfig.default
        config.visibleMissGrace = settings.visibleMissGrace
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
        payload["effectiveDetection"] = effectiveDetectionProviderKey
        payload["hostedDetectionAvailable"] = hasRoboflowKey
        // Kept as a positive assertion rather than deleted: the mirror
        // said `false` for long enough that a reader should see it flip.
        payload["visibleMissGraceConnected"] = true
        return payload
    }

    /// True when the hosted adapter can actually be used (key present).
    var canUseHostedDetection: Bool { hasRoboflowKey }

    /// What live tracking is running on right now, in words.
    /// For `/state.json`: a stable machine key a script can match on.
    /// Deliberately the raw value, and deliberately not shown to anyone.
    var effectiveDetectionProviderKey: String {
        guard isLiveTracking else { return "idle" }
        return usingOnDeviceDetection
            ? DetectionProviderSetting.onDevice.rawValue
            : DetectionProviderSetting.hosted.rawValue
    }

    /// For the Settings sheet. One value used to serve both jobs, so the
    /// row read "Running on: onDevice" — a raw enum case, two rows under
    /// the same enum rendered correctly as "On-device (bundled)".
    var effectiveDetectionProviderTitle: String {
        guard isLiveTracking else { return "Not running" }
        return usingOnDeviceDetection
            ? DetectionProviderSetting.onDevice.title
            : DetectionProviderSetting.hosted.title
    }
}
