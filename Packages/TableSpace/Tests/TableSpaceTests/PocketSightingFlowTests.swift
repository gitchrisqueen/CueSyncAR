//
//  PocketSightingFlowTests.swift
//  CueSync AR
//

import CueSyncCore
import Testing
@testable import TableSpace

@Suite("Pocket sighting flow")
struct PocketSightingFlowTests {

    @Test("Nothing sighted asks for pockets")
    func emptyFlow() {
        let flow = PocketSightingFlow()
        #expect(flow.readiness == .needMorePockets(have: 0))
        #expect(!flow.canSolve)
        #expect(flow.prompt.contains("Tap the pockets"))
    }

    @Test("Two pockets plus a middle point is enough")
    func twoPocketsAndTowards() {
        var flow = PocketSightingFlow()
        flow.sight(.cornerTopLeft, at: Vec2(100, 100))
        flow.sight(.cornerBottomRight, at: Vec2(900, 500))
        // Two points are always collinear, so a side is always needed.
        #expect(flow.readiness == .needTowardsPoint)
        flow.setTowards(Vec2(500, 300))
        #expect(flow.readiness == .ready)
        #expect(flow.canSolve)
    }

    @Test("One pocket needs a rail heading first, then a side")
    func onePocketPath() {
        var flow = PocketSightingFlow()
        flow.sight(.sideTop, at: Vec2(500, 200))
        #expect(flow.readiness == .needRailHeading)
        flow.setRailHeading(.init(from: Vec2(100, 190), to: Vec2(900, 210)))
        #expect(flow.readiness == .needTowardsPoint)
        flow.setTowards(Vec2(500, 400))
        #expect(flow.readiness == .ready)
    }

    @Test("Three pockets off a line stand on their own")
    func threeNonCollinearPocketsNeedNothingElse() {
        var flow = PocketSightingFlow()
        flow.sight(.cornerTopLeft, at: Vec2(100, 100))
        flow.sight(.cornerTopRight, at: Vec2(900, 120))
        flow.sight(.cornerBottomLeft, at: Vec2(120, 600))
        #expect(!flow.sightingsAreCollinear)
        #expect(flow.readiness == .ready)
    }

    @Test("Three pockets ALONG one rail still need a side")
    func collinearPocketsAreAmbiguous() {
        var flow = PocketSightingFlow()
        // The camera parked at the side of the table sees exactly this:
        // one long rail's three pockets and nothing else.
        flow.sight(.cornerTopLeft, at: Vec2(100, 200))
        flow.sight(.sideTop, at: Vec2(500, 200))
        flow.sight(.cornerTopRight, at: Vec2(900, 200))
        #expect(flow.sightingsAreCollinear)
        #expect(flow.readiness == .needTowardsPoint)
        flow.setTowards(Vec2(500, 500))
        #expect(flow.readiness == .ready)
    }

    @Test("Sighting the same pocket twice corrects it rather than adding it")
    func resightReplaces() {
        var flow = PocketSightingFlow()
        flow.sight(.sideTop, at: Vec2(500, 200))
        flow.sight(.sideTop, at: Vec2(520, 205))
        // Keeping both would hand the solver two contradictory positions
        // for one hole, which is exactly what a mis-tap correction is.
        #expect(flow.sightings.count == 1)
        #expect(flow.sightings[0].screen == Vec2(520, 205))
    }

    @Test("Undo drops one sighting, not the session")
    func undoIsNotReset() {
        var flow = PocketSightingFlow()
        flow.sight(.cornerTopLeft, at: Vec2(100, 100))
        flow.sight(.cornerTopRight, at: Vec2(900, 120))
        flow.sight(.cornerBottomLeft, at: Vec2(120, 600))
        flow.undoLastSighting()
        #expect(flow.sightings.count == 2)
        #expect(flow.sightings.map(\.pocket) == [.cornerTopLeft, .cornerTopRight])
        flow.undoLastSighting()
        flow.undoLastSighting()
        flow.undoLastSighting()   // past empty must not trap
        #expect(flow.sightings.isEmpty)
    }

    @Test("Reset clears everything, including the side and the rail")
    func resetClearsAll() {
        var flow = PocketSightingFlow()
        flow.sight(.sideTop, at: Vec2(500, 200))
        flow.setRailHeading(.init(from: Vec2(100, 190), to: Vec2(900, 210)))
        flow.setTowards(Vec2(500, 400))
        flow.reset()
        #expect(flow.sightings.isEmpty)
        #expect(flow.towards == nil)
        #expect(flow.railHeading == nil)
        #expect(flow.readiness == .needMorePockets(have: 0))
    }

    @Test("Every prompt is a sentence about the table, not the mechanism")
    func promptsAreForPlayers() {
        var flow = PocketSightingFlow()
        var prompts = [flow.prompt]
        flow.sight(.sideTop, at: Vec2(500, 200))
        prompts.append(flow.prompt)
        flow.setRailHeading(.init(from: Vec2(100, 190), to: Vec2(900, 210)))
        prompts.append(flow.prompt)
        flow.setTowards(Vec2(500, 400))
        prompts.append(flow.prompt)
        for prompt in prompts {
            #expect(!prompt.isEmpty)
            for word in ["raycast", "solve", "residual", "normal", "Vec2", "nil"] {
                #expect(!prompt.lowercased().contains(word.lowercased()),
                        "\(prompt) leaks \(word)")
            }
        }
    }

    @Test("The rail heading knows its own direction")
    func railDirection() {
        let heading = PocketSightingFlow.RailHeading(from: Vec2(100, 200), to: Vec2(900, 200))
        #expect(heading.direction == Vec2(800, 0))
    }
}
