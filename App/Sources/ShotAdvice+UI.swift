//
//  ShotAdvice+UI.swift
//  CueSync AR
//
//  Glue from CoachKit's ShotOption to the renderers' primitive inputs
//  (CueSyncUI and ARExperience deliberately don't depend on CoachKit).
//

import ARExperience
import CoachKit
import CueSyncCore
import CueSyncUI
import TableSpace

extension ShotOption {
    /// Difficulty colour for the HUD card (lines use `Theme.adviceLine`).
    var color: ColorToken {
        switch rating {
        case .easy: Theme.adviceEasy
        case .medium: Theme.adviceMedium
        case .hard: Theme.adviceHard
        }
    }

    /// Input for the 2D mini-map / TV table view.
    var tableAdvice: TableScene.Advice {
        TableScene.Advice(cue: aim.origin, ghost: ghostBall,
                          target: targetPosition, pocket: pocketPosition,
                          pocketRadius: pocketCaptureRadius, color: Theme.adviceLine)
    }
}

extension OverlayLayout {
    /// This layout plus the advised shot's AR overlay (no-op without one).
    func advising(_ shot: ShotOption?, cueID: BallID?,
                  calibration: TableCalibration) -> OverlayLayout {
        guard let shot, let cueID else { return self }
        return withSuggestion(cue: shot.aim.origin, ghost: shot.ghostBall,
                              target: shot.targetPosition,
                              pocket: shot.pocketPosition,
                              pocketRadius: shot.pocketCaptureRadius,
                              ballRadius: Ball.standardRadius,
                              color: Theme.adviceLine.rgb,
                              cueID: cueID, targetID: shot.target,
                              calibration: calibration)
    }
}
