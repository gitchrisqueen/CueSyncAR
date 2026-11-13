//
//  HUDTruthTests.swift
//  CueSync AR
//
//  The HUD must not say things that are not true: "On line" only when it is,
//  one rule for ball counts, a make as an event, a hard shot that is not an
//  error, and sheet text a player can read.
//

import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

@Suite("On line is only said when it is true")
struct AimLineTests {

    private func line(calledMode: Bool = true, set: Bool, onLine: Bool = false,
                      correction: AimCorrection? = nil, forCalled: Bool = false) -> AimLine? {
        AimLine.resolve(calledShotMode: calledMode, calledPocketSet: set, calledPocketOnLine: onLine,
                        correction: correction, correctionIsForCalledPocket: forCalled)
    }

    @Test("Called-shot play with no pocket called says nothing in that slot")
    func noPocketNoLine() {
        #expect(line(set: false) == nil)
        // Even when the aim happens to match the suggested shot.
        #expect(line(set: false, correction: .onLine, forCalled: true) == nil)
        #expect(line(set: false, correction: .left(degrees: 3)) == nil)
    }

    @Test("On line only when the aim sends a ball into the called pocket")
    func onLineIsTheCalledPocket() {
        let on = line(set: true, onLine: true)
        #expect(on?.text == "On line")
        #expect(on?.tone == .good)
        // The suggested shot is on its own line, but the called pocket is
        // not: that is off line, not "On line".
        let off = line(set: true, onLine: false, correction: .onLine, forCalled: false)
        #expect(off?.text == "Off line")
        #expect(off?.tone == .caution)
    }

    @Test("Off line says which way only when the app knows")
    func offLineDirection() {
        #expect(line(set: true, correction: .left(degrees: 9), forCalled: true)?.text
                == "Off line — move your aim left")
        #expect(line(set: true, correction: .right(degrees: 2), forCalled: true)?.text
                == "Off line — move your aim right")
        // The correction is for a different pocket: the direction is unknown.
        #expect(line(set: true, correction: .left(degrees: 9), forCalled: false)?.text == "Off line")
        #expect(line(set: true, correction: nil, forCalled: true)?.text == "Off line")
        for forCalled in [true, false] {
            #expect(line(set: true, correction: .right(degrees: 9), forCalled: forCalled)?.tone == .caution)
        }
    }

    @Test("Free play keeps the aim against the suggested shot, in plain words")
    func freePlay() {
        #expect(line(calledMode: false, set: false, correction: .onLine)?.text == "On line")
        #expect(line(calledMode: false, set: false, correction: .onLine)?.tone == .good)
        let nudge = line(calledMode: false, set: false, correction: .right(degrees: 12))
        #expect(nudge?.text == "Move your aim right")
        #expect(nudge?.tone == .neutral)
        #expect(line(calledMode: false, set: false, correction: .left(degrees: 2))?.text
                == "Move your aim a little left")
        #expect(line(calledMode: false, set: false, correction: nil) == nil)
    }

    @Test("The words name what to move")
    func wordsAreUnambiguous() {
        for text in [HUDCopy.aimMove(side: .left, degrees: 9), HUDCopy.aimMove(side: .right, degrees: 1)] {
            #expect(text.contains("your aim"), "\(text)")
            #expect(!text.hasPrefix("Aim "), "\(text)")
            #expect(PlayerCopyAudit.violations(in: text).isEmpty)
        }
    }
}

@Suite("Ball counts use one rule")
struct BallCountRuleTests {

    private func state(cue: Bool, objects: Int) -> TableState {
        var balls: [Ball] = (0..<objects).map {
            Ball(id: BallID(100 + $0), kind: .unknown, position: Vec2(Double($0) * 0.1, 0.2))
        }
        if cue { balls.append(Ball(id: BallID(0), kind: .cue, position: .zero)) }
        return TableState(table: Table(size: .nineFoot), balls: balls, timestamp: 0)
    }

    @Test("A full rack is 15 balls, the cue ball not counted")
    func rack() {
        #expect(state(cue: true, objects: 15).objectBallCount == 15)
        #expect(state(cue: true, objects: 15).balls.count == 16)
    }

    @Test("With no cue ball tracked, every ball is an object ball")
    func noCue() {
        #expect(state(cue: false, objects: 4).objectBallCount == 4)
    }

    @Test("The cue ball alone is zero balls")
    func cueOnly() {
        #expect(state(cue: true, objects: 0).objectBallCount == 0)
        #expect(HUDStatus.tracking(ballCount: 0).label == "No balls to shoot at")
    }

    @Test("The capsule and the loss message count the same things")
    func sameDenominator() {
        let full = state(cue: true, objects: 15)
        let seen = state(cue: true, objects: 1)
        // What the capsule shows when healthy, and what "only seeing" shows
        // when the detector has dropped to one ball.
        #expect(HUDStatus.tracking(ballCount: full.objectBallCount).label == "Tracking 15 balls")
        #expect(HUDStatus.losingBalls(seen: seen.objectBallCount, peak: full.objectBallCount, dark: false).label
                == "Only seeing 1 of 15 balls")
    }
}

@Suite("A make is an event")
struct PayoffTests {

    @Test("Words and tones")
    func words() {
        let made = PayoffEvent(id: 1, kind: .made, streak: 1, made: 1, attempted: 1)
        #expect(made.headline == "MADE IT")
        #expect(made.detail == "+1")
        #expect(made.tone == .good)
        #expect(made.isCelebration)
        let streak = PayoffEvent(id: 2, kind: .made, streak: 3, made: 3, attempted: 3)
        #expect(streak.detail == "+1 · 3 IN A ROW")
        #expect(PayoffEvent(id: 3, kind: .madeOther).headline == "BALL DOWN")
        let missed = PayoffEvent(id: 4, kind: .missed)
        #expect(missed.headline == "MISSED")
        #expect(missed.tone == .caution)
        #expect(!missed.isCelebration)
        let scratch = PayoffEvent(id: 5, kind: .scratch)
        #expect(scratch.headline == "SCRATCH")
        #expect(scratch.tone == .bad)
        #expect(!scratch.isCelebration)
    }

    @Test("Meaning is never colour alone: each outcome has its own word and symbol")
    func wordsAndSymbolsAreDistinct() {
        let kinds: [PayoffEvent.Kind] = [.made, .missed, .scratch]
        let events = kinds.map { PayoffEvent(id: 0, kind: $0) }
        #expect(Set(events.map(\.headline)).count == 3)
        #expect(Set(events.map(\.symbol)).count == 3)
    }

    @Test("It holds the slot for about 1.2 seconds, whatever happened")
    func timing() {
        for kind in PayoffEvent.Kind.allCases {
            let hold = PayoffTiming.holdSeconds(for: kind)
            #expect(abs(hold - 1.2) < 0.2, "\(kind): \(hold)")
        }
    }

    @Test("Reduce Motion: no swell, a shorter fade")
    func reduceMotion() {
        #expect(!PayoffTiming.scalesIn(reduceMotion: true))
        #expect(PayoffTiming.scalesIn(reduceMotion: false))
        #expect(PayoffTiming.fadeSeconds(reduceMotion: true) < PayoffTiming.fadeSeconds(reduceMotion: false))
    }

    @Test("What VoiceOver reads names the outcome")
    func spoken() {
        #expect(PayoffEvent(id: 1, kind: .made, streak: 2).spokenText == "Made It. +1 · 2 IN A ROW")
        #expect(PayoffEvent(id: 1, kind: .missed).spokenText.contains("Missed"))
        for kind in PayoffEvent.Kind.allCases {
            let event = PayoffEvent(id: 0, kind: kind, streak: 2)
            #expect(PlayerCopyAudit.violations(in: event.headline).isEmpty)
            #expect(PlayerCopyAudit.violations(in: event.detail ?? "").isEmpty)
        }
    }
}

@Suite("HARD is not an error")
struct HardIsNotAnErrorTests {

    @Test("HARD, BLOCKED and FAIR each have their own colour")
    func ownColours() {
        let tokens = [ShotConfidence.easy, .medium, .hard, .blocked].map(\.token.rgb)
        #expect(Set(tokens).count == 4)
        let texts = [ShotConfidence.easy, .medium, .hard, .blocked].map(\.textToken.rgb)
        #expect(Set(texts).count == 4)
    }

    @Test("HARD's text clears the contrast floor on the plate")
    func hardTextContrast() {
        let backdrop = Contrast.composite(Theme.hudScrim, alpha: Theme.hudScrimOpacity, over: .white)
        #expect(Contrast.ratio(Theme.hardTierText, backdrop) >= Contrast.aa)
    }

    @Test("The shape and the word still separate HARD from BLOCKED")
    func shapeAndWord() {
        #expect(ShotConfidence.hard.tierSymbol != ShotConfidence.blocked.tierSymbol)
        #expect(ShotConfidence.hard.tierWord != ShotConfidence.blocked.tierWord)
    }
}

@Suite("Sheet text is readable")
struct SheetStyleTests {

    @Test("Footnotes and headers are at least 4.5 : 1 on the grouped background, light and dark")
    func footnoteContrast() {
        let light = Contrast.ratio(Theme.sheetSecondaryLight, Contrast.RGB(Theme.sheetGroundLight))
        let dark = Contrast.ratio(Theme.sheetSecondaryDark, Contrast.RGB(Theme.sheetGroundDark))
        #expect(light >= Contrast.aa, "light \(light)")
        #expect(dark >= Contrast.aa, "dark \(dark)")
        // The system secondary grey this replaces measured 3.29 : 1.
        let system = Contrast.ratio(ColorToken(0x85858B), Contrast.RGB(Theme.sheetGroundLight))
        #expect(system < Contrast.aa)
    }

    @Test("Settings copy is in player words")
    func playerWords() {
        let text = SheetCopy.Settings.all.joined(separator: " ").lowercased()
        for banned in ["parked", "path budget", "ricochet", "remembered table", "grace", "guide speed",
                       "m/s", "snapped"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        #expect(SheetCopy.Settings.deviceParked == "Device on a stand")
        #expect(SheetCopy.Settings.shotStrength == "Shot strength")
    }

    @Test("Shot strength reads as a word across the slider's range")
    func shotStrength() {
        let range = 1.0...6.0
        #expect(HUDCopy.shotStrengthWord(speed: 1.0, range: range) == "Soft")
        #expect(HUDCopy.shotStrengthWord(speed: 3.5, range: range) == "Medium")
        #expect(HUDCopy.shotStrengthWord(speed: 6.0, range: range) == "Firm")
        #expect(HUDCopy.shotStrengthWord(speed: 2.0, range: 2.0...2.0) == "Medium")
    }
}

#if canImport(SwiftUI)
@Suite("The shot card tells the truth")
struct ShotCardTruthTests {

    @Test("A blocked card names the ball, then why")
    func blockedNamesTheBall() {
        let card = ShotCard(ball: "Red ball", leadBall: "3 Red", pocket: nil, confidence: .blocked,
                            chosenByPlayer: true, blockedReason: "A ball is in the way")
        #expect(card.headline == "3 RED")
        #expect(card.accessibilityText == "Red ball: A ball is in the way")
        #expect(card.calledLine == nil)
    }

    @Test("The headline leads with the number when it is known, the colour alone when not")
    func headlineLeads() {
        #expect(ShotCard(ball: "Maroon ball", leadBall: "7 Maroon", pocket: "left side pocket",
                         confidence: .easy, chosenByPlayer: false).headline == "7 MAROON → LEFT SIDE")
        #expect(ShotCard(ball: "Maroon ball", pocket: "left side pocket", confidence: .easy,
                         chosenByPlayer: false).headline == "MAROON → LEFT SIDE")
        #expect(ShotCard(ball: "8-ball", leadBall: "8-ball", pocket: "far side pocket", confidence: .easy,
                         chosenByPlayer: false).headline == "8-BALL → FAR SIDE")
        // No colour, no number: no invented colour.
        #expect(ShotCard(ball: "Ball", leadBall: "Ball", pocket: nil, confidence: .easy,
                         chosenByPlayer: false).headline == "BALL")
    }

    @Test("The called pocket has its own line")
    func calledLine() {
        let card = ShotCard(ball: "Red ball", pocket: "far-right corner", confidence: .medium,
                            chosenByPlayer: false, calledPocket: "far-right corner")
        #expect(card.calledLine == "CALLED: FAR-RIGHT CORNER")
        #expect(ShotCard(ball: "Red ball", pocket: nil, confidence: .medium, chosenByPlayer: false)
                    .calledLine == nil)
    }

    @Test("The headline length bound holds with numbers in front")
    func lengthWithNumbers() {
        var longest = 0
        for ball in ["15 Maroon stripe", "9 Yellow stripe", "10 Blue stripe", "14 Green stripe"] {
            for pocket in ["near-right corner", "far-left corner", "left side pocket"] {
                let line = HUDCopy.headline(ball: ball, pocket: pocket) ?? ""
                longest = max(longest, line.count)
                #expect(line.count <= HUDCopy.headlineMaxLength, "\(line)")
            }
        }
        #expect(longest <= 38)
    }
}
#endif
