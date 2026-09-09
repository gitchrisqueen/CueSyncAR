//
//  HUDControlBar.swift
//  CueSync AR
//
//  The bottom bar, after the split. It carried nine controls — camera
//  flip, calibrate, debug mirror, record, practice-mode menu, ball group,
//  model picker, settings gear, a latency readout and a box-rotation nudge
//  — seven of them icon-only, four of them there to serve development
//  rather than play. A player looking for "how do I start?" had to read a
//  row of unlabelled glyphs and guess.
//
//  What is left is what a person at a table actually does: say where the
//  table is, say how they are practising, and get at everything else. The
//  developer instruments are not deleted — they move to the More sheet and
//  Settings → Developer, and every one of them keeps its /cmd route on the
//  debug mirror.
//

import CoachKit
import CueSyncUI
import SwiftUI

/// Whether the record button is pinned in the HUD.
///
/// It is a development instrument, but it is used *at the table under time
/// pressure* — burying it two sheets deep will cost a session someday. So
/// it stays out by default in debug builds and is off by default in
/// release, with a toggle in Settings → Developer either way.
enum HUDPins {
    static let recordButtonKey = "showRecordButtonInHUD"

    static var recordButtonDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Three controls (four while a shot is live), all labelled.
struct HUDControlBar: View {
    @Environment(SessionModel.self) private var model
    @AppStorage(HUDPins.recordButtonKey) private var showRecordButton = HUDPins.recordButtonDefault
    /// Opens the More sheet. Owned by RootView, which owns sheet state.
    let onMore: () -> Void

    var body: some View {
        HUDBar {
            if model.usingFrontCamera {
                backCameraButton
            } else {
                tableButton
            }
            sessionButton
            // Only while there is a rack to have a half of: outside live
            // tracking the group changes nothing anyone can see. It is
            // also in Settings → Practice, so it is never unreachable.
            if model.isLiveTracking {
                BallGroupButton()
            }
            if showRecordButton, !model.usingFrontCamera {
                RecordButton()
            }
            moreButton
        }
    }

    /// Enters (or re-enters) the calibration flow; shows the locked table
    /// size once calibrated (tappable to recalibrate — 05-UX-DESIGN).
    /// Labelled, not a dashed-rectangle glyph: on a cold table this is the
    /// only thing the player needs to press.
    private var tableButton: some View {
        Button {
            if model.calibrationVisible {
                model.cancelCalibration()
            } else {
                model.beginCalibration()
            }
        } label: {
            if let size = model.tableCalibration?.size {
                Label(RootView.sizeBadge(for: size), systemImage: "checkmark.rectangle")
                    .font(.footnote.weight(.semibold))
            } else {
                Label("Set up table", systemImage: "rectangle.dashed")
                    .font(.footnote.weight(.semibold))
            }
        }
        .accessibilityLabel(model.tableCalibration == nil
                            ? "Set up table"
                            : "Table calibrated — tap to set it up again")
        .accessibilityIdentifier("calibrate-button")
    }

    /// The way back from the front-camera detection preview.
    ///
    /// The flip itself is a developer control and lives in Settings now —
    /// but a mode you can enter must be a mode you can leave without
    /// hunting through a sheet, and the front preview suspends the AR
    /// session, so leaving it is urgent in a way entering it never is.
    private var backCameraButton: some View {
        Button {
            model.setUsingFrontCamera(false)
        } label: {
            Label("Back camera", systemImage: "arrow.uturn.backward.circle")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityLabel("Return to the back camera and the AR session")
        .accessibilityIdentifier("camera-flip-button")
    }

    /// Practice mode (M6-01), with its name on it. Same menu as before —
    /// it was `figure.billiards`, an icon whose meaning was "billiards",
    /// which is not a distinction on this screen.
    private var sessionButton: some View {
        Menu {
            ForEach(PracticeMode.allCases, id: \.rawValue) { mode in
                Button {
                    model.selectPracticeMode(mode)
                } label: {
                    if model.practiceMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label(model.practiceMode.title, systemImage: "figure.billiards")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityLabel("Practice mode: \(model.practiceMode.title)")
        .accessibilityIdentifier("practice-mode-menu")
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("More — settings and developer tools")
        .accessibilityIdentifier("more-button")
    }
}
