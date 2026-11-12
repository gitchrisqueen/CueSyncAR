//
//  SheetCopy.swift
//  CueSyncUI
//
//  The words of the More and Settings sheets that a player sees, as
//  constants, so a Linux test can run the developer-string audit over them
//  (PlayerCopyAudit.developerViolations). The views use these constants and
//  nothing else for the player's rows; what a developer sees with developer
//  mode on stays in the views, behind the gate.
//
//  Each enum's `all` list is what the test walks: a new player-facing
//  string is added here and to that list, or it is not audited.
//

import Foundation

public enum SheetCopy {

    public enum More {
        public static let title = "More"
        public static let done = "Done"
        public static let tableHeader = "At the table"
        public static let record = "Record session"
        public static let stopRecording = "Stop recording"
        public static let recordFooter = "The recorder saves a session you can replay later."
        public static let settings = "Settings"
        public static let settingsFooter = "Table size, guides and practice mode."

        public static let all: [String] = [
            title, done, tableHeader, record, stopRecording, recordFooter,
            settings, settingsFooter,
        ]
    }

    public enum Settings {
        public static let title = "Settings"
        public static let done = "Done"

        public static let tableHeader = "Table"
        public static let tableSize = "Table size"
        public static let tableFooter = """
            “Use measured” keeps whatever calibration measures (snapped \
            to your remembered table when there is one). Pick a size to \
            force it — takes effect the next time you calibrate.
            """

        public static let savedHeader = "Saved tables"
        public static let savedInUse = "In use"
        public static let savedFooterFull = """
            This is as many tables as the app keeps. Delete one to \
            make room before calibrating somewhere new.
            """
        public static let savedFooter = """
            Each table keeps its own map of the room. Swipe to delete \
            one you no longer play on.
            """

        public static let guidesHeader = "Guides"
        public static let deviceParked = "Device is parked"
        public static let guideSpeed = "Guide speed"
        public static let guidesFooter = """
            Turn "device is parked" on whenever the phone or iPad is on \
            a tripod or propped on a rail. Held in the hand, the app can \
            aim from where the camera looks; parked, that becomes a \
            fixed line to wherever the mount happens to face, so it \
            aims from the cue only and tells you when it cannot see one.

            Guide speed is how hard the predicted shot is struck. Slower \
            lines die mid-table; faster ones spend the path budget on \
            ricochets.
            """

        public static let trackingHeader = "Tracking"
        public static let missGrace = "Visible-miss grace"
        public static let trackingFooter = """
            How long a ball that is in view but undetected keeps its \
            track — a ball hidden behind your bridge hand while you \
            aim, for instance. Longer survives that; shorter clears \
            stray balls sooner. A ball that vanishes while another \
            appears is treated as struck and always gives up its ring \
            quickly, whatever this is set to.
            """

        public static let practiceHeader = "Practice"
        public static let practiceMode = "Mode"
        public static let ballGroup = "Ball group"

        public static let voiceHeader = "Voice"
        public static let spokenGuidance = "Spoken guidance"
        public static let sayNow = "Say something now"
        public static let voiceCheck = "Voice check. Best shot, 62 percent into the top-left corner."
        public static let voiceFooterTail = """
            Off unless you turn it on. The voice is the one already on \
            this device — nothing is sent anywhere and it works with no \
            signal. Music in the room dips for a prompt rather than \
            stopping; like a navigation app, it speaks even when the \
            ring switch is set to silent.
            """

        public static let aboutHeader = "About"
        public static let version = "Version"

        public static let all: [String] = [
            title, done, tableHeader, tableSize, tableFooter, savedHeader, savedInUse,
            savedFooterFull, savedFooter, guidesHeader, deviceParked, guideSpeed,
            guidesFooter, trackingHeader, missGrace, trackingFooter, practiceHeader,
            practiceMode, ballGroup, voiceHeader, spokenGuidance, sayNow, voiceCheck,
            voiceFooterTail, aboutHeader, version,
        ]
    }
}
