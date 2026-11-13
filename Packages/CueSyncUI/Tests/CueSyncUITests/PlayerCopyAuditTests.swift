//
//  PlayerCopyAuditTests.swift
//  CueSync AR
//

import CueSyncCore
import Testing
@testable import CueSyncUI

@Suite("Player copy")
struct PlayerCopyAuditTests {

    /// Every status a player can be shown, with the arguments that produce
    /// the most jargon-prone text.
    static let everyStatus: [HUDStatus] = [
        .launching, .findingTable,
        .placingCorners(placed: 2), .confirmingRails,
        .needsCalibration(seeing: 0), .needsCalibration(seeing: 7),
        .awaitingCueBall, .tracking(ballCount: 6), .onLine,
        .losingBalls(seen: 2, peak: 6, dark: true),
        .losingBalls(seen: 2, peak: 6, dark: false),
        .degraded(reason: .fastMotion), .degraded(reason: .lowLight),
        .degraded(reason: .trackingLost), .tableMoved, .calledOffLine,
    ]

    @Test("No HUD status says anything a player cannot act on")
    func hudStatusesAreClean() {
        for status in Self.everyStatus {
            let violations = PlayerCopyAudit.violations(in: status.label)
            let detail = violations.map(\.description).joined(separator: "; ")
            #expect(violations.isEmpty, "\(detail)")
        }
    }

    @Test("The rule catches the four leaks that actually shipped")
    func catchesRealRegressions() {
        // Each of these was live in the app before this pass.
        let realOnes = [
            "Running on: onDevice",
            "Saved. 210 frames, 42 s, 32 MB → pull-session.sh",
            "No cloth height: put a few balls on the table, or pass h (remote)",
            "Bad rail (want x0:y0:x1:y1) (remote)",
        ]
        for text in realOnes {
            #expect(!PlayerCopyAudit.violations(in: text).isEmpty,
                    "expected a violation in \"\(text)\"")
        }
    }

    @Test("Ordinary copy is left alone")
    func doesNotFlagGoodCopy() {
        let fine = [
            "Point at the table",
            "Only seeing 2 of 6 balls — more light would help",
            "Tap the cushion-nose corners (0/4)",
            "On line — send it",
            "Voice guidance on. Key moments only.",
            "Mirror it to a TV over AirPlay from an iPhone or iPad",
            "Tracking 6 balls",
        ]
        for text in fine {
            let violations = PlayerCopyAudit.violations(in: text)
            let detail = violations.map(\.description).joined(separator: "; ")
            #expect(violations.isEmpty, "\(detail)")
        }
    }

    @Test("Identifier-shaped words are caught, real words are not")
    func identifierDetection() {
        #expect(PlayerCopyAudit.identifierLikeWords(in: "state is onDevice") == ["onDevice"])
        #expect(PlayerCopyAudit.identifierLikeWords(in: "Tracking limited: insufficientFeatures")
                == ["insufficientFeatures"])
        // Product spellings and ordinary sentences must survive, or the
        // rule gets switched off the first time it cries wolf.
        #expect(PlayerCopyAudit.identifierLikeWords(in: "Works on iPhone and iPad").isEmpty)
        #expect(PlayerCopyAudit.identifierLikeWords(in: "Mirror over AirPlay").isEmpty)
        #expect(PlayerCopyAudit.identifierLikeWords(in: "Point at the table").isEmpty)
        #expect(PlayerCopyAudit.identifierLikeWords(in: "Tracking 6 balls").isEmpty)
    }

    // MARK: Plurals

    /// Every count string a player can read, built with a count of one.
    static var countStringsAtOne: [String] {
        var strings = [
            HUDStatus.tracking(ballCount: 1).label,
            HUDStatus.needsCalibration(seeing: 1).label,
            HUDStatus.losingBalls(seen: 1, peak: 1, dark: false).label,
            HUDStatus.losingBalls(seen: 1, peak: 1, dark: true).label,
            HUDCopy.count(1, "ball"),
            HUDCopy.count(1, "object"),
        ]
        #if canImport(SwiftUI)
        strings.append(BallCountChip(count: 1).accessibilityText)
        #endif
        return strings
    }

    @Test("No player string says \"1 balls\"")
    func noOneBalls() {
        for text in Self.countStringsAtOne + Self.everyStatus.map(\.label) {
            #expect(text.range(of: "\\b1 balls\\b", options: .regularExpression) == nil, "\(text)")
            #expect(!PlayerCopyAudit.hasWrongPlural(in: text), "\(text)")
        }
        #expect(HUDStatus.tracking(ballCount: 1).label == "Tracking 1 ball")
        // Zero object balls is a table with only the cue ball on it, which is
        // not "tracking 0 balls".
        #expect(HUDStatus.tracking(ballCount: 0).label == "No balls to shoot at")
        #expect(HUDStatus.tracking(ballCount: 15).label == "Tracking 15 balls")
    }

    @Test("The plural rule catches the leak and nothing else")
    func pluralRule() {
        #expect(PlayerCopyAudit.hasWrongPlural(in: "Tracking 1 balls"))
        #expect(PlayerCopyAudit.hasWrongPlural(in: "seeing 1 objects"))
        #expect(!PlayerCopyAudit.hasWrongPlural(in: "Tracking 11 balls"))
        #expect(!PlayerCopyAudit.hasWrongPlural(in: "Tracking 1 ball"))
        #expect(!PlayerCopyAudit.hasWrongPlural(in: "Only seeing 1 of 6 balls"))
        #expect(HUDCopy.count(0, "ball") == "0 balls")
        #expect(HUDCopy.count(1, "ball") == "1 ball")
        #expect(HUDCopy.count(2, "ball") == "2 balls")
    }

    // MARK: Developer strings on the player's sheets

    @Test("With developer mode off, the More and Settings sheets show no developer string")
    func sheetsAreFreeOfDeveloperStrings() {
        for text in SheetCopy.More.all + SheetCopy.Settings.all {
            let violations = PlayerCopyAudit.developerViolations(in: text)
            let detail = violations.map(\.description).joined(separator: "; ")
            #expect(violations.isEmpty, "\(detail)")
            // The sheets also obey the general player-copy rule.
            let general = PlayerCopyAudit.violations(in: text)
            #expect(general.isEmpty, "\(general.map(\.description).joined(separator: "; "))")
        }
    }

    @Test("The developer rule catches every term it is meant to")
    func developerRuleCatches() {
        let leaks = [
            "Debug mirror",
            "The mirror serves the live screen",
            "Address 192.0.2.1",
            "Detector compute",
            "Needs a key in Secrets.xcconfig",
            "Neural Engine probe",
            "Saved. 210 frames",
            "about 32 MB",
            "Build 4f3a91c",
            "Commit 858e213a4b",
        ]
        for text in leaks {
            #expect(!PlayerCopyAudit.developerViolations(in: text).isEmpty,
                    "expected a developer violation in \"\(text)\"")
        }
    }

    @Test("The developer rule leaves ordinary words alone")
    func developerRuleIsNotParanoid() {
        let fine = [
            "Version 1.0 (12)",
            "Guide speed",
            "Show it on a TV over AirPlay",
            "Table size, guides and practice mode.",
            "A ball that vanishes while another appears",
            "decaded effaced",
        ]
        for text in fine {
            let violations = PlayerCopyAudit.developerViolations(in: text)
            #expect(violations.isEmpty, "\(violations.map(\.description).joined(separator: "; "))")
        }
    }
}
