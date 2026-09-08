//
//  MetricPalette.swift
//  ARExperience
//
//  A machine-readable overlay palette for session recordings: every
//  overlay marker kind gets a pure, opaque, saturated colour, pairwise far
//  apart in RGB, so a screenshot of the rendered view (the mirror's
//  frame.jpg, a snapshot) can be colour-keyed to find each overlay in
//  pixels and compared with the projected points in snapshots.jsonl. The
//  design palette (felt green, amber, translucent) is for people; this one
//  is for measurement. Pure — tested on Linux.
//

import Foundation

public enum OverlayPaletteMode: String, Sendable, Equatable {
    /// The 05-UX-DESIGN colours and translucency.
    case design
    /// Opaque, colour-keyable markers (`MetricPalette`).
    case metric
}

public enum MetricPalette {
    public enum Marker: String, CaseIterable, Sendable {
        case ball
        case cueBall
        case ghostBall
        case pocket
        case calledPocket
        case calledPocketOnLine
        case stripAim
        case stripObject
        case stripCueAfter
        case stripScratch
    }

    /// Guaranteed Chebyshev distance (max per-channel difference, 0–255)
    /// between any two markers' colours — the threshold a colour-key can
    /// rely on. Tested.
    public static let minimumChannelSeparation = 96

    /// 0xRRGGBB.
    public static func color(for marker: Marker) -> UInt32 {
        switch marker {
        case .ball: 0xFF00FF               // magenta
        case .cueBall: 0x00FFFF            // cyan
        case .ghostBall: 0xFFFF00          // yellow
        case .pocket: 0x00FF00             // green
        case .calledPocket: 0xFF8000       // orange
        case .calledPocketOnLine: 0x0000FF // blue
        case .stripAim: 0xFF0000           // red
        case .stripObject: 0x00FF80        // spring green
        case .stripCueAfter: 0x8000FF      // violet
        case .stripScratch: 0xFFFFFF       // white
        }
    }

    /// The strip marker for a design-palette strip colour token
    /// (OverlayLayout.compose's aim/object/cueAfter/scratch defaults).
    /// Unknown tokens map to the aim strip so nothing renders invisible.
    public static func stripMarker(forDesignColor rgb: UInt32) -> Marker {
        switch rgb {
        case 0xF5A623: .stripAim
        case 0x2FA36B: .stripObject
        case 0x4A90D9: .stripCueAfter
        case 0xE8604C: .stripScratch
        default: .stripAim
        }
    }

    /// Max per-channel difference between two 0xRRGGBB colours.
    public static func channelSeparation(_ a: UInt32, _ b: UInt32) -> Int {
        var worst = 0
        for shift in [16, 8, 0] as [UInt32] {
            let ca = Int((a >> shift) & 0xFF)
            let cb = Int((b >> shift) & 0xFF)
            worst = max(worst, abs(ca - cb))
        }
        return worst
    }
}
