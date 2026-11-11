import CueSyncCore
import Foundation
import Testing
@testable import CueSyncUI

@Suite("HUD cluster plan")
struct HUDClusterPlanTests {
    // An iPad (9th gen) in landscape, in points.
    private let ipad = Vec2(1080, 810)
    private let phone = Vec2(390, 844)
    private let sizes = HUDClusterSizes(wide: Vec2(600, 150), column: Vec2(260, 300),
                                        pill: Vec2(460, 56))
    private let insets = HUDClusterInsets(top: 130, bottom: 90, side: 16)

    /// A tripod looks at the table from the head rail: a trapezoid, wide at
    /// the near rail and narrower at the far one, in the lower middle.
    private let tripodQuad = [Vec2(300, 330), Vec2(780, 330), Vec2(930, 640), Vec2(150, 640)]

    /// What the app hands in on a phone: the pill spans the screen width.
    private let phoneSizes = HUDClusterSizes(wide: Vec2(358, 130), column: Vec2(260, 250),
                                             pill: Vec2(358, 64))

    private func plan(_ quad: [Vec2], on screen: Vec2, previous: HUDClusterPlan? = nil,
                      pockets: [Vec2] = []) -> HUDClusterPlan {
        HUDPlacement.clusterPlan(tableQuad: quad, pockets: pockets, viewport: screen,
                                 sizes: screen.x < 600 ? phoneSizes : sizes, insets: insets,
                                 previous: previous)
    }

    // MARK: The measured case

    @Test("Landscape iPad, table in the lower middle: the card leaves the near cloth for the top band")
    func ipadLandscapeTableCentred() {
        let result = plan(tripodQuad, on: ipad)
        #expect(result.style == .wide)
        #expect(result.anchor == .topCenter)
        #expect(result.clearOfTable)
        // Nothing of the card is on the table, with the clearance to spare.
        let hull = HUDPlacement.convexHull(tripodQuad)
        #expect(!HUDPlacement.intersects(result.frame, hull: hull))
        #expect(result.frame.maxY < 330)
        // ...and it is the card the old placement would have put on cloth.
        let bottom = HUDRect(minX: 16, minY: 810 - 90 - 150, width: 600, height: 150)
        #expect(HUDPlacement.intersects(bottom, hull: hull))
    }

    @Test("Table high on the screen leaves the bottom edge to the card")
    func tableHighLeavesTheBottom() {
        let high = [Vec2(300, 120), Vec2(780, 120), Vec2(930, 400), Vec2(150, 400)]
        let result = plan(high, on: ipad)
        #expect(result.style == .wide)
        #expect(result.anchor == .bottomLeading)
        #expect(result.clearOfTable)
    }

    @Test("A table pushed to one side leaves the other side column")
    func sideColumn() {
        // Top and bottom blocked; only the left strip is free.
        let right = [Vec2(330, 100), Vec2(1060, 100), Vec2(1060, 700), Vec2(330, 700)]
        let result = plan(right, on: ipad)
        #expect(result.style == .column)
        #expect(result.anchor == .leadingColumn)
        #expect(result.frame.width == 260)
        #expect(result.clearOfTable)
    }

    @Test("Table fills the frame but for a strip at the bottom: the pill takes it")
    func pillWhenNoPanelFits() {
        let tall = [Vec2(150, 100), Vec2(930, 100), Vec2(930, 640), Vec2(150, 640)]
        let result = plan(tall, on: ipad)
        #expect(result.style == .pill)
        #expect(result.anchor == .bottomLeading)
        #expect(result.clearOfTable)
        #expect(result.frame.minY >= 640)
    }

    @Test("Table fills the whole frame: the pill stays, readable, where the card was")
    func tableFillsTheFrame() {
        let all = [Vec2(0, 0), Vec2(1080, 0), Vec2(1080, 810), Vec2(0, 810)]
        let result = plan(all, on: ipad)
        // Never hidden, never a panel on top of the cloth.
        #expect(result.style == .pill)
        #expect(result.anchor == .bottomLeading)
        #expect(!result.clearOfTable)
        #expect(result.frame.width == 460 && result.frame.height == 56)
    }

    // MARK: Narrow screens

    @Test("A portrait phone gets the one-line pill, below the table")
    func portraitPhone() {
        let quad = [Vec2(50, 300), Vec2(340, 300), Vec2(340, 520), Vec2(50, 520)]
        let result = plan(quad, on: phone)
        #expect(result.style == .pill)
        #expect(result.anchor == .bottomLeading)
        #expect(result.clearOfTable)
    }

    @Test("A phone in landscape is narrow too: pill only")
    func landscapePhone() {
        let result = HUDPlacement.clusterPlan(
            tableQuad: [], viewport: Vec2(844, 390),
            sizes: HUDClusterSizes(wide: Vec2(600, 120), column: Vec2(260, 250), pill: Vec2(400, 52)),
            insets: HUDClusterInsets(top: 90, bottom: 70, side: 16))
        #expect(result.style == .pill)
    }

    // MARK: No table known

    @Test("No calibration: the default, the panel at the bottom leading edge")
    func noCalibrationDefault() {
        let result = plan([], on: ipad)
        #expect(result.style == .wide)
        #expect(result.anchor == .bottomLeading)
        #expect(result.clearOfTable)
    }

    @Test("No calibration on a phone: the default is the pill")
    func noCalibrationPhone() {
        let result = plan([], on: phone)
        #expect(result.style == .pill)
        #expect(result.anchor == .bottomLeading)
    }

    @Test("Without a table, pockets still push the default off the corner")
    func pocketsStillDodgedWithoutAQuad() {
        let result = plan([], on: ipad, pockets: [Vec2(90, 700), Vec2(990, 690)])
        #expect(result.anchor == .bottomCenter)
    }

    @Test("Fewer than three quad points counts as no table")
    func degenerateQuad() {
        let result = plan([Vec2(0, 0), Vec2(1000, 800)], on: ipad)
        #expect(result.anchor == .bottomLeading)
        #expect(result.clearOfTable)
    }

    @Test("A zero-size screen does not crash and still returns a pill")
    func zeroViewport() {
        let result = plan(tripodQuad, on: Vec2(0, 0))
        #expect(result.style == .pill)
        #expect(!result.clearOfTable)
    }

    // MARK: Steadiness

    @Test("A place that is still clear is kept, so the card does not hop")
    func keepsThePreviousPlaceWhileClear() {
        // The table is clear of the top band AND the left column, but the
        // order of preference would pick the top band first.
        let quad = [Vec2(330, 330), Vec2(1060, 330), Vec2(1060, 640), Vec2(330, 640)]
        let fresh = plan(quad, on: ipad)
        #expect(fresh.anchor == .topCenter)
        let column = HUDClusterPlan(style: .column, anchor: .leadingColumn,
                                    frame: HUDRect(minX: 16, minY: 420, width: 260, height: 300),
                                    clearOfTable: true)
        let kept = plan(quad, on: ipad, previous: column)
        #expect(kept.anchor == .leadingColumn)
        // Once the previous place is covered, it moves.
        let covered = [Vec2(0, 300), Vec2(1080, 300), Vec2(1080, 700), Vec2(0, 700)]
        #expect(plan(covered, on: ipad, previous: column).anchor != .leadingColumn)
    }

    // MARK: Geometry

    @Test("The convex hull drops an interior point and ignores input order")
    func hull() {
        let pts = [Vec2(0, 0), Vec2(10, 10), Vec2(10, 0), Vec2(5, 5), Vec2(0, 10)]
        #expect(HUDPlacement.convexHull(pts).count == 4)
    }

    @Test("A rectangle in the empty corner of a slanted quad does not intersect it")
    func slantedCorner() {
        // Bounding boxes overlap, the shapes do not: only the polygon-edge
        // axes can tell.
        let diamond = HUDPlacement.convexHull([Vec2(50, 0), Vec2(100, 50), Vec2(50, 100), Vec2(0, 50)])
        let corner = HUDRect(minX: 0, minY: 0, width: 20, height: 20)
        #expect(!HUDPlacement.intersects(corner, hull: diamond))
        let middle = HUDRect(minX: 40, minY: 40, width: 20, height: 20)
        #expect(HUDPlacement.intersects(middle, hull: diamond))
    }

    @Test("Touching edges are not an overlap")
    func touching() {
        let square = HUDPlacement.convexHull([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)])
        #expect(!HUDPlacement.intersects(HUDRect(minX: 10, minY: 0, width: 5, height: 5), hull: square))
    }

    @Test("HUDRect extents and inflation")
    func rect() {
        let r = HUDRect(minX: 10, minY: 20, width: 100, height: 50)
        #expect(r.maxX == 110 && r.maxY == 70 && r.midX == 60 && r.midY == 45)
        #expect(r.inflated(by: 5) == HUDRect(minX: 5, minY: 15, width: 110, height: 60))
    }

    // MARK: Evidence

    /// Writes one SVG per case when `HUD_PLACEMENT_SVG_DIR` is set, so the
    /// decision can be looked at. A no-op otherwise.
    @Test("Render the placement cases for review (only when asked)")
    func renderCases() throws {
        guard let dir = ProcessInfo.processInfo.environment["HUD_PLACEMENT_SVG_DIR"] else { return }
        let cases: [(String, [Vec2], Vec2)] = [
            ("ipad-landscape-table-centred", tripodQuad, ipad),
            ("ipad-landscape-table-high", [Vec2(300, 120), Vec2(780, 120), Vec2(930, 400), Vec2(150, 400)], ipad),
            ("ipad-landscape-table-right", [Vec2(330, 100), Vec2(1060, 100), Vec2(1060, 700), Vec2(330, 700)], ipad),
            ("ipad-landscape-table-fills", [Vec2(0, 0), Vec2(1080, 0), Vec2(1080, 810), Vec2(0, 810)], ipad),
            ("phone-portrait", [Vec2(50, 300), Vec2(340, 300), Vec2(340, 520), Vec2(50, 520)], phone)
        ]
        for (name, quad, screen) in cases {
            let result = plan(quad, on: screen)
            let polygon = quad.map { "\($0.x),\($0.y)" }.joined(separator: " ")
            let f = result.frame
            // Square canvas (QuickLook thumbnails crop to a square), the
            // screen drawn on it with its outline.
            let side = Int(max(screen.x, screen.y))
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(side)" height="\(side)" \
            viewBox="0 0 \(side) \(side)">
            <rect width="100%" height="100%" fill="#444"/>
            <rect width="\(Int(screen.x))" height="\(Int(screen.y))" fill="#1b2a26" stroke="#fff" stroke-width="4"/>
            <polygon points="\(polygon)" fill="#2f7d55" stroke="#6b4a2b" stroke-width="10"/>
            <rect x="\(f.minX)" y="\(f.minY)" width="\(f.width)" height="\(f.height)" rx="16" \
            fill="#ffffff" fill-opacity="0.9" stroke="#e8a33d" stroke-width="3"/>
            <text x="\(f.minX + 12)" y="\(f.midY)" font-family="Helvetica" font-size="22" fill="#111">\
            \(name): \(result.style) @ \(result.anchor)\(result.clearOfTable ? "" : " (on cloth)")</text>
            </svg>
            """
            try svg.write(toFile: dir + "/" + name + ".svg", atomically: true, encoding: .utf8)
        }
    }
}
