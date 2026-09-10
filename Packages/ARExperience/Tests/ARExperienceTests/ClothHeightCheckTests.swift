//
//  ClothHeightCheckTests.swift
//  CueSync AR
//

import Testing
@testable import ARExperience

@Suite("Cloth height check")
struct ClothHeightCheckTests {

    /// The owner's table, measured from the balls on two separate
    /// calibrations: cloth y = -0.533 and -0.582.
    static let cloth = -0.533

    @Test("A hit on the cloth is trusted")
    func onTheCloth() {
        #expect(ClothHeightCheck.trusts(hitHeight: Self.cloth, clothHeight: Self.cloth))
        #expect(ClothHeightCheck.trusts(hitHeight: Self.cloth + 0.01, clothHeight: Self.cloth))
        #expect(ClothHeightCheck.trusts(hitHeight: Self.cloth - 0.01, clothHeight: Self.cloth))
    }

    @Test("A hit on the cushion nose is still trusted")
    func onTheNose() {
        // The nose sits a few centimetres above the bed, and a tap aimed at
        // it legitimately lands there. Rejecting that would refuse the
        // correct answer.
        #expect(ClothHeightCheck.trusts(hitHeight: Self.cloth + 0.035, clothHeight: Self.cloth))
    }

    @Test("A hit on the rail top is NOT trusted")
    func onTheRail() {
        // The rail top is the surface ARKit most readily finds on a pool
        // table, and it is the wrong one.
        #expect(!ClothHeightCheck.trusts(hitHeight: Self.cloth + 0.08, clothHeight: Self.cloth))
    }

    @Test("A hit on the floor is emphatically not trusted")
    func onTheFloor() {
        // Roughly 80 cm below the bed. This is the case that put the quad in
        // the air: `.existingPlaneInfinite` extends the floor plane under
        // the whole room, so a tap could land on it and the corners would be
        // placed relative to a surface that is not the table at all.
        #expect(!ClothHeightCheck.trusts(hitHeight: Self.cloth - 0.8, clothHeight: Self.cloth))
    }

    @Test("A hit ABOVE the table is not trusted either")
    func aboveTheTable() {
        // A side table, a chair seat, a console under a TV — every flat
        // surface in the room is a candidate once planes are infinite.
        for offset in [0.10, 0.25, 0.5, 1.0] {
            #expect(!ClothHeightCheck.trusts(hitHeight: Self.cloth + offset,
                                             clothHeight: Self.cloth),
                    "a hit \(offset) m above the cloth should be refused")
        }
    }

    @Test("The tolerance sits between the nose and the rail")
    func toleranceIsBetweenNoseAndRail() {
        // Stated as a property rather than a magic number, so a future
        // change has to argue with the geometry rather than the constant.
        #expect(ClothHeightCheck.tolerance > 0.04, "must admit a cushion nose")
        #expect(ClothHeightCheck.tolerance < 0.08, "must reject a rail top")
    }
}
