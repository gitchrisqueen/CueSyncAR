//
//  BallColourFixTests.swift
//  PerceptionKitTests
//
//  The measured ball-colour fix: the eight-ball is decided on the AVERAGE
//  colour of the ball relative to the cue ball, never on a count of single
//  pixels that looked coloured. On the owner's black-cloth table a dark
//  BLUE ball was named the 8-ball at 0.9 confidence because H.264 noise put
//  most of its individual pixels under the chroma floor.
//
//  Three layers, none using an image file:
//  - synthetic painted balls (navy, eight with a number disc and a
//    specular highlight, red, maroon, orange, cue) through the real sampler
//    and classifier;
//  - numbers measured from the research's hand-labelled frames
//    (MeasuredBallPatches.swift);
//  - the temporal guard in BallIdentity and the cue-ball fallback in
//    BallAppearancePass.
//

import CueSyncCore
import Foundation
import Testing

@testable import PerceptionKit

// MARK: - Synthetic balls

/// A small canvas of RGB triples, painted back to front.
private struct Canvas: PixelSampling {
    let pixelWidth = 400
    let pixelHeight = 120
    var pixels: [Vec3]

    init(cloth: Vec3 = Vec3(0.02, 0.02, 0.02)) {
        pixels = Array(repeating: cloth, count: 400 * 120)
    }

    func rgb(x: Int, y: Int) -> Vec3? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        return pixels[y * pixelWidth + x]
    }

    mutating func disc(x: Double, y: Double, radius: Double, colour: Vec3) {
        for row in Int(y - radius) - 1...Int(y + radius) + 1 {
            for column in Int(x - radius) - 1...Int(x + radius) + 1 {
                let dx = Double(column) + 0.5 - x
                let dy = Double(row) + 0.5 - y
                guard dx * dx + dy * dy <= radius * radius,
                      column >= 0, row >= 0, column < pixelWidth, row < pixelHeight else { continue }
                pixels[row * pixelWidth + column] = colour
            }
        }
    }

    /// A ball of radius 14 at (`x`, 60): its body, an optional white
    /// number disc at the centre (the eight's), and an optional specular
    /// highlight up and left of centre (the lamp, which the sampler drops).
    mutating func ball(x: Double, body: Vec3, numberDisc: Bool = false, specular: Bool = false,
                       light: Vec3 = Vec3(1, 1, 1)) {
        disc(x: x, y: 60, radius: 14, colour: body.lit(light))
        if numberDisc { disc(x: x, y: 60, radius: 4.2, colour: Vec3(0.72, 0.72, 0.70).lit(light)) }
        if specular { disc(x: x - 5, y: 55, radius: 2.2, colour: Vec3(1, 1, 1)) }
    }

    func patch(x: Double) -> BallPatch? {
        BallPatchSampler.sample(
            box: NormalizedRect(x: (x - 14) / 400, y: (60 - 14) / 120,
                                width: 28 / 400, height: 28 / 120),
            from: self)
    }
}

private extension Vec3 {
    /// The scene's illuminant: per-channel gain, clipped at 1.
    func lit(_ light: Vec3) -> Vec3 {
        Vec3(Swift.min(1, x * light.x), Swift.min(1, y * light.y), Swift.min(1, z * light.z))
    }
}

private enum Palette {
    static let cue = Vec3(0.70, 0.68, 0.64)
    /// Dark navy: relative chroma 0.29, inside the measured blue band
    /// 0.24-0.31, and dim enough (value 0.44 of the cue) for every rule
    /// that looks at darkness to like it.
    static let navy = Vec3(0.10, 0.20, 0.30)
    /// Near-black with a faint warm cast, as the measured eights are.
    static let eight = Vec3(0.17, 0.15, 0.18)
    static let red = Vec3(0.80, 0.20, 0.18)
    static let maroon = Vec3(0.40, 0.10, 0.09)
    static let orange = Vec3(0.85, 0.45, 0.08)
}

@Suite("Ball colour: the eight is decided on mean colour relative to the cue ball")
struct BallColourSyntheticTests {
    private func classified(_ body: Vec3, numberDisc: Bool = false, specular: Bool = false,
                            light: Vec3 = Vec3(1, 1, 1))
        throws -> (observation: AppearanceObservation, chroma: Double, value: Double) {
        var canvas = Canvas()
        canvas.ball(x: 40, body: Palette.cue, specular: true, light: light)
        canvas.ball(x: 120, body: body, numberDisc: numberDisc, specular: specular, light: light)
        let cue = try #require(canvas.patch(x: 40))
        let ball = try #require(canvas.patch(x: 120))
        let reference = WhiteReference(meanRGB: cue.meanRGB)
        let relative = try #require(BallAppearance.relativeColour(of: ball, reference: reference))
        let observation = try #require(BallAppearance.classify(ball, reference: reference))
        return (observation, relative.chroma, relative.value)
    }

    @Test("A dark navy ball is blue, not the eight, with margin to spare")
    func navyIsNotTheEight() throws {
        let result = try classified(Palette.navy)
        #expect(result.observation.family == .blue)
        let ceiling = BallAppearance.Config.default.blackMeanChromaCeiling
        #expect(result.chroma > ceiling * 1.5, "chroma \(result.chroma)")
    }

    @Test("A near-black ball with a white number disc and a specular highlight is the eight")
    func eightWithNumberDiscAndHighlight() throws {
        let result = try classified(Palette.eight, numberDisc: true, specular: true)
        #expect(result.observation.family == .black)
        #expect(result.observation.confidence >= 0.9)
        let ceiling = BallAppearance.Config.default.blackMeanChromaCeiling
        // Inside the measured eight band (0.020-0.079), about 2.6x under the line.
        #expect(result.chroma < 0.08, "chroma \(result.chroma)")
        #expect(result.chroma < ceiling / 1.8)
        #expect(result.value < BallAppearance.Config.default.blackRelativeValueCeiling)
    }

    @Test("The same verdicts hold under warm tungsten light, because everything is relative")
    func verdictsSurviveWarmLight() throws {
        let warm = Vec3(1.35, 1.0, 0.62)
        #expect(try classified(Palette.navy, light: warm).observation.family == .blue)
        #expect(try classified(Palette.eight, numberDisc: true, specular: true,
                               light: warm).observation.family == .black)
    }

    @Test("Red, maroon and orange are never the eight, and keep their own names")
    func warmBallsAreNotBlack() throws {
        #expect(try classified(Palette.red).observation.family == .red)
        #expect(try classified(Palette.maroon).observation.family == .maroon)
        #expect(try classified(Palette.orange).observation.family == .orange)
    }

    @Test("Red against maroon follows brightness relative to the cue ball, not absolute brightness")
    func redMaroonIsRelativeToTheCue() throws {
        // The same two balls under light half as bright: absolute value
        // would call the red a maroon (value 0.40 is under the old 0.55).
        let dim = Vec3(0.5, 0.5, 0.5)
        #expect(try classified(Palette.red, light: dim).observation.family == .red)
        #expect(try classified(Palette.maroon, light: dim).observation.family == .maroon)
    }

    @Test("The cue ball reads white against itself")
    func cueIsWhite() throws {
        var canvas = Canvas()
        canvas.ball(x: 40, body: Palette.cue, specular: true)
        let cue = try #require(canvas.patch(x: 40))
        let observation = try #require(
            BallAppearance.classify(cue, reference: WhiteReference(meanRGB: cue.meanRGB)))
        #expect(observation.family == .white)
    }

    @Test("A bright neutral ball is white, never black")
    func brightNeutralIsWhiteNotBlack() throws {
        // chroma ~0, value 0.8 of the cue: neutral, but far too bright
        // for the eight.
        let result = try classified(Vec3(0.56, 0.54, 0.51))
        #expect(result.observation.family == .white)
    }
}

// MARK: - Measured vectors

@Suite("Ball colour on measured frames (numbers from the research labels)")
struct BallColourMeasuredTests {
    private func whiteReference(in frame: [MeasuredBall]) -> WhiteReference? {
        frame.first(where: \.isCue).map { WhiteReference(meanRGB: $0.patch.meanRGB) }
    }

    /// The old per-pixel rule, kept here only to show what it did.
    private func legacyCallsBlack(_ patch: BallPatch, reference: WhiteReference) -> Bool {
        guard let balanced = reference.balanced(patch.meanRGB) else { return false }
        let value = max(balanced.x, balanced.y, balanced.z)
        return patch.chromaFraction <= 0.15 && value <= 0.45
    }

    @Test("iPad session: every one of the 66 non-cue balls gets its labelled colour (34 did before)")
    func ipadSessionAllCorrect() throws {
        var correct = 0
        var total = 0
        for frame in MeasuredBall.frames(MeasuredBall.ipadSession) {
            let reference = try #require(whiteReference(in: frame.balls))
            for ball in frame.balls where !ball.isCue {
                total += 1
                let observation = BallAppearance.classify(ball.patch, reference: reference)
                if observation?.family == ball.family { correct += 1 }
            }
        }
        #expect(total == 66)
        #expect(correct == 66)
    }

    @Test("iPad session: the dark blue ball is never the eight, in any of 22 frames")
    func blueIsNeverBlack() throws {
        var legacyBlack = 0
        var chromas: [Double] = []
        for frame in MeasuredBall.frames(MeasuredBall.ipadSession) {
            let reference = try #require(whiteReference(in: frame.balls))
            for ball in frame.balls where ball.label == "blue" {
                #expect(BallAppearance.classify(ball.patch, reference: reference)?.family == .blue)
                if legacyCallsBlack(ball.patch, reference: reference) { legacyBlack += 1 }
                let relative = try #require(
                    BallAppearance.relativeColour(of: ball.patch, reference: reference))
                chromas.append(relative.chroma)
            }
        }
        #expect(chromas.count == 22)
        // Reproduces the reported bug: the per-pixel rule named this ball
        // black in 17 of 22 frames.
        #expect(legacyBlack == 17)
        // Measured 0.236-0.313, so at least 1.5x clear of the 0.15 line.
        let ceiling = BallAppearance.Config.default.blackMeanChromaCeiling
        #expect((chromas.min() ?? 0) > ceiling * 1.5)
    }

    @Test("Clips: all 8 true eight-balls are black and nothing else is, with 3x margin each side")
    func eightsAndOnlyEights() throws {
        var eights = 0
        var eightChroma: [Double] = []
        for frame in MeasuredBall.frames(MeasuredBall.clips) {
            let reference = try #require(whiteReference(in: frame.balls))
            for ball in frame.balls where !ball.isCue {
                let observation = BallAppearance.classify(ball.patch, reference: reference)
                if ball.label == "black" {
                    eights += 1
                    #expect(observation?.family == .black, "\(ball.frame) eight")
                    let relative = try #require(
                        BallAppearance.relativeColour(of: ball.patch, reference: reference))
                    eightChroma.append(relative.chroma)
                } else {
                    #expect(observation?.family != .black, "\(ball.frame) \(ball.label)")
                }
            }
        }
        #expect(eights == 8)
        let ceiling = BallAppearance.Config.default.blackMeanChromaCeiling
        // Measured eights 0.020-0.079.
        #expect((eightChroma.max() ?? 1) < ceiling / 1.8)
    }

    @Test("The brightest, least-coloured ball is the cue ball in 31 of 31 labelled frames")
    func cuePickOnMeasuredFrames() {
        var right = 0
        var frames = 0
        for set in [MeasuredBall.clips, MeasuredBall.ipadSession] {
            for frame in MeasuredBall.frames(set) {
                frames += 1
                let candidates = frame.balls.enumerated().map { index, ball in
                    (id: BallID(index + 1), patch: ball.patch)
                }
                guard let pick = BallAppearancePass.brightestLeastColoured(in: candidates),
                      let chosen = frame.balls.indices.first(where: { BallID($0 + 1) == pick })
                else { continue }
                if frame.balls[chosen].isCue { right += 1 }
            }
        }
        #expect(frames == 31)
        #expect(right == 31)
    }

    @Test("The cue pick refuses a lone ball and a dead heat rather than guess")
    func cuePickRefusesWhenUnsure() throws {
        let cue = BallPatch(meanRGB: Vec3(0.65, 0.63, 0.60), whiteFraction: 0.9,
                            chromaFraction: 0, sampleCount: 300)
        #expect(BallAppearancePass.brightestLeastColoured(in: [(BallID(1), cue)]) == nil)
        #expect(BallAppearancePass.brightestLeastColoured(
            in: [(BallID(1), cue), (BallID(2), cue)]) == nil)
    }
}

// MARK: - Temporal guard

@Suite("Ball colour: a name changes only after consecutive agreeing looks")
struct BallColourVotingTests {
    private let ball = BallID(7)

    private func look(_ family: ColorFamily, _ confidence: Double = 0.9) -> AppearanceObservation {
        AppearanceObservation(family: family, confidence: confidence, whiteFraction: 0.05)
    }

    @Test("The first name is not held back: it commits at the minimum number of looks")
    func firstNameIsImmediate() {
        var identity = BallIdentity()
        for _ in 0..<4 { identity.observe(look(.blue), for: ball) }
        #expect(identity.family(for: ball) == nil)
        identity.observe(look(.blue), for: ball)
        #expect(identity.family(for: ball)?.family == .blue)
        #expect(identity.record(for: ball)?.committedFamily == .blue)
    }

    @Test("A ball named the eight stays the eight until another colour has led five looks running")
    func eightHoldsUntilFiveConsecutiveLooks() {
        let config = BallIdentity.Config(window: 10, minimumObservations: 5,
                                         switchObservations: 5)
        var identity = BallIdentity(config: config)
        for _ in 0..<10 { identity.observe(look(.black), for: ball) }
        #expect(identity.kind(for: ball) == .eight)
        var renamedAt: Int?
        for step in 1...10 {
            identity.observe(look(.blue), for: ball)
            if identity.family(for: ball)?.family != .black, renamedAt == nil { renamedAt = step }
        }
        // Blue first LEADS the 10-look window at the sixth look (6 vs 4);
        // the name moves on the fifth consecutive lead, the tenth look.
        #expect(renamedAt == 10)
        #expect(identity.kind(for: ball) == .solid(2))
    }

    @Test("Without the guard the same sequence renames four looks earlier")
    func guardIsWhatDelaysTheSwitch() {
        let config = BallIdentity.Config(window: 10, minimumObservations: 5,
                                         switchObservations: 1)
        var identity = BallIdentity(config: config)
        for _ in 0..<10 { identity.observe(look(.black), for: ball) }
        var renamedAt: Int?
        for step in 1...10 {
            identity.observe(look(.blue), for: ball)
            if identity.family(for: ball)?.family != .black, renamedAt == nil { renamedAt = step }
        }
        #expect(renamedAt == 6)
    }

    @Test("A vote that keeps crossing back and forth does not flip the label")
    func flickerDoesNotFlip() {
        func run(switchObservations: Int) -> Set<ColorFamily> {
            let config = BallIdentity.Config(window: 4, minimumObservations: 4,
                                             switchObservations: switchObservations)
            var identity = BallIdentity(config: config)
            for _ in 0..<4 { identity.observe(look(.black), for: ball) }
            var seen: Set<ColorFamily> = []
            // Three blue, then a repeating black, black, blue, blue: the
            // leader changes but never holds for five looks.
            let sequence: [ColorFamily] = [.blue, .blue, .blue] + Array(
                repeating: [ColorFamily.black, .black, .blue, .blue], count: 4).flatMap { $0 }
            for family in sequence {
                identity.observe(look(family), for: ball)
                if let named = identity.family(for: ball)?.family { seen.insert(named) }
            }
            return seen
        }
        #expect(run(switchObservations: 5) == [.black])
        #expect(run(switchObservations: 1).contains(.blue), "the unguarded vote does flip")
    }

    @Test("A challenged name reads as less certain while it is being challenged")
    func challengeLowersConfidence() {
        let config = BallIdentity.Config(window: 10, minimumObservations: 5,
                                         switchObservations: 5)
        var identity = BallIdentity(config: config)
        for _ in 0..<10 { identity.observe(look(.black), for: ball) }
        let settled = identity.family(for: ball)?.confidence ?? 0
        for _ in 0..<6 { identity.observe(look(.blue), for: ball) }
        let challenged = identity.family(for: ball)
        #expect(challenged?.family == .black)
        #expect((challenged?.confidence ?? 1) < settled)
        #expect(identity.isTentative(for: ball))
    }

    @Test("A tap still wins over everything, guard or no guard")
    func tapOverrideIsUntouched() {
        var identity = BallIdentity()
        for _ in 0..<10 { identity.observe(look(.black), for: ball) }
        identity.setOverride(.solid(2), for: ball)
        for _ in 0..<10 { identity.observe(look(.black), for: ball) }
        #expect(identity.kind(for: ball) == .solid(2))
        #expect(!identity.isTentative(for: ball))
    }
}

// MARK: - Cue-ball fallback in the pass

private struct DiscImage: PixelSampling {
    let pixelWidth = 400
    let pixelHeight = 300
    var discs: [(centre: Vec2, colour: Vec3)] = []

    func rgb(x: Int, y: Int) -> Vec3? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        for disc in discs {
            let dx = Double(x) + 0.5 - disc.centre.x
            let dy = Double(y) + 0.5 - disc.centre.y
            if dx * dx + dy * dy <= 18 * 18 { return disc.colour }
        }
        return Vec3(0.02, 0.02, 0.02)
    }
}

@Suite("Ball appearance pass: cue ball inferred only when nothing named one")
struct CueBallFallbackTests {
    /// A cue-coloured ball, a navy ball and an eight, three tracked balls
    /// whose detections all carry the class `unknown` (the detector found
    /// no white-ball), and whose table positions are far apart.
    private func scene(detectionKinds: [Ball.Kind] = [.unknown, .unknown, .unknown],
                       trackedKinds: [Ball.Kind] = [.unknown, .unknown, .unknown],
                       colours: [Vec3] = [Palette.cue, Palette.navy, Vec3(0.19, 0.17, 0.20)])
        -> (image: DiscImage, balls: [Ball], detections: [LocatedDetection]) {
        var image = DiscImage()
        var balls: [Ball] = []
        var detections: [LocatedDetection] = []
        for index in 0..<3 {
            let centre = Vec2(80 + 120 * Double(index), 150)
            let position = Vec2(0.3 + 0.5 * Double(index), 0.4)
            image.discs.append((centre, colours[index]))
            balls.append(Ball(id: BallID(index + 1), kind: trackedKinds[index], position: position))
            detections.append(LocatedDetection(
                position: position,
                box: NormalizedRect(x: (centre.x - 18) / 400, y: (centre.y - 18) / 300,
                                    width: 36 / 400, height: 36 / 300),
                kind: detectionKinds[index]))
        }
        return (image, balls, detections)
    }

    @Test("With no white-ball from the detector the brightest, least coloured ball is the reference")
    func fallbackNamesEveryBall() {
        let (image, balls, detections) = scene()
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result[BallID(1)]?.family == .white)
        #expect(result[BallID(1)]?.confidence == BallAppearancePass.Config.default.inferredCueConfidence)
        #expect(result[BallID(2)]?.family == .blue)
        #expect(result[BallID(3)]?.family == .black)
    }

    @Test("A detector-named cue ball is never overridden by the fallback")
    func detectorCueWins() {
        // The detector calls the navy ball the cue ball. The brightest
        // ball is elsewhere, but it does not get to take the job.
        let (image, balls, detections) = scene(detectionKinds: [.unknown, .cue, .unknown])
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result[BallID(2)]?.family == .white)
        #expect(result[BallID(2)]?.confidence == 0.9)
        #expect(result[BallID(1)]?.confidence != BallAppearancePass.Config.default.inferredCueConfidence)
    }

    @Test("A player-designated cue ball is never overridden either")
    func designatedCueWins() {
        let (image, balls, detections) = scene(trackedKinds: [.unknown, .cue, .unknown])
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result[BallID(2)]?.confidence == 0.9)
    }

    @Test("A cue ball named but unreadable this frame leaves the frame unnamed, not guessed")
    func namedButUnreadableIsNotReplaced() {
        var (image, balls, detections) = scene(trackedKinds: [.unknown, .unknown, .unknown])
        // The tracked cue ball is somewhere no detection reaches.
        balls[0].kind = .cue
        balls[0].position = Vec2(1.9, 0.4)
        // The bright ball's own detection is gone too.
        detections.removeFirst()
        image.discs.removeFirst()
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result.isEmpty)
    }

    @Test("The fallback can be switched off, and a dead heat is not resolved by guessing")
    func offAndAmbiguous() {
        let (image, balls, detections) = scene()
        var off = BallAppearancePass.Config.default
        off.inferCueBall = false
        #expect(BallAppearancePass.run(balls: balls, detections: detections, image: image,
                                       config: off).isEmpty)

        let twins = scene(colours: [Palette.cue, Palette.cue, Palette.navy])
        #expect(BallAppearancePass.run(balls: twins.balls, detections: twins.detections,
                                       image: twins.image).isEmpty)
    }

    @Test("Four looks at an inferred cue ball name nothing; the fifth agreeing look does")
    func inferredCueNeedsAgreement() {
        let (image, balls, detections) = scene()
        var identity = BallIdentity()
        for look in 1...6 {
            identity.observe(BallAppearancePass.run(balls: balls, detections: detections,
                                                    image: image))
            let named = identity.kind(for: BallID(1))
            if look < 5 { #expect(named == .unknown, "look \(look)") } else {
                #expect(named == .cue, "look \(look)")
            }
        }
        #expect(identity.kind(for: BallID(3)) == .eight)
        #expect(identity.kind(for: BallID(2)) == .solid(2))
    }
}
