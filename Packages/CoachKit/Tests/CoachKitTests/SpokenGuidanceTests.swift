import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

/// The value of this type is entirely in what it REFUSES to say, so that
/// is what most of these tests are about: the same line twice, a nudge on
/// top of an announcement, a voice chattering across the on-line boundary
/// while the player holds still. Time is supplied by the test, never read
/// from a clock, so the gap rules are exact rather than flaky.
@Suite("SpokenGuidance")
struct SpokenGuidanceTests {

    // MARK: Fixtures

    private func shot(ball: Int = 3,
                      pocket: PocketID = .cornerTopLeft,
                      probability: Double = 0.62,
                      blocker: ShotRating.Blocker? = nil) -> ShotRating {
        ShotRating(ball: BallID(ball), pocket: pocket,
                   probability: blocker == nil ? probability : 0,
                   difficulty: blocker == nil
                       ? ShotRating.Difficulty.band(probability: probability) : .blocked,
                   cutAngleDegrees: 20, cueTravel: 0.8, objectTravel: 0.6,
                   aimTolerance: 0.01, ghostBall: Vec2(0.1, 0.2), blocker: blocker)
    }

    private func playing(nudge: AimNudge? = nil,
                         shot: ShotRating? = nil,
                         chosenByPlayer: Bool = false) -> SpokenGuidance.Situation {
        SpokenGuidance.Situation(stage: .tracking,
                                 shot: shot ?? self.shot(),
                                 chosenByPlayer: chosenByPlayer,
                                 nudge: nudge)
    }

    private func coach(_ verbosity: SpeechVerbosity = .coaching) -> SpokenGuidance {
        SpokenGuidance(verbosity: verbosity)
    }

    // MARK: Verbosity

    @Test("Off says nothing, however loud the situation")
    func offIsSilent() {
        var guidance = coach(.off)
        #expect(guidance.next(for: playing(), at: 0) == nil)
        #expect(guidance.next(for: .init(stage: .degraded(.lowLight)), at: 10) == nil)
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 20) == nil)
    }

    @Test("Key moments announces the shot but never nudges the aim")
    func keyMomentsSkipsNudges() {
        var guidance = coach(.keyMoments)
        let opening = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        #expect(opening?.priority == .moment)
        #expect(opening?.text.contains("62 percent") == true)
        // Everything else on offer is a nudge, so from here it is silent.
        for tick in 1...40 {
            let time = TimeInterval(tick) * 2
            #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: time) == nil)
        }
    }

    @Test("Coaching nudges once the shot has been announced")
    func coachingNudges() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        let nudge = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 5)
        #expect(nudge?.priority == .nudge)
        #expect(nudge?.text == "Aim left.")
    }

    @Test("Under five degrees is a little, over five is not")
    func nudgeMagnitudeMatchesTheOnScreenWording() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .right(degrees: 2)), at: 0)
        #expect(guidance.next(for: playing(nudge: .right(degrees: 2)), at: 5)?.text
                == "Aim a little right.")
        #expect(guidance.next(for: playing(nudge: .right(degrees: 12)), at: 20)?.text
                == "Aim right.")
    }

    // MARK: De-duplication

    @Test("An unchanged situation is announced exactly once")
    func doesNotRepeatItself() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: playing(), at: 0) != nil)
        for tick in 1...200 {
            #expect(guidance.next(for: playing(), at: TimeInterval(tick)) == nil)
        }
    }

    @Test("A line becomes sayable again once it has stopped being on offer")
    func repeatsOnlyAfterTheSituationLeavesAndReturns() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: .init(stage: .awaitingCueBall), at: 0) != nil)
        #expect(guidance.next(for: .init(stage: .awaitingCueBall), at: 30) == nil)
        // The cue ball comes back and the shot is announced instead…
        #expect(guidance.next(for: playing(), at: 60) != nil)
        // …and losing it again is worth saying a second time.
        #expect(guidance.next(for: .init(stage: .awaitingCueBall), at: 90) != nil)
    }

    @Test("A new shot is a new announcement")
    func announcesEachShot() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: playing(), at: 0)?.text.contains("top-left corner") == true)
        let other = shot(ball: 7, pocket: .sideBottom, probability: 0.31)
        let next = guidance.next(for: playing(shot: other), at: 10)
        #expect(next?.text == "Best shot, 31 percent into the bottom side.")
    }

    @Test("The player's own pick is never read out as the app's suggestion")
    func namesWhoChose() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: playing(), at: 0)?.text.hasPrefix("Best shot") == true)
        let mine = guidance.next(for: playing(chosenByPlayer: true), at: 10)
        #expect(mine?.text.hasPrefix("Your ball") == true)
    }

    // MARK: The minimum gap

    @Test("Two announcements do not run into each other")
    func enforcesTheMinimumGap() {
        var guidance = coach(.keyMoments)
        var config = SpokenGuidance.Config()
        config.momentGap = 1.5
        guidance.config = config

        #expect(guidance.next(for: playing(), at: 0) != nil)
        // A genuinely different moment, but far too soon.
        #expect(guidance.next(for: .init(stage: .degraded(.lowLight)), at: 1.0) == nil)
        #expect(guidance.next(for: .init(stage: .degraded(.lowLight)), at: 1.5) != nil)
    }

    @Test("A nudge waits far longer than an announcement does")
    func nudgesAreRateLimitedHarder() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)   // the shot
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 2) == nil)
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 4)?.priority == .nudge)
        // A different nudge is still a nudge and still waits.
        #expect(guidance.next(for: playing(nudge: .right(degrees: 9)), at: 6) == nil)
        #expect(guidance.next(for: playing(nudge: .right(degrees: 9)), at: 8)?.text == "Aim right.")
    }

    @Test("The same nudge comes round again, but only after a long silence")
    func repeatsANudgeEventually() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 4) != nil)
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 9) == nil)
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: 10)?.text == "Aim left.")
    }

    // MARK: Priority

    @Test("A state change cuts a nudge off mid-gap")
    func momentsPreemptNudges() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        let nudge = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 4)
        #expect(nudge?.priority == .nudge)
        // 0.1 s later the cue ball vanishes. That cannot wait for the gap.
        let alarm = guidance.next(for: .init(stage: .awaitingCueBall), at: 4.1)
        #expect(alarm?.priority == .moment)
        #expect(alarm?.text.contains("cue ball") == true)
    }

    @Test("A nudge never cuts a state change off")
    func nudgesNeverPreemptMoments() {
        var guidance = coach()
        let opening = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        #expect(opening?.priority == .moment)
        for time in stride(from: 0.5, through: 3.5, by: 0.5) {
            #expect(guidance.next(for: playing(nudge: .left(degrees: 9)), at: time) == nil)
        }
    }

    @Test("Blocked outranks nothing else, but is announced as a state change")
    func blockedIsAMoment() {
        var guidance = coach()
        let blocked = shot(blocker: .cuePath(BallID(9)))
        let line = guidance.next(for: playing(nudge: .left(degrees: 9), shot: blocked), at: 0)
        #expect(line?.priority == .moment)
        #expect(line?.text == "That one is blocked. A ball is in the cue ball's way.")
        // And no aim coaching for a shot that cannot be taken.
        #expect(guidance.next(for: playing(nudge: .left(degrees: 9), shot: blocked), at: 30) == nil)
    }

    // MARK: On line, and the hysteresis around it

    @Test("On line is said once, then the coaching stops")
    func onLineEndsTheCoaching() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        let onLine = guidance.next(for: playing(nudge: .onLine), at: 2)
        #expect(onLine?.text == "On line. Send it.")
        #expect(onLine?.priority == .moment)
        #expect(guidance.next(for: playing(nudge: .onLine), at: 20) == nil)
    }

    @Test("A hand shaking on the boundary does not restart the chatter")
    func hysteresisSuppressesBoundaryChatter() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        #expect(guidance.next(for: playing(nudge: .onLine), at: 2) != nil)
        // Wobbling in and out of the 1° deadband by a degree or two: the
        // aim has not really left, so nothing is said.
        for (index, time) in stride(from: 10.0, through: 60.0, by: 5).enumerated() {
            let wobble: AimNudge = index.isMultiple(of: 2) ? .onLine : .right(degrees: 2.5)
            #expect(guidance.next(for: playing(nudge: wobble), at: time) == nil)
        }
    }

    @Test("Leaving the deadband for real re-arms both the nudges and the call")
    func hysteresisReleasesOnARealMiss() {
        var guidance = coach()
        _ = guidance.next(for: playing(nudge: .left(degrees: 9)), at: 0)
        #expect(guidance.next(for: playing(nudge: .onLine), at: 2) != nil)
        // 8° is not a wobble; the player has moved off the shot.
        #expect(guidance.next(for: playing(nudge: .right(degrees: 8)), at: 10)?.text
                == "Aim right.")
        #expect(guidance.next(for: playing(nudge: .onLine), at: 20)?.text == "On line. Send it.")
    }

    @Test("Changing shot re-arms the on-line call for the new one")
    func newShotReleasesTheOnLineHold() {
        var guidance = coach(.keyMoments)
        _ = guidance.next(for: playing(), at: 0)
        #expect(guidance.next(for: playing(nudge: .onLine), at: 2) != nil)
        let other = shot(ball: 11, pocket: .sideTop)
        _ = guidance.next(for: playing(nudge: .onLine, shot: other), at: 10)  // announces it
        #expect(guidance.next(for: playing(nudge: .onLine, shot: other), at: 20)?.id
                == "aim.onLine")
    }

    @Test("On line is not called for a blocked shot")
    func noOnLineWithoutAShotToMake() {
        var guidance = coach()
        let blocked = shot(blocker: .objectPath(BallID(4)))
        _ = guidance.next(for: playing(nudge: .onLine, shot: blocked), at: 0)
        #expect(guidance.next(for: playing(nudge: .onLine, shot: blocked), at: 30) == nil)
    }

    // MARK: Setup prompts — "what is expected next"

    @Test("The corner countdown counts down")
    func cornerPrompts() {
        var guidance = coach(.keyMoments)
        var time = 0.0
        var said: [String] = []
        for placed in 0...4 {
            time += 10
            if let line = guidance.next(for: .init(stage: .placingCorners(placed: placed)),
                                        at: time) {
                said.append(line.text)
            }
        }
        #expect(said == [
            "Tap the four corners of the playing surface, where the cushions meet.",
            "Three more corners.",
            "Two more corners.",
            "One more corner."
        ])
    }

    @Test("Every setup stage that expects something says what it expects")
    func setupPrompts() {
        let stages: [GuidanceStage] = [.findingTable, .needsCalibration, .confirmingRails,
                                       .awaitingCueBall, .degraded(.fastMotion),
                                       .degraded(.lowLight), .degraded(.trackingLost)]
        for (index, stage) in stages.enumerated() {
            var guidance = coach(.keyMoments)
            let line = guidance.next(for: .init(stage: stage), at: TimeInterval(index))
            #expect(line != nil, "\(stage) said nothing")
            #expect(line?.priority == .moment)
        }
    }

    @Test("Launching and plain tracking have nothing to ask for")
    func silentStages() {
        var guidance = coach()
        #expect(guidance.next(for: .init(stage: .starting), at: 0) == nil)
        #expect(guidance.next(for: .init(stage: .tracking), at: 10) == nil)
    }

    // MARK: The copy itself

    @Test("Nothing spoken contains a character a synthesizer would mangle")
    func copyIsSpeakable() {
        let situations: [SpokenGuidance.Situation] = [
            .init(stage: .findingTable), .init(stage: .needsCalibration),
            .init(stage: .placingCorners(placed: 0)), .init(stage: .placingCorners(placed: 3)),
            .init(stage: .confirmingRails), .init(stage: .awaitingCueBall),
            .init(stage: .degraded(.lowLight)), .init(stage: .degraded(.fastMotion)),
            .init(stage: .degraded(.trackingLost)),
            playing(), playing(chosenByPlayer: true),
            playing(nudge: .onLine), playing(nudge: .left(degrees: 2)),
            playing(nudge: .right(degrees: 20)),
            playing(shot: shot(blocker: .cutTooThin)),
            playing(shot: shot(blocker: .pocketFacingAway)),
            playing(shot: shot(blocker: .cuePath(BallID(2)))),
            playing(shot: shot(blocker: .objectPath(BallID(2))))
        ]
        var time = 0.0
        var spoken: [String] = []
        for situation in situations {
            var guidance = coach()
            time += 10
            if let line = guidance.next(for: situation, at: time) { spoken.append(line.text) }
        }
        #expect(spoken.count == situations.count)
        for text in spoken {
            #expect(!text.contains("%"), "\(text) has a percent sign in it")
            #expect(!text.contains("—"), "\(text) has an em dash in it")
            #expect(!text.contains("°"), "\(text) has a degree sign in it")
            #expect(text.hasSuffix("."), "\(text) does not end")
            #expect(text.first?.isUppercase == true, "\(text) does not start")
        }
    }

    @Test("The spoken shot line carries the same facts as the HUD headline")
    func spokenLineTracksTheHeadline() {
        let open = shot(probability: 0.62)
        #expect(open.headline == "62% into the top-left corner")
        #expect(open.spokenLine(chosenByPlayer: false)
                == "Best shot, 62 percent into the top-left corner.")
        let thin = shot(blocker: .cutTooThin)
        #expect(thin.headline.contains("No angle"))
        #expect(thin.spokenLine(chosenByPlayer: false).hasPrefix("No angle there."))
    }

    // MARK: Housekeeping

    @Test("Reset forgets what was said and every hold")
    func resetForgets() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: playing(), at: 0) != nil)
        #expect(guidance.next(for: playing(), at: 1) == nil)
        guidance.reset()
        #expect(guidance.next(for: playing(), at: 1) != nil)
    }

    @Test("Changing the level starts a fresh conversation")
    func changingVerbosityResets() {
        var guidance = coach(.keyMoments)
        #expect(guidance.next(for: playing(), at: 0) != nil)
        guidance.update(verbosity: .coaching)
        #expect(guidance.next(for: playing(), at: 0.1) != nil)
        // A no-op change keeps the history.
        guidance.update(verbosity: .coaching)
        #expect(guidance.next(for: playing(), at: 20) == nil)
    }

    @Test("Turning it off clears the history so it does not resume mid-thought")
    func offClearsState() {
        var guidance = coach(.keyMoments)
        _ = guidance.next(for: playing(), at: 0)
        guidance.verbosity = .off
        #expect(guidance.next(for: playing(), at: 1) == nil)
        guidance.verbosity = .keyMoments
        #expect(guidance.next(for: playing(), at: 2) != nil)
    }

    @Test("Verbosity levels describe themselves for the picker")
    func verbosityCopy() {
        #expect(SpeechVerbosity.allCases.count == 3)
        for level in SpeechVerbosity.allCases {
            #expect(!level.title.isEmpty)
            #expect(!level.detail.isEmpty)
        }
        #expect(SpeechVerbosity.off.isOn == false)
        #expect(SpeechVerbosity.keyMoments.speaksNudges == false)
        #expect(SpeechVerbosity.coaching.speaksNudges)
    }

    @Test("An aim nudge reports its own size and side")
    func nudgeAccessors() {
        #expect(AimNudge.onLine.degrees == 0)
        #expect(AimNudge.onLine.side == nil)
        #expect(AimNudge.left(degrees: 4).side == "left")
        #expect(AimNudge.right(degrees: 4).degrees == 4)
    }
}
