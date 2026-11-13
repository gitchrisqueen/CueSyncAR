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
            “Use measured” sizes the table from the corners you tap. Pick a \
            size to force it; it applies the next time you set up the table.
            """

        public static let savedHeader = "Saved tables"
        public static let savedInUse = "In use"
        public static let savedFooterFull = """
            This is as many tables as the app remembers. Delete one before \
            setting up somewhere new.
            """
        public static let savedFooter = """
            The app remembers each table you play on. Swipe to delete one \
            you no longer use.
            """

        public static let guidesHeader = "Aiming"
        public static let deviceParked = "Device on a stand"
        public static let shotStrength = "Shot strength"
        public static let guidesFooter = """
            Turn "Device on a stand" on whenever the iPad or iPhone is on a \
            tripod or propped on a rail. Held in your hand, the app aims \
            where the camera points; on a stand it aims from your cue only, \
            and tells you when it cannot see one.

            Shot strength is how hard the predicted shot is struck. Soft \
            lines stop sooner; firm ones travel further.
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
            savedFooterFull, savedFooter, guidesHeader, deviceParked, shotStrength,
            guidesFooter, practiceHeader,
            practiceMode, ballGroup, voiceHeader, spokenGuidance, sayNow, voiceCheck,
            voiceFooterTail, aboutHeader, version,
        ]
    }
}
