import CueSyncCore
import Testing
@testable import CueSyncUI

@Suite("HUD placement")
struct HUDPlacementTests {
    private let screen = Vec2(1000, 800)

    @Test("With no pocket under it the cluster stays where it is")
    func staysPut() {
        let pockets = [Vec2(100, 100), Vec2(900, 120), Vec2(500, 90)]
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen) == .leading)
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen,
                                         preferred: .trailing) == .trailing)
    }

    @Test("Near pockets at both low corners push the cluster to the middle")
    func dodgesBothNearPockets() {
        // How a parked iPad at the head rail sees the near pockets: low on
        // the screen, at the far left and the far right.
        let pockets = [Vec2(90, 600), Vec2(970, 590), Vec2(380, 330), Vec2(700, 330)]
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen) == .center)
    }

    @Test("A single near-left pocket moves the cluster off the left edge")
    func dodgesTheNearLeftPocket() {
        let pockets = [Vec2(120, 650), Vec2(100, 150)]
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen) == .center)
    }

    @Test("If the middle is covered too it takes the free edge")
    func takesTheFreeEdge() {
        // Pockets low at left and in the middle; the right is clear.
        let pockets = [Vec2(120, 650), Vec2(500, 700)]
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen,
                                         widthFraction: 0.4) == .trailing)
    }

    @Test("When every position covers a pocket it does not hop")
    func everywhereCovered() {
        let pockets = [Vec2(120, 650), Vec2(500, 700), Vec2(880, 650)]
        #expect(HUDPlacement.clusterSide(pockets: pockets, viewport: screen) == .leading)
    }

    @Test("A pocket high on the screen is never under the cluster")
    func farPocketsDoNotCount() {
        #expect(HUDPlacement.clusterSide(pockets: [Vec2(50, 50), Vec2(950, 60)],
                                         viewport: screen) == .leading)
    }

    @Test("A zero-size viewport keeps the preferred side")
    func degenerateViewport() {
        #expect(HUDPlacement.clusterSide(pockets: [Vec2(1, 1)], viewport: Vec2(0, 0)) == .leading)
    }
}
