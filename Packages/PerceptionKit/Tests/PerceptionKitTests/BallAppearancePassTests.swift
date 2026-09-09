//
//  BallAppearancePassTests.swift
//  PerceptionKitTests
//
//  The pass has three ways to be wrong that the sampler and classifier
//  cannot catch: giving a track its neighbour's colour, naming colours
//  with no white reference, and speaking at all when there is nothing to
//  read. One test each.
//

import CueSyncCore
import Foundation
import Testing

@testable import PerceptionKit

private struct FlatImage: PixelSampling {
    let pixelWidth = 400
    let pixelHeight = 300
    /// Each ball is drawn as a disc at the centre of its own box.
    var discs: [(centre: Vec2, radius: Double, colour: Vec3)] = []

    func rgb(x: Int, y: Int) -> Vec3? {
        guard x >= 0, y >= 0, x < pixelWidth, y < pixelHeight else { return nil }
        for disc in discs {
            let dx = Double(x) + 0.5 - disc.centre.x
            let dy = Double(y) + 0.5 - disc.centre.y
            if dx * dx + dy * dy <= disc.radius * disc.radius { return disc.colour }
        }
        return Vec3(0.02, 0.02, 0.02)
    }
}

@Suite("Ball appearance pass")
struct BallAppearancePassTests {

    /// Two balls: a cue ball and a blue solid, each with a box drawn
    /// round its own disc.
    private func scene() -> (image: FlatImage, detections: [LocatedDetection]) {
        var image = FlatImage()
        image.discs = [
            (Vec2(100, 150), 18, Vec3(0.70, 0.69, 0.65)),   // cue
            (Vec2(300, 150), 18, Vec3(0.13, 0.27, 0.40))    // blue
        ]
        func box(_ centre: Vec2) -> NormalizedRect {
            NormalizedRect(x: (centre.x - 18) / 400, y: (centre.y - 18) / 300,
                           width: 36 / 400, height: 36 / 300)
        }
        return (image, [
            LocatedDetection(position: Vec2(0.2, 0.4), box: box(Vec2(100, 150)), kind: .cue),
            LocatedDetection(position: Vec2(0.9, 0.4), box: box(Vec2(300, 150)), kind: .unknown)
        ])
    }

    @Test("Each track gets the colour of its own ball")
    func tracksGetTheirOwnColour() throws {
        let (image, detections) = scene()
        let balls = [
            Ball(id: BallID(rawValue: 1), kind: .cue, position: Vec2(0.2, 0.4)),
            Ball(id: BallID(rawValue: 2), kind: .unknown, position: Vec2(0.9, 0.4))
        ]
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result[BallID(rawValue: 1)]?.family == .white)
        #expect(result[BallID(rawValue: 2)]?.family == .blue)
    }

    @Test("A track with no observation within a ball's width is left unread")
    func distantTrackIsNotGivenANeighboursColour() throws {
        let (image, detections) = scene()
        let balls = [
            Ball(id: BallID(rawValue: 1), kind: .cue, position: Vec2(0.2, 0.4)),
            // Half a metre from anything the detector saw. Silence is the
            // right answer; the blue ball's colour is not.
            Ball(id: BallID(rawValue: 9), kind: .unknown, position: Vec2(1.6, 0.4))
        ]
        let result = BallAppearancePass.run(balls: balls, detections: detections, image: image)
        #expect(result[BallID(rawValue: 9)] == nil)
        #expect(result[BallID(rawValue: 1)] != nil)
    }

    @Test("With no cue ball in frame nothing is named at all")
    func withoutAWhiteReferenceNothingIsNamed() throws {
        let (image, detections) = scene()
        // Only the blue ball is tracked, and its detection is not a cue.
        let balls = [Ball(id: BallID(rawValue: 2), kind: .unknown, position: Vec2(0.9, 0.4))]
        let result = BallAppearancePass.run(balls: balls,
                                            detections: [detections[1]], image: image)
        #expect(result.isEmpty)
    }

    @Test("An empty frame produces nothing rather than an empty-patch guess")
    func emptyInputsProduceNothing() {
        let (image, detections) = scene()
        #expect(BallAppearancePass.run(balls: [], detections: detections, image: image).isEmpty)
        #expect(BallAppearancePass.run(
            balls: [Ball(id: BallID(rawValue: 1), kind: .cue, position: .zero)],
            detections: [], image: image).isEmpty)
    }

    @Test("A designated cue ball serves as the reference even when the detector missed it")
    func playerDesignationCanSupplyTheReference() throws {
        let (image, detections) = scene()
        // The detector called the cue ball a colour-ball — the measle-ball
        // case CLAUDE.md documents — but the player tapped to designate it.
        var mislabelled = detections
        mislabelled[0] = LocatedDetection(position: detections[0].position,
                                          box: detections[0].box, kind: .unknown)
        let balls = [
            Ball(id: BallID(rawValue: 1), kind: .cue, position: Vec2(0.2, 0.4)),
            Ball(id: BallID(rawValue: 2), kind: .unknown, position: Vec2(0.9, 0.4))
        ]
        let result = BallAppearancePass.run(balls: balls, detections: mislabelled, image: image)
        #expect(result[BallID(rawValue: 2)]?.family == .blue)
    }
}
