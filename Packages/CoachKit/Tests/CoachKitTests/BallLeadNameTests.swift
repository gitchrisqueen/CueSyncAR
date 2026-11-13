import CueSyncCore
import Testing
@testable import CoachKit

@Suite("Ball names that lead the card")
struct BallLeadNameTests {

    @Test("A known number comes first, then the colour")
    func numberFirst() {
        #expect(BallNaming.leadName(kind: .solid(7), colour: "maroon") == "7 Maroon")
        #expect(BallNaming.leadName(kind: .stripe(15), colour: "maroon") == "15 Maroon stripe")
        #expect(BallNaming.leadName(kind: .stripe(9), colour: nil) == "9 Yellow stripe")
        #expect(BallNaming.leadName(kind: .solid(3), colour: nil) == "3 Red")
        #expect(BallNaming.leadName(kind: .eight, colour: nil) == "8-ball")
        #expect(BallNaming.leadName(kind: .cue, colour: nil) == "Cue ball")
    }

    @Test("No number: the colour alone; no colour either: no invented colour")
    func colourOnlyThenNothing() {
        #expect(BallNaming.leadName(kind: .unknown, colour: "orange") == "Orange ball")
        #expect(BallNaming.leadName(kind: .unknown, colour: nil) == "Ball")
        #expect(BallNaming.leadName(kind: .unknown, colour: "black") == "Ball")
        #expect(BallNaming.leadName(kind: .unknown, colour: "white") == "Cue ball")
    }

    @Test("A number the seen colour contradicts is not claimed")
    func contradictionDropsTheNumber() {
        // The tracker says solid 7 (maroon) but the pixels say orange: say
        // what was seen, never a number that is probably wrong.
        #expect(BallNaming.leadName(kind: .solid(7), colour: "orange") == "Orange ball")
        #expect(BallNaming.leadName(kind: .stripe(15), colour: "orange") == "Orange stripe")
    }

    @Test("A number outside the set is never printed")
    func outOfRange() {
        #expect(BallNaming.leadName(kind: .solid(0), colour: nil) == "Ball")
        #expect(BallNaming.leadName(kind: .stripe(8), colour: nil) == "Ball")
        #expect(BallNaming.leadName(kind: .solid(9), colour: "blue") == "Blue ball")
    }

    @Test("The existing spoken name is unchanged")
    func spokenNameUnchanged() {
        #expect(BallNaming.name(kind: .solid(7), colour: "maroon") == "Maroon ball")
        #expect(BallNaming.name(kind: .stripe(9), colour: nil) == "Yellow stripe")
    }

    // MARK: The call names the rated ball, whatever else is on the table

    private func table(_ balls: [Ball]) -> TableState {
        TableState(table: Table(size: .nineFoot), balls: balls, timestamp: 0)
    }

    @Test("Two maroon balls each keep their own name, in any table order")
    func twoMaroonBalls() {
        let seven = Ball(id: BallID(7), kind: .solid(7), position: Vec2(0, 0))
        let fifteen = Ball(id: BallID(15), kind: .stripe(15), position: Vec2(0.2, 0))
        for balls in [[seven, fifteen], [fifteen, seven]] {
            let state = table(balls)
            #expect(ShotCall.make(ball: BallID(7), in: state, colour: "maroon", pocket: "left side pocket").leadBall
                    == "7 Maroon")
            #expect(ShotCall.make(ball: BallID(15), in: state, colour: "maroon", pocket: nil).leadBall
                    == "15 Maroon stripe")
        }
    }

    @Test("The call reads only the rated ball's own colour, not a neighbour's")
    func ownColourOnly() {
        let orange = Ball(id: BallID(5), kind: .unknown, position: Vec2(0, 0))
        let maroon = Ball(id: BallID(7), kind: .unknown, position: Vec2(0.2, 0))
        let state = table([orange, maroon])
        // The caller passes the colour of the rated id; nothing about the
        // other ball can reach the name.
        #expect(ShotCall.make(ball: BallID(7), in: state, colour: "maroon", pocket: nil).leadBall == "Maroon ball")
        #expect(ShotCall.make(ball: BallID(5), in: state, colour: "orange", pocket: nil).leadBall == "Orange ball")
    }

    @Test("A rated ball that is no longer on the table is just 'Ball'")
    func missingBall() {
        let call = ShotCall.make(ball: BallID(4), in: table([]), colour: "red", pocket: nil)
        #expect(call.leadBall == "Ball")
        #expect(call.ball == "Ball")
    }

    @Test("The card line and the spoken line still use the plain name")
    func lineUnchanged() {
        let call = ShotCall(ball: "Blue ball", pocket: "right side pocket", leadBall: "2 Blue")
        #expect(call.line == "Blue ball → right side pocket")
        #expect(call.spoken == "Blue ball into the right side pocket")
        #expect(call.leadBall == "2 Blue")
        #expect(ShotCall(ball: "Blue ball", pocket: nil).leadBall == "Blue ball")
    }
}
