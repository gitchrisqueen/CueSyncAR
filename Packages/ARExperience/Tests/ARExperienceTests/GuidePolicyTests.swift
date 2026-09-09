//
//  GuidePolicyTests.swift
//  ARExperienceTests
//
//  The trim must cut length without cutting meaning: the ghost ball, the
//  object ball's leg to its pocket or rail, and at least one cushion have
//  to survive, because those are what the guide is FOR.
//

import CueSyncCore
import Testing
@testable import ARExperience

@Suite("Guide policy")
struct GuidePolicyTests {
    private let cue = BallID(0)
    private let object = BallID(1)
    private let third = BallID(2)

    private func segment(_ ball: BallID, _ from: Vec2, _ to: Vec2) -> TrajectorySegment {
        TrajectorySegment(ballID: ball, start: from, end: to)
    }

    /// Cue banks twice, strikes the object ball, banks twice more; the
    /// object ball banks and then rolls to rest; a third ball is set moving.
    private var longShot: ShotPrediction {
        ShotPrediction(
            segments: [
                segment(cue, Vec2(-1, 0), Vec2(-0.5, 0.5)),
                segment(cue, Vec2(-0.5, 0.5), Vec2(0, 0)),
                segment(cue, Vec2(0, 0), Vec2(0.5, -0.5)),
                segment(cue, Vec2(0.5, -0.5), Vec2(1, 0)),
                segment(object, Vec2(0, 0), Vec2(0.8, 0.4)),
                segment(object, Vec2(0.8, 0.4), Vec2(0.2, 0.2)),
                segment(third, Vec2(0.2, 0.2), Vec2(0.4, 0.4))
            ],
            events: [
                .cushion(ball: cue, point: Vec2(-0.5, 0.5)),
                .ballBall(moving: cue, struck: object, contact: Vec2(0, 0)),
                .cushion(ball: cue, point: Vec2(0.5, -0.5)),
                .rest(ball: cue, point: Vec2(1, 0)),
                .cushion(ball: object, point: Vec2(0.8, 0.4)),
                .ballBall(moving: object, struck: third, contact: Vec2(0.2, 0.2)),
                .rest(ball: third, point: Vec2(0.4, 0.4))
            ],
            pocketedBalls: [])
    }

    @Test("The cue keeps one cushion after contact, and the chain is dropped")
    func trimsToTheShotWorthDrawing() {
        let trimmed = GuidePolicy.trim(longShot, cueID: cue)
        let cueSegments = trimmed.segments.filter { $0.ballID == cue }
        let objectSegments = trimmed.segments.filter { $0.ballID == object }

        // Approach cushion, contact, then ONE cushion after.
        #expect(cueSegments.count == 3)
        // Object ball stops at its first cushion.
        #expect(objectSegments.count == 1)
        // The third ball is a prediction about a prediction.
        #expect(!trimmed.segments.contains { $0.ballID == third })
        // Shorter than what came in, and still shorter in events.
        #expect(trimmed.segments.count < longShot.segments.count)
        #expect(trimmed.events.count < longShot.events.count)
    }

    @Test("The ghost ball survives — the contact is the point of the guide")
    func contactSurvives() {
        let trimmed = GuidePolicy.trim(longShot, cueID: cue)
        let contact = trimmed.firstContact
        #expect(contact?.struck == object)
        #expect(contact?.contact == Vec2(0, 0))
    }

    @Test("At least one cushion or pocket survives (MVP item 4)")
    func keepsATerminalEvent() {
        let trimmed = GuidePolicy.trim(longShot, cueID: cue)
        let terminal = trimmed.events.contains {
            if case .cushion = $0 { return true }
            if case .pocket = $0 { return true }
            return false
        }
        #expect(terminal)
    }

    @Test("A bank with no contact keeps two cushions")
    func bankLineKeepsTwoCushions() {
        let bank = ShotPrediction(
            segments: [
                segment(cue, Vec2(-1, 0), Vec2(0, 0.5)),
                segment(cue, Vec2(0, 0.5), Vec2(1, 0)),
                segment(cue, Vec2(1, 0), Vec2(0, -0.5)),
                segment(cue, Vec2(0, -0.5), Vec2(-1, 0))
            ],
            events: [
                .cushion(ball: cue, point: Vec2(0, 0.5)),
                .cushion(ball: cue, point: Vec2(1, 0)),
                .cushion(ball: cue, point: Vec2(0, -0.5)),
                .rest(ball: cue, point: Vec2(-1, 0))
            ],
            pocketedBalls: [])
        let trimmed = GuidePolicy.trim(bank, cueID: cue)
        #expect(trimmed.segments.count == 2)
    }

    @Test("Pocketed balls follow what is DRAWN, not what was solved")
    func pocketedFollowsTheDrawnLine() {
        let scratchAfterTrim = ShotPrediction(
            segments: [
                segment(cue, Vec2(-1, 0), Vec2(0, 0)),
                segment(cue, Vec2(0, 0), Vec2(0.5, 0.5)),
                segment(cue, Vec2(0.5, 0.5), Vec2(1, 1)),
                segment(object, Vec2(0, 0), Vec2(1, 0))
            ],
            events: [
                .ballBall(moving: cue, struck: object, contact: Vec2(0, 0)),
                .cushion(ball: cue, point: Vec2(0.5, 0.5)),
                // Beyond the one-cushion budget: not drawn, so not claimed.
                .pocket(ball: cue, pocket: .cornerTopRight),
                .pocket(ball: object, pocket: .cornerBottomRight)
            ],
            pocketedBalls: [cue, object])
        let trimmed = GuidePolicy.trim(scratchAfterTrim, cueID: cue)
        #expect(!trimmed.pocketedBalls.contains(cue))
        #expect(trimmed.pocketedBalls.contains(object))
    }

    @Test("Keeping chains and following the struck ball are opt-in")
    func policyKnobsWiden() {
        let generous = GuidePolicy(cueCushionsAfterContact: 3,
                                   followStruckBallPastFirstCushion: true,
                                   keepSecondaryChains: true)
        let trimmed = GuidePolicy.trim(longShot, cueID: cue, policy: generous)
        #expect(trimmed.segments.count == longShot.segments.count)
    }

    @Test("An empty prediction passes through untouched")
    func emptyIsSafe() {
        let empty = ShotPrediction()
        #expect(GuidePolicy.trim(empty, cueID: cue) == empty)
    }
}
