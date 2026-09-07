//
//  AppBuild.swift
//  CueSync AR
//
//  "Which build is on the phone?" — the app-side half of the build-identity
//  feature. Reads what the "Embed Build Identity" build phase stamped into
//  the built Info.plist (project.yml → Scripts/embed-build-identity.sh) and
//  hands it to the three surfaces that answer the question: the HUD badge
//  (RootView), the debug mirror's /state.json (SessionModel), and the
//  startup log line.
//
//  Bundle access lives here rather than in CueSyncUI so the pure packages
//  stay free of Foundation bundle plumbing — BuildIdentity only ever sees
//  plain strings, which is what makes its formatting rules unit-testable.
//

import CueSyncUI
import Foundation
import os

enum AppBuild {
    /// Identity of the binary currently running, resolved once — the bundle
    /// cannot change underneath a running process. A build made from a
    /// checkout with no git history reports `unknown`; nothing here fails.
    static let identity = BuildIdentity(infoDictionary: Bundle.main.infoDictionary)

    /// Flat payload merged into the debug mirror's `/state.json`.
    static let json = identity.jsonFields

    /// Same subsystem/category as SessionModel's channel, so the build line
    /// shows up in the usual "cuesync" console filter. A separate Logger
    /// value rather than SessionModel's, which is main-actor isolated.
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "session")

    /// First line of every run. `.notice` (not `.info`) so it is still there
    /// in a console capture pulled hours later, away from the Mac.
    static func logStartup() {
        log.notice("\(identity.logLine, privacy: .public)")
    }
}
