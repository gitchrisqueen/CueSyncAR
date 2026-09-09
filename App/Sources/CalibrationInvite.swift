//
//  CalibrationInvite.swift
//  CueSync AR
//
//  Before the table is calibrated, the camera area has nothing to tap.
//
//  The ARView is `allowsHitTesting(false)` (RealityKit's own gestures are
//  not wanted), the detection-preview overlay is too, and PocketCallCatcher
//  — the one view that makes the cloth tappable — mounts only during live
//  tracking, which cannot start without a calibrated table. So the entire
//  middle of the screen was inert, and the only way in was an unlabelled
//  dashed-rectangle icon in a row of nine.
//
//  Worth stating because of how it presented: the root's tap probe
//  (`noteRootTap`, on a non-consuming simultaneousGesture) stayed at zero
//  while the owner was tapping the screen. That probe measures taps that
//  land on hit-testable content, so zero meant "nothing there to hit", not
//  "touch input is broken" — a distinction that cost a diagnosis.
//

import SwiftUI

/// Makes the whole screen open calibration while there is no table yet.
///
/// Sits below the HUD in the ZStack, so the control bar keeps its taps;
/// it only claims the empty camera area that previously swallowed them.
struct CalibrationInviteCatcher: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                // Same probe the live catcher uses, so "a tap arrived" and
                // "a tap was ignored" stay distinguishable from the mirror.
                model.noteRootTap()
                model.beginCalibration()
            }
            .accessibilityLabel("Tap anywhere to calibrate the table")
            .accessibilityAddTraits(.isButton)
    }
}
