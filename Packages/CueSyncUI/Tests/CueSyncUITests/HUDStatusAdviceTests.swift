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

    @Test("Fewer than half the balls in view: no card, the capsule says so")
    func losingBallsHidesTheCard() {
        #expect(!HUDStatus.losingBalls(seen: 5, peak: 15, dark: false).allowsShotAdvice)
        #expect(!HUDStatus.losingBalls(seen: 5, peak: 15, dark: true).allowsShotAdvice)
    }

    @Test("Every status that hides the card is drawn as a warning, and no other is")
    func hidingTheCardIsTheWarningSet() {
        let all: [HUDStatus] = [.launching, .findingTable, .placingCorners(placed: 1), .confirmingRails,
                                .awaitingCueBall, .onLine, .calledOffLine, .tracking(ballCount: 5),
                                .needsCalibration(seeing: 3), .losingBalls(seen: 2, peak: 6, dark: false),
                                .degraded(reason: .fastMotion), .degraded(reason: .lowLight),
                                .degraded(reason: .trackingLost), .tableMoved]
        for status in all {
            #expect(status.isWarning == !status.allowsShotAdvice, "\(status)")
        }
    }

    @Test("A warning status never carries a tick or a ball count")
    func warningsHaveNoTickAndNoTrackingCount() {
        let warnings: [HUDStatus] = [.losingBalls(seen: 2, peak: 6, dark: false),
                                     .degraded(reason: .fastMotion), .degraded(reason: .lowLight),
                                     .degraded(reason: .trackingLost), .tableMoved]
        for status in warnings {
            #expect(status.systemImage != "checkmark.circle", "\(status)")
            #expect(!status.label.hasPrefix("Tracking "), "\(status)")
        }
    }

    @Test("Ordinary tracking states keep the card")
    func healthyStatesKeepTheCard() {
        #expect(HUDStatus.awaitingCueBall.allowsShotAdvice)
    }

    @Test("A status that hides the card never draws overlays at full strength")
    func hidingTheCardGoesWithFadedOverlays() {
        let hiding: [HUDStatus] = [.degraded(reason: .fastMotion), .degraded(reason: .lowLight),
                                   .degraded(reason: .trackingLost), .tableMoved,
                                   .losingBalls(seen: 2, peak: 6, dark: false)]
        for status in hiding {
            #expect(status.overlayOpacity < 1, "\(status) hides the card but draws overlays at full strength")
        }
    }
}
