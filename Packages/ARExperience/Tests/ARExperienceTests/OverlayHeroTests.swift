import BilliardsPhysics
import CueSyncCore
import CueSyncUI
import Foundation
import TableSpace
import Testing
@testable import ARExperience

// "One bright line to follow and one pocket to hit; everything else quiet or
// gone." These tests hold the overlay to that, on a 15-ball table like the
// one on the real iPad, with no rendering involved.

private let cueID = BallID(0)
private let solver = AnalyticSolver()

/// Table in the world xz-plane (y up), centred on the origin, so a table
/// point (x, y) is world (x, 0, -y).
private let calibration = TableCalibration(origin: .zero,
                                           xAxis: Vec3(1, 0, 0),
                                           yAxis: Vec3(0, 0, -1),
                                           size: .eightFoot)

/// The cue ball plus fifteen object balls on the diamond-line grid the
/// device runs use (rows x = k L/8 for k in 3, 2, 0, -2, -3; columns
/// y = j W/8 for j in 1, 0, -1), the cue ball off the grid.
private func fifteenBallState() -> TableState {
    let table = Table(size: .eightFoot)
    let (length, width) = (table.size.playField.width, table.size.playField.height)
    var balls = [Ball(id: cueID, kind: .cue, position: Vec2(0.3, 0.07))]
    var next = 1
    for k in [3.0, 2.0, 0.0, -2.0, -3.0] {
        for j in [1.0, 0.0, -1.0] {
            balls.append(Ball(id: BallID(next), kind: .solid(next),
                              position: Vec2(k * length / 8, j * width / 8)))
            next += 1
        }
    }
    return TableState(table: table, balls: balls, timestamp: 0)
}

/// The shot the ranking would suggest: `ball` into `pocket`.
private func suggestion(state: TableState, ball: BallID,
                        pocket: PocketID) throws -> OverlayLayout.Target {
    let object = try #require(state.ball(ball))
    let hole = try #require(state.table.pockets.first { $0.id == pocket })
    let ghost = object.position
        - (hole.position - object.position).normalized * (2 * object.radius)
    let prediction = try #require(TargetGuide.plan(state: state, ghostBall: ghost,
                                                   solver: solver, speed: 3.5))
    return OverlayLayout.Target(prediction: prediction, ball: ball, pocket: pocket,
                                ghostBall: ghost)
}

/// A live aim that really hits something, so it has a ghost ball, a ricochet
/// and a struck ball's path: the clutter the suggestion must silence.
private func busyLiveAim(_ state: TableState, at target: Vec2) -> ShotPrediction {
    let cue = state.cueBall?.position ?? .zero
    return solver.predict(state: state,
                          aim: AimRay(origin: cue, direction: target - cue),
                          options: SolverOptions(initialSpeed: 3.5, maxEvents: 8))
}

@Suite("Overlay: one line, one pocket")
struct OverlaySuggestionTests {

    @Test("15 balls and a suggestion: at most 2 primitives outside the shot, none under another ball")
    func quietTableWhileSuggesting() throws {
        let state = fifteenBallState()
        let target = try suggestion(state: state, ball: BallID(7), pocket: .cornerTopLeft)
        let object = try #require(state.ball(BallID(7)))
        let live = busyLiveAim(state, at: object.position)
        #expect(live.firstContact != nil, "fixture: the live aim must hit the target ball")

        let layout = OverlayLayout.frame(state: state, calibration: calibration,
                                         prediction: live, showsShotGuides: true,
                                         target: target)
        #expect(layout.shotID == OverlayLayout.ShotID(ball: BallID(7), pocket: .cornerTopLeft))
        #expect(layout.primitivesOutsideSuggestion <= 2)

        // Rings: the cue ball and the target ball, nothing else.
        #expect(layout.balls.count == 2)
        #expect(layout.balls.filter(\.isCue).count == 1)
        #expect(layout.balls.filter(\.isTarget).count == 1)
        for ball in state.balls where ball.id != cueID && ball.id != BallID(7) {
            let world = calibration.tableToWorld(ball.position)
            #expect(!layout.balls.contains { $0.position.distance(to: world) < 1e-9 },
                    "ring under ball \(ball.id.rawValue)")
        }
        // The live ghost sphere (the "second ghost ball") and the predicted
        // pocket marks are gone; the ricochet and the object ball's own
        // predicted path are gone with them.
        #expect(layout.ghostBall == nil)
        #expect(layout.highlightedPockets.isEmpty)
        #expect(layout.strips.allSatisfy { $0.ballID == cueID && !$0.dashed })
    }

    @Test("Secondary lines come back only when asked for")
    func secondaryLinesAreOptIn() throws {
        let state = fifteenBallState()
        let target = try suggestion(state: state, ball: BallID(7), pocket: .cornerTopLeft)
        let object = try #require(state.ball(BallID(7)))
        let live = busyLiveAim(state, at: object.position)

        let quiet = OverlayLayout.frame(state: state, calibration: calibration,
                                        prediction: live, showsShotGuides: true, target: target)
        let loud = OverlayLayout.frame(state: state, calibration: calibration,
                                       prediction: live, showsShotGuides: true,
                                       target: target, showsSecondaryLines: true)
        #expect(loud.strips.count > quiet.strips.count)
        #expect(loud.ghostBall != nil)
        #expect(loud.primitivesOutsideSuggestion > quiet.primitivesOutsideSuggestion)
        // Turning them on never touches the hero or the rings.
        #expect(loud.targetPocket == quiet.targetPocket)
        #expect(loud.balls == quiet.balls)
        // Default is off: the parameter's default is the quiet table.
        let byDefault = OverlayLayout.compose(state: state, prediction: live,
                                              calibration: calibration, target: target)
        #expect(byDefault == quiet)
    }

    @Test("No suggestion: every ball keeps a thin ring so it can be tapped, and nothing is hidden")
    func ringsOnlyWithoutASuggestion() {
        let state = fifteenBallState()
        let live = busyLiveAim(state, at: Vec2(-0.56, 0))
        let layout = OverlayLayout.frame(state: state, calibration: calibration,
                                         prediction: live, showsShotGuides: true)
        #expect(layout.shotID == nil)
        #expect(layout.balls.count == 16)
        #expect(layout.balls.filter(\.isCue).count == 1)
        #expect(layout.balls.allSatisfy { !$0.isTarget })
        #expect(layout.targetStrips.isEmpty)
        #expect(layout.targetPocket == nil)
        #expect(!layout.strips.isEmpty)
    }

    @Test("Without shot guides (a game with friends) only rings are drawn")
    func gameModeIsRingsOnly() throws {
        let state = fifteenBallState()
        let target = try suggestion(state: state, ball: BallID(7), pocket: .cornerTopLeft)
        let layout = OverlayLayout.frame(state: state, calibration: calibration,
                                         prediction: busyLiveAim(state, at: Vec2(-0.56, 0)),
                                         showsShotGuides: false, target: target)
        #expect(layout.strips.isEmpty && layout.targetStrips.isEmpty)
        #expect(layout.ghostBall == nil && layout.targetPocket == nil)
        #expect(layout.balls.count == 16)
    }

    @Test("The object leg runs from the target's centre to the pocket's centre, within 1 mm")
    func objectLegEndPoints() throws {
        let state = fifteenBallState()
        for pocket in [PocketID.cornerTopLeft, .sideTop, .cornerBottomLeft] {
            let target = try suggestion(state: state, ball: BallID(7), pocket: pocket)
            let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                                 target: target)
            let leg = try #require(layout.targetStrips.last { $0.color == OverlayStyle.heroObjectColor })
            let ball = try #require(state.ball(BallID(7)))
            let hole = try #require(state.table.pockets.first { $0.id == pocket })
            #expect(leg.ballID == BallID(7))
            #expect(leg.start.distance(to: calibration.tableToWorld(ball.position)) < 0.001, "\(pocket)")
            #expect(leg.end.distance(to: calibration.tableToWorld(hole.position)) < 0.001, "\(pocket)")
            #expect(abs(leg.length - (hole.position - ball.position).length) < 0.001)
            #expect(!leg.dashed && leg.role == .plan)
        }
    }

    @Test("The cue leg is the other colour, so each meaning has its own")
    func legsHaveTheirOwnColours() throws {
        let state = fifteenBallState()
        let target = try suggestion(state: state, ball: BallID(7), pocket: .cornerTopLeft)
        let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration, target: target)
        let cueLeg = layout.targetStrips.filter { $0.ballID == cueID }
        let objectLeg = layout.targetStrips.filter { $0.ballID == BallID(7) }
        #expect(!cueLeg.isEmpty && objectLeg.count == 1)
        #expect(cueLeg.allSatisfy { $0.color == OverlayStyle.heroCueColor })
        #expect(objectLeg.allSatisfy { $0.color == OverlayStyle.heroObjectColor })
        // The cue leg ends at the ghost ball, where the cue ball has to arrive.
        let ghost = calibration.tableToWorld(target.ghostBall)
        #expect(try #require(cueLeg.last).end.distance(to: ghost) < 0.002)
    }

    @Test("The pocket marker is the capture radius, centred on the pocket")
    func pocketMarker() throws {
        let state = fifteenBallState()
        for pocket in state.table.pockets {
            let target = try suggestion(state: state, ball: BallID(7), pocket: pocket.id)
            let layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                                 target: target)
            let marker = try #require(layout.targetPocket)
            #expect(marker.radius == pocket.captureRadius, "\(pocket.id)")
            #expect(marker.position.distance(to: calibration.tableToWorld(pocket.position)) < 1e-9)
            // The hero line ends at the ring's centre.
            let leg = try #require(layout.targetStrips.last)
            #expect(leg.end.distance(to: marker.position) < 0.001)
        }
    }

    @Test("The ring on the pocket straddles the capture circle and is a ring, not a disc")
    func pocketRingGeometry() {
        for radius in [0.05, 0.065, 0.1] {
            let ring = OverlayStyle.pocketRing(captureRadius: radius)
            #expect(ring.inner > 0 && ring.inner < radius && ring.outer > radius)
            #expect(abs((ring.inner + ring.outer) / 2 - radius) < 1e-12)
            #expect(ring.outer - ring.inner <= 0.012, "thin")
        }
    }

    @Test("A suggestion hides nothing the player asked for: the called pocket stays")
    func calledPocketSurvives() throws {
        let state = fifteenBallState()
        let target = try suggestion(state: state, ball: BallID(7), pocket: .cornerTopLeft)
        let layout = OverlayLayout.frame(state: state, calibration: calibration,
                                         prediction: busyLiveAim(state, at: Vec2(0, 0)),
                                         showsShotGuides: true, calledPocket: .sideTop,
                                         target: target)
        #expect(layout.calledPocket != nil)
    }
}

@Suite("Parked device: aim from the cue only")
struct ParkedAimTests {
    /// Camera 1.5 m behind the cue ball looking down the table: the
    /// device-pose model would aim along +x.
    private let tripodCamera = Transform3D(columns: [
        SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(-1.5, 0.6, 0, 1)
    ])
    private let stick: [Vec2] = [Vec2(-1.1, 0.07), Vec2(-0.0, 0.07), Vec2(0.0, 0.03), Vec2(-1.1, 0.03)]

    private func planner(parked: Bool) -> ShotPlanner {
        ShotPlanner(solver: solver, guideSpeed: 3.5, config: .forDevice(parked: parked))
    }

    @Test("The config built for a parked device refuses device-pose aiming")
    func configFollowsParkedMode() {
        #expect(ShotPlanner.Config.forDevice(parked: true).resolver.allowDevicePose == false)
        #expect(ShotPlanner.Config.forDevice(parked: false).resolver.allowDevicePose == true)
        // The default is hand-held. That is why launch has to build the
        // planner from the persisted setting rather than keep the default:
        // a parked device that kept it aimed from the tripod for hours.
        #expect(ShotPlanner.Config.default.resolver.allowDevicePose == true)
    }

    @Test("Parked, no stick: no plan, no live strips, no live ghost ball")
    func parkedWithoutStickHasNoLiveAim() throws {
        let state = fifteenBallState()
        var parked = planner(parked: true)
        var handheld = planner(parked: false)
        // The control: the same inputs on a hand-held device DO produce the
        // phantom aim, so the assertions below are not vacuous.
        let control = handheld.update(state: state, stickQuad: nil, cameraTransform: tripodCamera,
                                      calibration: calibration, at: 0)
        #expect(control.plan?.source == .devicePose)

        for time in stride(from: 0.0, through: 3600, by: 600) {
            let result = parked.update(state: state, stickQuad: nil, cameraTransform: tripodCamera,
                                       calibration: calibration, at: time)
            #expect(result.plan == nil, "t=\(time)")
            #expect(parked.aimSource == .devicePose, "no stick source either")

            let layout = OverlayLayout.frame(state: state, calibration: calibration,
                                             prediction: result.plan?.prediction,
                                             showsShotGuides: true)
            #expect(layout.strips.isEmpty)
            #expect(layout.ghostBall == nil)
            #expect(layout.highlightedPockets.isEmpty)
        }
    }

    @Test("Parked with a held cue: the cue still aims, and the hold lapses to nothing, not to the tripod")
    func parkedWithStickStillAims() throws {
        let state = fifteenBallState()
        var parked = planner(parked: true)
        let held = parked.update(state: state, stickQuad: stick, cameraTransform: tripodCamera,
                                 calibration: calibration, at: 0)
        #expect(held.plan?.source == .stick)
        let bridged = parked.update(state: state, stickQuad: nil, cameraTransform: tripodCamera,
                                    calibration: calibration, at: 1)
        #expect(bridged.plan?.source == .stick)
        let lapsed = parked.update(state: state, stickQuad: nil, cameraTransform: tripodCamera,
                                   calibration: calibration, at: 10)
        #expect(lapsed.plan == nil)
    }
}

@Suite("Overlay style: rings and colours")
struct OverlayRingStyleTests {
    @Test("Every ball ring is inside the 25 to 40 percent band")
    func ringOpacityBand() {
        #expect(OverlayStyle.ringOpacityRange.contains(OverlayStyle.ballRingOpacity))
        #expect(OverlayStyle.ringOpacityRange.contains(OverlayStyle.involvedRingOpacity))
        #expect(OverlayStyle.ringOpacityRange == 0.25...0.4)
        #expect(OverlayStyle.involvedRingOpacity >= OverlayStyle.ballRingOpacity)
    }

    @Test("A ball ring starts outside the ball and is thin: it covers nothing")
    func ringDoesNotCoverTheBall() {
        for radius in [Ball.standardRadius, 0.025, 0.03] {
            let ring = OverlayStyle.ballRing(ballRadius: radius)
            #expect(ring.inner > radius, "clear of the ball's footprint")
            #expect(ring.outer - ring.inner <= 0.004, "thin")
            #expect(ring.outer < radius * 1.3, "close to the ball, not a plate")
        }
    }

    @Test("The hero is never dimmer than a ring, and the pocket ring is the strongest ring")
    func hierarchy() {
        #expect(OverlayStyle.opacity(.hero) > OverlayStyle.involvedRingOpacity)
        #expect(OverlayStyle.pocketRingOpacity > OverlayStyle.involvedRingOpacity)
    }

    @Test("One colour per meaning, all from the theme")
    func oneColourPerMeaning() {
        #expect(OverlayStyle.heroCueColor == Theme.hudText.rgb)
        #expect(OverlayStyle.heroObjectColor == Theme.feltGreen.rgb)
        let roles: [UInt32] = [
            OverlayStyle.heroCueColor, OverlayStyle.heroObjectColor,
            Theme.cueAmber.rgb, Theme.chalkBlue.rgb, Theme.warnCoral.rgb
        ]
        #expect(Set(roles).count == roles.count, "no two roles share a colour")
        #expect(OverlayStyle.shotColor == OverlayStyle.heroCueColor)
        #expect(OverlayStyle.pocketRingColor == OverlayStyle.heroObjectColor)
        #expect(OverlayStyle.cueRingColor == OverlayStyle.heroCueColor)
        #expect(OverlayStyle.targetRingColor == OverlayStyle.heroObjectColor)
    }

    @Test("The compose defaults are the theme's amber, green, blue and coral")
    func composeDefaultsAreTheTheme() {
        let cue = BallID(0), object = BallID(1)
        let state = TableState(table: Table(size: .nineFoot), balls: [
            Ball(id: cue, kind: .cue, position: Vec2(-0.5, 0)),
            Ball(id: object, kind: .solid(1), position: .zero)
        ])
        let contact = Vec2(-2 * Ball.standardRadius, 0)
        let prediction = ShotPrediction(
            segments: [
                TrajectorySegment(ballID: cue, start: Vec2(-0.5, 0), end: contact),
                TrajectorySegment(ballID: cue, start: contact, end: Vec2(-0.1, -0.3)),
                TrajectorySegment(ballID: object, start: .zero, end: Vec2(0.6, 0))
            ],
            events: [.ballBall(moving: cue, struck: object, contact: contact)],
            pocketedBalls: [])
        let layout = OverlayLayout.compose(state: state, prediction: prediction,
                                           calibration: calibration)
        #expect(layout.strips.map(\.color) == [Theme.cueAmber.rgb, Theme.chalkBlue.rgb, Theme.feltGreen.rgb])
    }
}

@Suite("Ring mesh")
struct RingMeshTests {
    @Test("Radii are honoured and the middle is empty")
    func hasAHole() {
        let ring = RingMesh(innerRadius: 0.032, outerRadius: 0.035)
        #expect(abs(ring.innerRadius - 0.032) < 1e-6)
        #expect(abs(ring.outerRadius - 0.035) < 1e-6)
        #expect(ring.points.allSatisfy { $0.y == 0 })
        // Nothing sits at the centre: no vertex closer than the inner radius.
        #expect(ring.points.allSatisfy { ($0.x * $0.x + $0.z * $0.z).squareRoot() > 0.031 })
    }

    @Test("The ring's area is the annulus, not the disc")
    func areaIsTheAnnulus() {
        let (inner, outer) = (0.032, 0.035)
        let ring = RingMesh(innerRadius: inner, outerRadius: outer, segments: 96)
        let annulus = Double.pi * (outer * outer - inner * inner)
        let disc = Double.pi * outer * outer
        #expect(abs(ring.upwardArea - annulus) / annulus < 0.01)
        #expect(ring.upwardArea < disc / 5)
    }

    @Test("Every triangle exists facing up and facing down, and indices are in range")
    func bothSides() {
        let ring = RingMesh(innerRadius: 0.03, outerRadius: 0.04, segments: 32)
        #expect(ring.indices.count % 6 == 0)
        #expect(ring.indices.allSatisfy { Int($0) < ring.points.count })
        #expect(ring.points.count == 64)
    }

    @Test("Degenerate input still yields a valid mesh")
    func degenerate() {
        let swapped = RingMesh(innerRadius: 0.05, outerRadius: 0.03, segments: 2)
        #expect(swapped.innerRadius < swapped.outerRadius)
        #expect(swapped.points.count >= 16)
    }
}

@Suite("HeroTransition: the cross-fade and the pulse")
struct HeroTransitionTests {
    private let a = OverlayLayout.ShotID(ball: BallID(3), pocket: .cornerTopLeft)
    private let b = OverlayLayout.ShotID(ball: BallID(4), pocket: .sideTop)

    @Test("The fade is 200 to 300 ms")
    func duration() {
        #expect((0.2...0.3).contains(HeroTransition.fadeDuration))
    }

    @Test("Fade-in is 0 at the change, 1 after the duration, and monotonic between")
    func fadeInCurve() {
        let duration = HeroTransition.fadeDuration
        #expect(HeroTransition.fadeIn(elapsed: 0, reduceMotion: false) == 0)
        #expect(HeroTransition.fadeIn(elapsed: duration, reduceMotion: false) == 1)
        #expect(HeroTransition.fadeIn(elapsed: duration * 4, reduceMotion: false) == 1)
        #expect(HeroTransition.fadeIn(elapsed: -1, reduceMotion: false) == 0, "a clock that steps back")
        var previous = -1.0
        for step in 0...100 {
            let value = HeroTransition.fadeIn(elapsed: duration * Double(step) / 100, reduceMotion: false)
            #expect((0...1).contains(value))
            #expect(value >= previous, "step \(step)")
            previous = value
        }
        let half = HeroTransition.fadeIn(elapsed: duration / 2, reduceMotion: false)
        #expect(half > 0.3 && half < 0.7)
    }

    @Test("Reduce Motion: 1 immediately, no pulse")
    func reduceMotion() {
        #expect(HeroTransition.fadeIn(elapsed: 0, reduceMotion: true) == 1)
        #expect(HeroTransition.fadeOut(elapsed: 0, reduceMotion: true) == 0)
        for elapsed in [0.0, 0.1, 0.2] {
            #expect(HeroTransition.pulseScale(elapsed: elapsed, reduceMotion: true) == 1)
        }
        var transition = HeroTransition()
        transition.note(shot: a, at: 10, reduceMotion: true)
        #expect(transition.incomingOpacity(at: 10) == 1)
        transition.note(shot: b, at: 20, reduceMotion: true)
        #expect(transition.incomingOpacity(at: 20) == 1)
        #expect(transition.outgoingOpacity(at: 20) == 0)
        #expect(transition.ringScale(at: 20.1) == 1)
        #expect(transition.isSettled(at: 20))
    }

    @Test("The outgoing line is the complement: the two always sum to one")
    func crossFade() {
        var transition = HeroTransition()
        transition.note(shot: a, at: 0, reduceMotion: false)
        transition.note(shot: b, at: 5, reduceMotion: false)
        #expect(transition.previousShot == a && transition.shot == b)
        for offset in stride(from: 0.0, through: 0.4, by: 0.02) {
            let now = 5 + offset
            #expect(abs(transition.incomingOpacity(at: now) + transition.outgoingOpacity(at: now) - 1) < 1e-12)
        }
        #expect(transition.incomingOpacity(at: 5) == 0)
        #expect(transition.outgoingOpacity(at: 5) == 1)
        #expect(transition.incomingOpacity(at: 5.3) == 1)
        #expect(transition.outgoingOpacity(at: 5.3) == 0)
    }

    @Test("Only a different shot is a change; a nudged ball is the same shot")
    func changeDetection() {
        var transition = HeroTransition()
        let nothingToNothing = transition.note(shot: nil, at: 0, reduceMotion: false)
        let first = transition.note(shot: a, at: 1, reduceMotion: false)
        let same = transition.note(shot: a, at: 2, reduceMotion: false)
        #expect(!nothingToNothing)
        #expect(first)
        #expect(!same)
        #expect(transition.changedAt == 1, "the clock restarts only on a change")
        let different = transition.note(shot: b, at: 3, reduceMotion: false)
        let gone = transition.note(shot: nil, at: 4, reduceMotion: false)
        #expect(different)
        #expect(gone, "the suggestion going away fades out")
        #expect(transition.outgoingOpacity(at: 4) == 1)
        #expect(transition.outgoingOpacity(at: 4.3) == 0)
    }

    @Test("A first suggestion fades in from nothing, with nothing fading out")
    func firstShot() {
        var transition = HeroTransition()
        transition.note(shot: a, at: 7, reduceMotion: false)
        #expect(transition.incomingOpacity(at: 7) == 0)
        #expect(transition.outgoingOpacity(at: 7) == 0)
        #expect(!transition.isSettled(at: 7.1))
        #expect(transition.isSettled(at: 7 + HeroTransition.pulseDuration))
    }

    @Test("The pocket ring pulses once: rest, up, rest")
    func pulse() {
        let duration = HeroTransition.pulseDuration
        #expect(HeroTransition.pulseScale(elapsed: 0, reduceMotion: false) == 1)
        #expect(HeroTransition.pulseScale(elapsed: duration, reduceMotion: false) == 1)
        #expect(HeroTransition.pulseScale(elapsed: duration * 3, reduceMotion: false) == 1)
        let peak = HeroTransition.pulseScale(elapsed: duration / 2, reduceMotion: false)
        #expect(abs(peak - HeroTransition.pulsePeak) < 1e-9)
        var sawRise = false, sawFall = false
        var previous = 1.0
        for step in 1..<100 {
            let value = HeroTransition.pulseScale(elapsed: duration * Double(step) / 100, reduceMotion: false)
            #expect(value >= 1 && value <= HeroTransition.pulsePeak + 1e-9)
            if value > previous { sawRise = true }
            if value < previous { sawFall = true }
            // Once it has started falling it never rises again: once.
            if sawFall { #expect(value <= previous + 1e-12) }
            previous = value
        }
        #expect(sawRise && sawFall)
    }

    @Test("No shot, no pulse")
    func noShotNoPulse() {
        var transition = HeroTransition()
        transition.note(shot: a, at: 0, reduceMotion: false)
        transition.note(shot: nil, at: 1, reduceMotion: false)
        #expect(transition.ringScale(at: 1.2) == 1)
    }
}
