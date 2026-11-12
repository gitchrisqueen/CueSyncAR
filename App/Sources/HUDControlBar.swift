//
//  HUDControlBar.swift
//  CueSync AR
//
//  The bottom bar, after two splits. It carried nine controls — camera
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
//  The second split: "8-ft", "Free play" and "Open" were three bare words
//  in the same weight as the icon buttons, so none of them read as state
//  and none as a button. They are now one grey sentence, and the two real
//  buttons carry words ("Record", "More").
//

import CoachKit
import CueSyncCore
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

/// One quiet grey state line and two labelled buttons.
///
///     8 ft · Free play · Any group          [Record]  [More]
///
/// The state line is a menu (table, practice mode, ball group), so the
/// things the three bare words used to be are still one tap away, but it
/// reads as a sentence, not as three controls. Until a table is locked a
/// "Set up table" button comes first, because that is the only thing a
/// player needs to press then. Every button is at least 44 pt tall
/// (`HUDBarButtonStyle`).
struct HUDControlBar: View {
    @Environment(SessionModel.self) private var model
    @AppStorage(HUDPins.recordButtonKey) private var showRecordButton = HUDPins.recordButtonDefault
    /// Opens the More sheet. Owned by RootView, which owns sheet state.
    let onMore: () -> Void

    /// "8 ft · Free play · Any group". The table part is left out until a
    /// table is locked.
    private var stateText: String {
        HUDCopy.stateLine(table: model.tableCalibration.map { Self.sizeName(for: $0.size) },
                          practice: model.practiceMode.title,
                          group: model.ballGroup == .any ? nil : model.ballGroup.label)
    }

    var body: some View {
        HUDBottomBar {
            HStack(spacing: 12) {
                if model.usingFrontCamera {
                    backCameraButton
                } else {
                    if model.tableCalibration == nil || model.calibrationVisible {
                        setUpTableButton
                    }
                    stateMenu
                }
            }
        } buttons: {
            HStack(spacing: 12) {
                if showRecordButton, !model.usingFrontCamera {
                    RecordButton(labelled: true)
                }
                moreButton
            }
            .buttonStyle(HUDBarButtonStyle())
        }
    }

    /// "8 ft" for the three standard sizes, "2.2×1.1 m" for a custom one.
    static func sizeName(for size: TableSize) -> String {
        switch size {
        case .sevenFoot: HUDCopy.tableSizeName(feet: 7)
        case .eightFoot: HUDCopy.tableSizeName(feet: 8)
        case .nineFoot: HUDCopy.tableSizeName(feet: 9)
        case .custom(let width, let height): String(format: "%.1f×%.1f m", width, height)
        }
    }

    /// The state line, as a menu: ball group, practice mode, and a way to
    /// set the table up again. No chrome: it is the quiet line, and the
    /// buttons beside it are the loud ones.
    private var stateMenu: some View {
        Menu {
            Section("Balls") {
                ForEach([BallGroup.any, .solids, .stripes], id: \.rawValue) { group in
                    Button {
                        model.setBallGroup(group)
                    } label: {
                        if model.ballGroup == group {
                            Label(group == .any ? "Any group" : group.label, systemImage: "checkmark")
                        } else {
                            Text(group == .any ? "Any group" : group.label)
                        }
                    }
                }
            }
            Section("Practice") {
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
            }
            if model.tableCalibration != nil, !model.calibrationVisible {
                Button {
                    model.beginCalibration()
                } label: {
                    Label("Set up table again", systemImage: "rectangle.dashed")
                }
                .accessibilityIdentifier("calibrate-again-button")
            }
        } label: {
            HUDStateLineText(stateText)
        }
        .accessibilityLabel("Table, practice and balls: \(stateText)")
        .accessibilityHint("Opens a menu to change the balls or the practice mode")
        .accessibilityIdentifier("hud-state-menu")
    }

    /// Enters the calibration flow (or leaves it again). Labelled, not a
    /// dashed-rectangle glyph: on a cold table this is the only thing the
    /// player needs to press.
    private var setUpTableButton: some View {
        Button {
            if model.calibrationVisible {
                model.cancelCalibration()
            } else {
                model.beginCalibration()
            }
        } label: {
            Label(model.calibrationVisible ? "Cancel setup" : "Set up table",
                  systemImage: "rectangle.dashed")
                .fixedSize()
        }
        .buttonStyle(HUDBarButtonStyle())
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
        }
        .buttonStyle(HUDBarButtonStyle())
        .accessibilityLabel("Return to the back camera and the AR session")
        .accessibilityIdentifier("camera-flip-button")
    }

    private var moreButton: some View {
        Button(action: onMore) {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("More — record and settings")
        .accessibilityIdentifier("more-button")
    }
}
