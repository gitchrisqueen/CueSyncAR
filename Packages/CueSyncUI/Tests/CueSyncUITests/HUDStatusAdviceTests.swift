//
//  HUDStatusAdviceTests.swift
//  CueSync AR
//

import Testing
@testable import CueSyncUI

@Suite("HUD status and the shot card")
struct HUDStatusAdviceTests {

    @Test("No shot card while tracking is degraded")
    func degradedHidesTheCard() {
        #expect(!HUDStatus.degraded(reason: .fastMotion).allowsShotAdvice)
        #expect(!HUDStatus.degraded(reason: .lowLight).allowsShotAdvice)
        #expect(!HUDStatus.degraded(reason: .trackingLost).allowsShotAdvice)
    }

    @Test("No shot card on a calibration that no longer fits the table")
    func tableMovedHidesTheCard() {
        #expect(!HUDStatus.tableMoved.allowsShotAdvice)
    }

    @Test("Losing balls keeps the card: the table is still tracked")
    func losingBallsKeepsTheCard() {
        #expect(HUDStatus.losingBalls(seen: 5, peak: 15, dark: false).allowsShotAdvice)
        #expect(HUDStatus.losingBalls(seen: 5, peak: 15, dark: true).allowsShotAdvice)
    }

    @Test("Ordinary tracking states keep the card")
    func healthyStatesKeepTheCard() {
        #expect(HUDStatus.awaitingCueBall.allowsShotAdvice)
    }

    @Test("A status that hides the card never draws overlays at full strength")
    func hidingTheCardGoesWithFadedOverlays() {
        let hiding: [HUDStatus] = [.degraded(reason: .fastMotion), .degraded(reason: .lowLight),
                                   .degraded(reason: .trackingLost), .tableMoved]
        for status in hiding {
            #expect(status.overlayOpacity < 1, "\(status) hides the card but draws overlays at full strength")
        }
    }
}
