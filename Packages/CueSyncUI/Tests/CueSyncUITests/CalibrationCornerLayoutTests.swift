//
//  CalibrationCornerLayoutTests.swift
//  CueSyncUITests
//
//  The regression these lock down: a corner that fails to project must not
//  renumber the corners that follow it. The overlay draws each corner twice
//  (Canvas dot, positioned drag handle) from the same indices, so a shift in
//  one pass and not the other separates the white handle from its green dot
//  — the symptom reported from the table on 2026-09-08.
//

// Foundation, NOT CoreGraphics: these packages build on Linux too, where
// CoreGraphics does not exist. swift-corelibs-foundation supplies CGPoint
// and CGFloat, which is all this suite needs.
import Foundation
import Testing
@testable import CueSyncUI

@Suite("Calibration corner layout")
struct CalibrationCornerLayoutTests {
    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    @Test("Every corner projected: indices are identity, outline closes")
    func allProjected() {
        let layout = CalibrationCornerLayout(points: [
            point(0, 0), point(10, 0), point(10, 10), point(0, 10)])
        #expect(layout.drawable.map(\.index) == [0, 1, 2, 3])
        #expect(layout.drawable.map(\.point) == [
            point(0, 0), point(10, 0), point(10, 10), point(0, 10)])
        #expect(layout.closedOutline?.count == 4)
    }

    @Test("A dropped corner does NOT renumber the ones after it")
    func gapPreservesIndices() {
        // Corner 1 is behind the camera. Corners 2 and 3 must keep their
        // own indices — with compactMap they would have become 1 and 2, and
        // the drag handle for corner 2 would sit on corner 3's dot.
        let layout = CalibrationCornerLayout(points: [
            point(0, 0), nil, point(10, 10), point(0, 10)])
        #expect(layout.drawable.map(\.index) == [0, 2, 3])
        #expect(layout.point(at: 2) == point(10, 10))
        #expect(layout.point(at: 1) == nil)
    }

    @Test("Handle lookup agrees with the dot drawn at the same index")
    func handleAndDotAgree() {
        let layout = CalibrationCornerLayout(points: [
            point(1, 1), nil, point(3, 3), point(4, 4)])
        for (index, expected) in layout.drawable {
            #expect(layout.point(at: index) == expected)
        }
    }

    @Test("Outline is withheld unless all four corners project")
    func partialOutlineWithheld() {
        let missing = CalibrationCornerLayout(points: [
            point(0, 0), nil, point(10, 10), point(0, 10)])
        #expect(missing.closedOutline == nil)

        // Fewer than four corners placed yet — also no outline.
        let partial = CalibrationCornerLayout(points: [point(0, 0), point(1, 1)])
        #expect(partial.closedOutline == nil)
    }

    @Test("Empty and out-of-range lookups are safe")
    func boundsSafety() {
        let empty = CalibrationCornerLayout(points: [])
        #expect(empty.drawable.isEmpty)
        #expect(empty.closedOutline == nil)
        #expect(empty.point(at: 0) == nil)
        #expect(empty.point(at: -1) == nil)
    }
}
