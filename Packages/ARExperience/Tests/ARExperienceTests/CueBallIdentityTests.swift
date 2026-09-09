//
//  CueBallIdentityTests.swift
//  ARExperienceTests
//
//  Identity has to survive the two things that actually happen at a table:
//  the detector losing the `white-ball` label for a few frames, and the
//  tracker handing out fresh ids after a reset. Neither should cost the
//  player a tap, and neither should ever leave two cue balls on the table.
//

import CueSyncCore
import Foundation
import Testing
@testable import ARExperience

@Suite("Cue-ball identity")
struct CueBallIdentityTests {
    private let table = Table(size: .eightFoot)

    private func state(_ balls: [Ball], at time: TimeInterval = 0) -> TableState {
        TableState(table: table, balls: balls, timestamp: time)
    }

    private func ball(_ id: Int, _ kind: Ball.Kind = .unknown,
                      _ position: Vec2, confidence: Double = 0.8) -> Ball {
        Ball(id: BallID(id), kind: kind, position: position, confidence: confidence)
    }

    @Test("With nothing tracked there is no cue ball and no crash")
    func emptyTableIsSafe() {
        var identity = CueBallIdentity()
        let empty = state([])
        #expect(identity.apply(to: empty) == empty)
        #expect(identity.currentID == nil)
    }

    @Test("The detector's own claim is adopted and then held")
    func adoptsAndHolds() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([
            ball(1, .cue, .zero), ball(2, .unknown, Vec2(0.5, 0))
        ], at: 0))
        #expect(identity.currentID == BallID(1))

        // The label goes away; the track does not.
        let held = identity.apply(to: state([
            ball(1, .unknown, Vec2(0.01, 0)), ball(2, .unknown, Vec2(0.5, 0))
        ], at: 0.2))
        #expect(held.cueBall?.id == BallID(1))
    }

    @Test("Exactly one cue ball, always")
    func demotesRivalClaims() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, .zero)], at: 0))
        // A second ball starts claiming to be the cue ball too.
        let adjusted = identity.apply(to: state([
            ball(1, .cue, .zero), ball(2, .cue, Vec2(0.5, 0))
        ], at: 0.2))
        #expect(adjusted.balls.filter { $0.kind == Ball.Kind.cue }.count == 1)
        #expect(adjusted.cueBall?.id == BallID(1))
    }

    @Test("A tap beats adoption, and tapping again clears the mark")
    func tapWinsAndToggles() {
        var identity = CueBallIdentity()
        let live = state([ball(1, .cue, .zero), ball(2, .unknown, Vec2(0.5, 0))])
        _ = identity.apply(to: live)
        #expect(identity.currentID == BallID(1))

        let marked = identity.toggle(near: Vec2(0.5, 0), in: live, maxDistance: 0.25)
        #expect(marked)
        #expect(identity.designatedID == BallID(2))
        #expect(identity.apply(to: live).cueBall?.id == BallID(2))

        let cleared = identity.toggle(near: Vec2(0.5, 0), in: live, maxDistance: 0.25)
        #expect(cleared)
        #expect(identity.designatedID == nil)
    }

    @Test("A tap with no ball near it changes nothing")
    func tapOutOfRangeIsIgnored() {
        var identity = CueBallIdentity()
        let live = state([ball(1, .unknown, .zero)])
        let hit = identity.toggle(near: Vec2(1.0, 0.5), in: live, maxDistance: 0.25)
        #expect(!hit)
        #expect(identity.designatedID == nil)
    }

    @Test("A ball standing where the cue ball was is the cue ball")
    func reattachesByPosition() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, Vec2(-0.6, 0.05))], at: 0))
        // The track dies; a new one appears in the same spot.
        let reborn = identity.apply(to: state([ball(9, .unknown, Vec2(-0.61, 0.05))], at: 1.0))
        #expect(reborn.cueBall?.id == BallID(9))
    }

    @Test("A ball somewhere else is NOT the cue ball")
    func doesNotReattachAcrossTheTable() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, Vec2(-0.6, 0.05))], at: 0))
        // 40 cm away: this is a different ball, and adopting it would put
        // the aim origin on the wrong one.
        let elsewhere = identity.apply(to: state([ball(9, .unknown, Vec2(-0.2, 0.05))], at: 1.0))
        #expect(elsewhere.cueBall == nil)
    }

    @Test("Re-attachment expires, so a fresh rack is not silently adopted")
    func reattachmentWindowExpires() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, Vec2(-0.6, 0.05))], at: 0))
        let late = identity.apply(to: state([ball(9, .unknown, Vec2(-0.6, 0.05))], at: 10.0))
        #expect(late.cueBall == nil)
    }

    @Test("A tracking reset keeps the place, not the id")
    func trackingResetKeepsPosition() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, Vec2(-0.6, 0.05))], at: 0))
        identity.trackingReset(at: 1.0)
        #expect(identity.currentID == nil)
        #expect(identity.designatedID == nil)
        // Same felt, new ids: re-adopted in place.
        let after = identity.apply(to: state([ball(7, .unknown, Vec2(-0.6, 0.05))], at: 1.5))
        #expect(after.cueBall?.id == BallID(7))
    }

    @Test("A full reset forgets the place too")
    func resetForgetsEverything() {
        var identity = CueBallIdentity()
        _ = identity.apply(to: state([ball(1, .cue, Vec2(-0.6, 0.05))], at: 0))
        identity.reset()
        let after = identity.apply(to: state([ball(7, .unknown, Vec2(-0.6, 0.05))], at: 0.5))
        #expect(after.cueBall == nil)
    }

    @Test("Clearing the mark leaves adoption running")
    func clearingTheMarkKeepsFollowing() {
        var identity = CueBallIdentity()
        let live = state([ball(1, .cue, .zero), ball(2, .unknown, Vec2(0.5, 0))])
        _ = identity.apply(to: live)
        _ = identity.toggle(near: Vec2(0.5, 0), in: live, maxDistance: 0.25)
        #expect(identity.designatedID == BallID(2))
        identity.clearDesignation()
        // Still following ball 2 — clearing a mark is not a statement that
        // there is no cue ball on the table.
        #expect(identity.apply(to: live).cueBall?.id == BallID(2))
    }

    @Test("The most confident claim wins when several appear at once")
    func adoptsTheMostConfidentClaim() {
        var identity = CueBallIdentity()
        let adjusted = identity.apply(to: state([
            ball(1, .cue, .zero, confidence: 0.4),
            ball(2, .cue, Vec2(0.5, 0), confidence: 0.9)
        ], at: 0))
        #expect(adjusted.cueBall?.id == BallID(2))
    }
}
