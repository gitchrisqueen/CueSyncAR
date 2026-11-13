//
//  SessionModel+AimLine.swift
//  CueSync AR
//
//  The card's aim line and its called-pocket line, from facts the session
//  model already holds. "On line" is `calledShotOnLine` (one definition:
//  the prediction sinks a non-cue ball into the called pocket) and nothing
//  else; see CueSyncUI.AimLine.
//

import ARExperience
import CueSyncUI
import Foundation

extension SessionModel {

    /// The aim against the suggested shot, in the HUD's terms.
    var aimCorrection: AimCorrection? {
        guard let correction = targetCorrection else { return nil }
        switch correction {
        case .onLine: return .onLine
        case .left(let degrees): return .left(degrees: degrees)
        case .right(let degrees): return .right(degrees: degrees)
        }
    }

    /// The line the card shows about the aim, or nil.
    var aimLine: AimLine? {
        AimLine.resolve(calledShotMode: practiceMode == .calledShots,
                        calledPocketSet: calledPocket != nil,
                        calledPocketOnLine: calledShotOnLine,
                        correction: aimCorrection,
                        correctionIsForCalledPocket: calledPocket != nil
                            && activeShot?.pocket == calledPocket)
    }

    /// The called pocket in the player's words ("far-right corner"), nil
    /// when none is called or the view of the table is not known yet.
    var calledPocketName: String? {
        calledPocket.flatMap { presentation.pocketNames[$0] }
    }
}
