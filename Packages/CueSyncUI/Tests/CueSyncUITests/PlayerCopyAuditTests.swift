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
        .degraded(reason: .trackingLost),
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
}
