//
//  SessionModel+DebugMirror.swift
//  CueSync AR
//
//  Lifecycle of the LAN debug mirror (App/Sources/DebugMirrorServer.swift):
//  the HUD/Settings switch, bringing the server up and down to match the
//  persisted preference, and publishing the rendered frame + `/state.json`
//  (SessionModel+MirrorState). The remote-command dispatcher stays in
//  SessionModel.swift (`handleMirrorCommand`) because it pokes tracking
//  state that is private to the class body. This file is the only writer
//  of `debugMirror` / `debugMirrorURL`. Split out of SessionModel.swift
//  for SwiftLint's file_length limit.
//

import CoachKit
import Foundation
import os

extension SessionModel {

    /// Diagnostics for the mirror specifically, so the token line can be
    /// found without wading through the session category.
    static let mirrorLog = Logger(subsystem: "com.cuesync.ar", category: "mirror")

    /// Whether the mirror starts on its own when nothing is persisted.
    ///
    /// A caveat worth knowing before testing this: it only applies to a
    /// FRESH store. A device that has already run a build with the old
    /// default has `true` written down, so flipping this changes nothing
    /// there until the setting is toggled or the app is reinstalled.
    static var mirrorOnByDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Open in development, token-gated in a Release build. Decided here,
    /// in the app target, rather than with a `#if DEBUG` inside CoachKit —
    /// that package is pure and Linux-tested, and its tests assert the
    /// defaults, so a configuration-dependent value there would change
    /// behaviour under `swift test -c release`.
    static func mirrorAccessMode() -> MirrorAccessPolicy.Mode {
        #if DEBUG
        return .open
        #else
        return .tokenRequired(MirrorAccessPolicy.freshToken())
        #endif
    }

    /// HUD antenna button. Flips the persisted preference; the mirror is
    /// brought up or down by `applyDebugMirrorSetting`, so the button and
    /// the Settings sheet toggle drive exactly one switch.
    func toggleDebugMirror() {
        updateSettings { $0.debugMirrorEnabled.toggle() }
    }

    /// Match the running mirror to `settings.debugMirrorEnabled`.
    func applyDebugMirrorSetting() {
        guard !settings.debugMirrorEnabled else {
            startDebugMirrorIfEnabled()
            return
        }
        guard let server = debugMirror else { return }
        server.stop()
        debugMirror = nil
        debugMirrorURL = nil
        showTapFeedback("Debug mirror off")
    }

    /// Bring the mirror up if the preference allows (default ON): the
    /// device usually sits at the table out of reach, so the mirror must
    /// survive app relaunches without a hand touching the screen.
    /// - Parameter announcing: whether to say the address on the HUD once
    ///   it is up. True for a switch someone just flipped; false at launch,
    ///   where the mirror comes up on its own and a player would be shown a
    ///   developer's IP address for no reason they asked for.
    func startDebugMirrorIfEnabled(announcing: Bool = true) {
        guard debugMirror == nil, settings.debugMirrorEnabled else { return }
        startDebugMirror(announcing: announcing)
    }

    private func startDebugMirror(announcing: Bool) {
        do {
            let server = try DebugMirrorServer()
            server.setCommandHandler { [weak self] params in
                Task { @MainActor in
                    self?.handleMirrorCommand(params)
                }
            }
            // Who may talk to it. DEBUG is open, because the whole
            // agent-driven table loop is `curl`-shaped and must not need a
            // secret; Release requires a per-launch token.
            let policy = MirrorAccessPolicy(mode: Self.mirrorAccessMode())
            server.setAccessPolicy(policy)
            debugMirror = server
            // NOT `server.sessionsRoot = ...` here, deliberately.
            //
            // The mirror runs by default and has no authentication, so
            // handing it the recordings directory at startup made every
            // bundle on the device — including ~200 MB of video of whatever
            // room the table is in — downloadable by anything on the same
            // Wi-Fi, for the life of the app, whether or not anyone had
            // recorded anything that session.
            //
            // The live surfaces stay open, because that is the whole point
            // of the mirror: /state.json, /frame.jpg and /cmd all work as
            // before. Only the FILES wait, and only until a recording is
            // started (see `startRecording`), which is the moment the owner
            // has plainly said they intend to pull something off.
            server.setActiveSession(recorder?.sessionID)
            let host = DebugMirrorServer.deviceIPAddress() ?? "<device-ip>"
            debugMirrorURL = policy.viewerURL(host: host, port: DebugMirrorServer.port)
            // `.notice` and not `.info`: this is the only way to read the
            // token off a device that is propped at a table with nobody
            // near the screen. `log stream --predicate 'subsystem ==
            // "com.cuesync.ar"'` over `devicectl` picks it up, which is
            // what the remote-verification loop actually does. Putting it
            // in /state.json instead would hand it to the very reader the
            // token exists to stop.
            Self.mirrorLog.notice("debug mirror at \(self.debugMirrorURL ?? "?", privacy: .public)")
            // The address used to sit in a permanent green capsule at the
            // top of the player's screen. It now lives in the More sheet
            // and in Settings -> Developer (both selectable) — but it is
            // still said out loud once, here, so turning the mirror on at
            // the table tells you what to type without opening a sheet.
            if announcing {
                showTapFeedback("Debug mirror on — \(debugMirrorURL ?? "")")
            }
        } catch {
            // Say what actually happened. This is the owner's only
            // debugging channel, and "port in use?" was a guess that would
            // send someone hunting the wrong problem — a denied local-network
            // permission fails here too, and looks identical.
            Self.log.error("debug mirror failed: \(String(describing: error), privacy: .public)")
            showTapFeedback("Mirror could not start — \(DebugMirrorServer.startFailureHint(error))")
        }
    }

    /// Publish the newest rendered frame + a state snapshot (~1 Hz).
    func publishMirrorFrame(_ jpeg: Data?) {
        guard let server = debugMirror else { return }
        server.update(jpeg: jpeg, stateJSON: mirrorStateJSON())
    }
}
