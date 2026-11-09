//
//  ShotAdvisorModel.swift
//  CueSync AR
//
//  State for the shot advisor ("what should I shoot?"): the viable shots for
//  the current layout (CoachKit's ShotPlanner), which one is selected, and
//  the on/off switch. Split out of SessionModel to keep that file small.
//

import CoachKit
import CueSyncCore
import Foundation
import Observation

@MainActor
@Observable
final class ShotAdvisorModel {
    private static let enabledKey = "shotAdvisorEnabled"

    /// Master switch for the advisor overlay + card (persisted, default on).
    private(set) var isEnabled: Bool =
        UserDefaults.standard.object(forKey: "shotAdvisorEnabled") as? Bool ?? true
    /// Viable shots for the current layout, easiest first.
    private(set) var options: [ShotOption] = []
    private(set) var selectedID: String?
    /// True once the player cycled to a specific shot: that choice then
    /// stays until it stops being viable, instead of snapping back to "best".
    @ObservationIgnored private var pinnedByUser = false
    @ObservationIgnored private var lastPlannedState: TableState?

    /// The shot currently being advised (nil: advisor off, no cue ball, or
    /// no viable shot).
    var advised: ShotOption? {
        guard isEnabled, let id = selectedID else { return nil }
        return options.first { $0.id == id }
    }

    /// Flips the switch and returns the message to show the player.
    func toggle() -> String {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        lastPlannedState = nil // force a re-plan when switched back on
        if !isEnabled { clear() }
        return isEnabled ? "Shot advisor on" : "Shot advisor off"
    }

    /// Step to the next-best shot (wraps); pins the choice.
    func cycle() {
        guard options.count > 1,
              let current = options.firstIndex(where: { $0.id == selectedID })
        else { return }
        selectedID = options[(current + 1) % options.count].id
        pinnedByUser = true
    }

    func clear() {
        options = []
        selectedID = nil
        pinnedByUser = false
        lastPlannedState = nil
    }

    /// Re-plan when the ball layout materially changes (planner is cheap:
    /// balls × 6 pockets × balls lane checks).
    func refresh(for state: TableState) {
        guard isEnabled else { return }
        guard SessionModel.layoutMoved(from: lastPlannedState, to: state) else { return }
        lastPlannedState = state
        options = ShotPlanner.plan(state: state)
        if pinnedByUser, let id = selectedID, options.contains(where: { $0.id == id }) {
            return
        }
        pinnedByUser = false
        selectedID = ShotPlanner.select(previous: selectedID, among: options)?.id
    }

    /// Fields merged into the debug mirror's state.json.
    var mirrorState: [String: Any] {
        var fields: [String: Any] = ["shotAdvisorEnabled": isEnabled]
        if let shot = advised {
            fields["advisedShot"] = [
                "title": shot.title,
                "detail": shot.detail,
                "cutDegrees": (shot.cutAngleDegrees * 10).rounded() / 10,
                "difficulty": (shot.difficulty * 100).rounded() / 100,
                "optionCount": options.count
            ] as [String: Any]
        }
        return fields
    }
}
