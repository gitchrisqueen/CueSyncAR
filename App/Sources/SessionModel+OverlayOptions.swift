//
//  SessionModel+OverlayOptions.swift
//  CueSync AR
//
//  Test-only overlay switches, driven from the debug mirror. There is
//  deliberately no Settings row for them: the player's table shows one line
//  to follow and one pocket to hit, and the lines that are hidden while a
//  shot is suggested (the cue ball after contact, the object ball's own
//  predicted path, the live ghost ball) are for whoever is debugging.
//

import Foundation

extension SessionModel {
    /// `/cmd?action=secondaryLines&v=0|1`. Returns false for any other
    /// action so the next handler gets a turn.
    ///
    /// A malformed `v` is answered on the HUD and in the log rather than
    /// ignored: a remote command that does nothing and says nothing looks
    /// exactly like a command that worked.
    func handleOverlayMirrorCommand(_ params: [String: String]) -> Bool {
        guard params["action"] == "secondaryLines" else { return false }
        guard let raw = params["v"], let value = Int(raw), value == 0 || value == 1 else {
            Self.log.error("secondaryLines: expected v=0 or v=1, got \(params["v"] ?? "nothing", privacy: .public)")
            showRemoteFeedback("secondaryLines needs v=0 or v=1")
            return true
        }
        showsSecondaryLines = value == 1
        Self.log.info("secondaryLines -> \(self.showsSecondaryLines, privacy: .public)")
        showRemoteFeedback(showsSecondaryLines ? "Secondary lines on" : "Secondary lines off")
        return true
    }
}
