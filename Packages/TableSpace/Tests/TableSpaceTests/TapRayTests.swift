//
//  TapRayTests.swift
//  CueSync AR
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Tap ray")
struct TapRayTests {

    @Test("A ray meets the plane it was aimed at")
    func hitsThePlane() {
        let ray = TapRay(origin: Vec3(0, 0, 0), direction: Vec3(0, -1, 0))
        let hit = try? #require(ray.intersect(planeHeight: -0.533))
        #expect(abs((hit?.y ?? 0) - (-0.533)) < 1e-9)
    }

    @Test("The SAME ray at a corrected height lands somewhere else — the point of storing it")
    func reintersectingMovesTheCorner() {
        // A tap taken at a slant. The whole reason to keep the ray is that
        // correcting the height moves the corner in x and z too, not only
        // in y — so translating a locked table vertically would NOT fix a
        // wrong plane.
        let ray = TapRay(origin: Vec3(0, 0, 0), direction: Vec3(0.5, -1, 0.3))
        let wrong = try? #require(ray.intersect(planeHeight: -0.40))
        let right = try? #require(ray.intersect(planeHeight: -0.533))
        #expect(abs((right?.y ?? 0) - (-0.533)) < 1e-9)
        #expect(abs((right?.x ?? 0) - (wrong?.x ?? 0)) > 0.05,
                "correcting the height must move the corner horizontally too")
        #expect(abs((right?.z ?? 0) - (wrong?.z ?? 0)) > 0.03)
    }

    @Test("A grazing ray has no honest answer")
    func grazingRayRefuses() {
        // A device resting on the rail sights nearly parallel to the cloth.
        let ray = TapRay(origin: Vec3(0, -0.53, 0), direction: Vec3(1, 0, 0))
        #expect(ray.intersect(planeHeight: -0.533) == nil)
    }

    @Test("A plane behind the camera is refused, not extrapolated")
    func behindTheCameraRefuses() {
        // Looking UP, asked for a plane below: returning a point anyway is
        // how a corner ends up on the far side of the room.
        let ray = TapRay(origin: Vec3(0, 0, 0), direction: Vec3(0, 1, 0))
        #expect(ray.intersect(planeHeight: -0.533) == nil)
    }

    @Test("Direction is normalized on the way in")
    func directionIsNormalized() {
        let ray = TapRay(origin: .zero, direction: Vec3(0, -10, 0))
        #expect(abs(ray.direction.length - 1) < 1e-9)
    }

    @Test("It round-trips through Codable, so a saved calibration can still be refined")
    func codable() throws {
        let ray = TapRay(origin: Vec3(0.1, 0.2, 0.3), direction: Vec3(0.5, -1, 0.3))
        let data = try JSONEncoder().encode(ray)
        let back = try JSONDecoder().decode(TapRay.self, from: data)
        #expect(back == ray)
    }
}
