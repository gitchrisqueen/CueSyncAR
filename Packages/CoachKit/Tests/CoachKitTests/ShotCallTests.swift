import CueSyncCore
import Foundation
import Testing
@testable import CoachKit

@Suite("Pocket names from the viewer's side")
struct PocketViewNamingTests {
    private let table = Table(size: .eightFoot)

    private func names(cameraAt camera: Vec2) throws -> [PocketID: String] {
        let frame = try #require(PocketViewFrame(cameraAt: camera))
        return PocketViewNaming.names(for: table, frame: frame)
    }

    @Test("Camera at the head end: the long rails are left and right")
    func cameraAtTheLeftEnd() throws {
        // Looking along +x, table +y is on the viewer's left.
        let n = try names(cameraAt: Vec2(-3, 0))
        #expect(n[.cornerTopLeft] == "near-left corner")
        #expect(n[.cornerTopRight] == "far-left corner")
        #expect(n[.cornerBottomLeft] == "near-right corner")
        #expect(n[.cornerBottomRight] == "far-right corner")
        #expect(n[.sideTop] == "left side pocket")
        #expect(n[.sideBottom] == "right side pocket")
    }

    @Test("Camera at the foot end: everything is turned half a circle")
    func cameraAtTheRightEnd() throws {
        let n = try names(cameraAt: Vec2(3, 0))
        #expect(n[.cornerTopLeft] == "far-right corner")
        #expect(n[.cornerTopRight] == "near-right corner")
        #expect(n[.cornerBottomLeft] == "far-left corner")
        #expect(n[.cornerBottomRight] == "near-left corner")
        #expect(n[.sideTop] == "right side pocket")
        #expect(n[.sideBottom] == "left side pocket")
    }

    @Test("Camera at the bottom long rail: the side pockets are near and far")
    func cameraAtTheBottomRail() throws {
        let n = try names(cameraAt: Vec2(0, -2))
        #expect(n[.cornerTopLeft] == "far-left corner")
        #expect(n[.cornerTopRight] == "far-right corner")
        #expect(n[.cornerBottomLeft] == "near-left corner")
        #expect(n[.cornerBottomRight] == "near-right corner")
        #expect(n[.sideTop] == "far side pocket")
        #expect(n[.sideBottom] == "near side pocket")
    }

    @Test("Camera at the top long rail")
    func cameraAtTheTopRail() throws {
        let n = try names(cameraAt: Vec2(0, 2))
        #expect(n[.cornerTopLeft] == "near-right corner")
        #expect(n[.cornerTopRight] == "near-left corner")
        #expect(n[.cornerBottomLeft] == "far-right corner")
        #expect(n[.cornerBottomRight] == "far-left corner")
        #expect(n[.sideTop] == "near side pocket")
        #expect(n[.sideBottom] == "far side pocket")
    }

    @Test("Every pocket gets a distinct name from any camera")
    func namesAreDistinct() throws {
        for camera in [Vec2(-3, 0), Vec2(3, 0), Vec2(0, -2), Vec2(0, 2),
                       Vec2(-2, -2), Vec2(2, 1.5), Vec2(-1.5, 2.2)] {
            let n = try names(cameraAt: camera)
            #expect(n.count == 6)
            #expect(Set(n.values).count == 6, "\(camera): \(n)")
        }
    }

    @Test("From a table corner the table is a diamond: far, right, near and left corners")
    func cameraAtACorner() throws {
        let n = try names(cameraAt: Vec2(-2, -2))
        #expect(n[.cornerTopRight] == "far corner")
        #expect(n[.cornerBottomRight] == "right corner")
        #expect(n[.cornerTopLeft] == "left corner")
        #expect(n[.cornerBottomLeft] == "near corner")
    }

    @Test("The table-axis name is gone: nothing says top or bottom")
    func neverTableAxisWords() throws {
        for camera in [Vec2(-3, 0), Vec2(0, -2)] {
            for name in try names(cameraAt: camera).values {
                #expect(!name.contains("top") && !name.contains("bottom"), "\(name)")
            }
        }
    }

    @Test("A camera on the target has no direction")
    func cameraOnTheTable() {
        #expect(PocketViewFrame(cameraAt: Vec2(0.01, 0.01)) == nil)
    }

    @Test("Screen axes: an unrotated top-down view is the identity frame")
    func screenAxesIdentity() throws {
        // Table +x lands to the right, table +y lands UP the screen (y down).
        let frame = try #require(PocketViewFrame(screenOrigin: Vec2(500, 400),
                                                 xTip: Vec2(600, 400),
                                                 yTip: Vec2(500, 300)))
        #expect(frame.right.distance(to: Vec2(1, 0)) < 1e-12)
        #expect(frame.forward.distance(to: Vec2(0, 1)) < 1e-12)
        #expect(PocketViewNaming.names(for: table, frame: frame)[.sideBottom] == "near side pocket")
    }

    @Test("Screen axes: a table seen from its head end names pockets like the camera frame")
    func screenAxesMatchTheCameraFrame() throws {
        // Viewer at -x looking along +x: table +x goes UP the screen,
        // table +y goes to the LEFT.
        let fromScreen = try #require(PocketViewFrame(screenOrigin: Vec2(500, 400),
                                                      xTip: Vec2(500, 300),
                                                      yTip: Vec2(400, 400)))
        let fromCamera = try #require(PocketViewFrame(cameraAt: Vec2(-3, 0)))
        #expect(PocketViewNaming.names(for: table, frame: fromScreen)
                == PocketViewNaming.names(for: table, frame: fromCamera))
    }

    @Test("Screen axes: perspective foreshortening does not change the answer")
    func screenAxesSurvivePerspective() throws {
        // Depth squashed to a fifth, as a low camera sees it, plus a skew.
        let frame = try #require(PocketViewFrame(screenOrigin: Vec2(500, 400),
                                                 xTip: Vec2(580, 399),
                                                 yTip: Vec2(505, 380)))
        let n = PocketViewNaming.names(for: table, frame: frame)
        #expect(n[.cornerTopLeft] == "far-left corner")
        #expect(n[.cornerBottomRight] == "near-right corner")
    }

    @Test("Screen axes: an edge-on table has no frame")
    func edgeOnTable() {
        #expect(PocketViewFrame(screenOrigin: Vec2(0, 0), xTip: Vec2(10, 0),
                                yTip: Vec2(20, 0)) == nil)
    }
}

@Suite("Ball names")
struct BallNamingTests {
    @Test("The tracker's colour is what is named")
    func colourWins() {
        #expect(BallNaming.name(kind: .solid(2), colour: "blue") == "Blue ball")
        #expect(BallNaming.name(kind: .stripe(11), colour: "red") == "Red stripe")
        #expect(BallNaming.name(kind: .unknown, colour: "green") == "Green ball")
    }

    @Test("Without a measured colour the number implies one")
    func numberImpliesColour() {
        #expect(BallNaming.name(kind: .solid(3)) == "Red ball")
        #expect(BallNaming.name(kind: .solid(7)) == "Maroon ball")
        #expect(BallNaming.name(kind: .stripe(9)) == "Yellow stripe")
        #expect(BallNaming.name(kind: .stripe(15)) == "Maroon stripe")
    }

    @Test("The eight and the cue ball are named as such, whatever colour was seen")
    func specialBalls() {
        #expect(BallNaming.name(kind: .eight, colour: "blue") == "8-ball")
        #expect(BallNaming.name(kind: .cue) == "Cue ball")
        #expect(BallNaming.name(kind: .unknown, colour: "white") == "Cue ball")
    }

    @Test("Unknown with nothing measured is just a ball")
    func unknownIsBall() {
        #expect(BallNaming.name(kind: .unknown) == "Ball")
        #expect(BallNaming.name(kind: .unknown, colour: "black") == "Ball")
    }
}

@Suite("Shot call and difficulty words")
struct ShotCallTests {
    private func rating(_ difficulty: ShotRating.Difficulty, ball: Int = 3,
                        pocket: PocketID = .sideTop) -> ShotRating {
        ShotRating(ball: BallID(ball), pocket: pocket, probability: 0.5,
                   difficulty: difficulty, cutAngleDegrees: 10, cueTravel: 1,
                   objectTravel: 1, aimTolerance: 0.01, ghostBall: Vec2(0, 0))
    }

    @Test("The card line and the spoken line say the same thing")
    func lines() {
        let call = ShotCall(ball: "Blue ball", pocket: "right side pocket")
        #expect(call.line == "Blue ball → right side pocket")
        #expect(call.spoken == "Blue ball into the right side pocket")
        let noPocket = ShotCall(ball: "Blue ball", pocket: nil)
        #expect(noPocket.line == "Blue ball")
        #expect(noPocket.spoken == "Blue ball")
    }

    @Test("Five bands collapse to three words, plus blocked")
    func tierWords() {
        #expect(ShotRating.Difficulty.easy.tierWord == "Easy")
        #expect(ShotRating.Difficulty.medium.tierWord == "Fair")
        #expect(ShotRating.Difficulty.hard.tierWord == "Hard")
        #expect(ShotRating.Difficulty.longShot.tierWord == "Hard")
        #expect(ShotRating.Difficulty.blocked.tierWord == "Blocked")
        #expect(ShotRating.Difficulty.medium.spokenTier == "fair")
    }

    @Test("A band flicker on the same shot is held until it persists")
    func holdsAFlicker() {
        var hold = DifficultyHold(dwell: 1.5)
        #expect(hold.resolve(rating(.easy), at: 0) == .easy)
        // Probability dips across the boundary for a moment: still Easy.
        #expect(hold.resolve(rating(.medium), at: 0.4) == .easy)
        #expect(hold.resolve(rating(.easy), at: 0.8) == .easy)
        // The dip returned to Easy, so the clock restarted.
        #expect(hold.resolve(rating(.medium), at: 1.0) == .easy)
        #expect(hold.resolve(rating(.medium), at: 2.4) == .easy)
        // Persisted for the full dwell: now it changes.
        #expect(hold.resolve(rating(.medium), at: 2.6) == .medium)
    }

    @Test("A different shot or a block is shown at once")
    func factsAreNotHeld() {
        var hold = DifficultyHold(dwell: 1.5)
        #expect(hold.resolve(rating(.easy, ball: 3), at: 0) == .easy)
        #expect(hold.resolve(rating(.hard, ball: 5), at: 0.1) == .hard)
        #expect(hold.resolve(rating(.blocked, ball: 5), at: 0.2) == .blocked)
        #expect(hold.resolve(rating(.easy, ball: 5), at: 0.3) == .easy)
    }

    @Test("Reset forgets the held word")
    func resets() {
        var hold = DifficultyHold(dwell: 1.5)
        _ = hold.resolve(rating(.easy), at: 0)
        hold.reset()
        #expect(hold.resolve(rating(.hard), at: 0.1) == .hard)
    }
}
