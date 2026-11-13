//
//  SessionModel+ShotSlot.swift
//  CueSync AR
//
//  What the shot card's slot shows, decided in one place so the card, the
//  overlay's highlight and the score chip all agree.
//
//  Once a pocket is called the card is about THAT pocket only: the ball that
//  goes into it, the tier of that shot, the aim against it. It used to show
//  the best shot into any pocket ("-> FAR-RIGHT CORNER") with the called
//  pocket named on a line beneath it ("CALLED: FAR-LEFT CORNER"), two
//  pockets on one card. If no ball can go into the called pocket the slot
//  says so in words instead of showing a shot into a different pocket.
//

import ARExperience
import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation

/// What a called pocket makes of the table.
enum CalledShot {
    /// No pocket is called (or there is no cue ball to shoot with).
    case none
    /// The shot into the called pocket that the card is about. It can be a
    /// blocked rating when the player picked a ball that cannot go there.
    case shot(ShotRating)
    /// No ball can go into the called pocket cleanly.
    case noShot
}

/// What the slot under the status capsule shows.
enum ShotSlotContent {
    case payoff(PayoffEvent)
    case empty(ShotEmptyState)
    case shot(ShotRating, isCalled: Bool)
    case guide(ShotGuide)
}

extension SessionModel {

    /// The shot into the called pocket, when one is called.
    var calledShot: CalledShot {
        guard let called = calledPocket, let state = tableState, state.cueBall != nil else { return .none }
        let intoCalled = ShotRanking.rank(state: state, group: settings.ballGroup,
                                          config: settings.skillLevel.rankingConfig)
            .filter { $0.pocket == called }
        // A ball the player tapped: that ball into the called pocket, even
        // if it cannot go (the card then says why, for THIS pocket).
        if targetIsPlayerChosen, let picked = activeShot?.ball,
           let rating = intoCalled.first(where: { $0.ball == picked }) {
            return .shot(rating)
        }
        // Otherwise the best ball into it (the ranking puts clear shots first).
        if let best = intoCalled.first(where: { $0.blocker == nil }) { return .shot(best) }
        return .noShot
    }

    /// The shot being shown and drawn: the called pocket's shot when a
    /// pocket is called, else the app's suggestion or the player's pick. The
    /// card AND the overlay's highlight both read this, so they name and
    /// draw the same ball by construction.
    var displayedShot: ShotRating? {
        switch calledShot {
        case .none: activeShot
        case .shot(let rating): rating
        case .noShot: nil
        }
    }

    /// The slot's content, or nil when it is empty.
    var shotSlotContent: ShotSlotContent? {
        // No confident card while the app cannot stand behind it: a stale
        // calibration, or a status that says tracking is degraded
        // (`HUDStatus.allowsShotAdvice`). The capsule says why.
        guard isLiveTracking, !calibrationIsStale, hudStatus?.allowsShotAdvice ?? true else { return nil }
        // A made shot, a miss or a scratch takes the card's slot for about
        // 1.2 s, then the card comes back. Nothing stacks under the card.
        if let payoff = feedback.payoff { return .payoff(payoff) }
        switch calledShot {
        case .noShot:
            return .empty(.noShotToCalledPocket(pocket: calledPocketName ?? "called pocket"))
        case .shot(let rating):
            return .shot(rating, isCalled: true)
        case .none:
            // A full rack or no clean pot: say so, instead of the card
            // vanishing and the player wondering if the app has stopped. A
            // rack outranks any shot rated into it.
            if let empty = shotEmptyState { return .empty(empty) }
            if let shot = activeShot { return .shot(shot, isCalled: false) }
            // Aiming with no shot on offer: the strike advice alone, when
            // it is not just "centre ball".
            if let guide = shotGuide, HUDCopy.guideWord(tipOffset: guide.tipOffset) != nil {
                return .guide(guide)
            }
            return nil
        }
    }

    /// Why `shot` cannot be taken, true for what the card shows.
    ///
    /// For a called pocket that is that pocket's own blocker. For a ball
    /// picked with no pocket in mind it is the obstruction at the pocket the
    /// ball comes closest to making, NOT the rating `ShotRanking.best` keeps
    /// (the lowest pocket id among all-zero ratings, which can be a pocket
    /// behind the ball: "that cut is past 90°" with another ball plainly on
    /// the line).
    func blockedReason(for shot: ShotRating) -> String {
        guard let state = tableState else { return shot.headline }
        let name: (BallID) -> String = { id in
            ShotCall.make(ball: id, in: state,
                          colour: self.ballIdentity.family(for: id)?.family.rawValue,
                          pocket: nil).leadBall
        }
        if case .shot = calledShot { return BlockedReason.reason(for: shot, name: name) }
        let ofBall = ShotRanking.rank(state: state, group: settings.ballGroup,
                                      config: settings.skillLevel.rankingConfig)
            .filter { $0.ball == shot.ball }
        return BlockedReason.reason(forBall: ofBall, name: name)
    }

    /// "2 of 5" for the card's first row, nil with the scoreboard off.
    var cardScoreText: String? {
        settings.showScoreboard ? feedback.score.chipText : nil
    }
}
