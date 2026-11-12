//
//  CueBallGuide.swift
//  CueSyncUI
//
//  The cue-ball guide: a dark tile with the cue ball's face (the tip-contact
//  dot from CoachKit's ShotGuide) and ONE word under it: "Draw", "Stun",
//  "Follow", "Left" or "Right". Pure presentation: all recommendation logic
//  lives (tested) in CoachKit, and the word is chosen by `HUDCopy.guideWord`.
//
//  It used to be a white disc with a green dot and no word, the brightest
//  object on the screen, in a different place in each state. When the
//  advice is centre ball it is not drawn at all.
//

import CueSyncCore
import Foundation

#if canImport(SwiftUI)
import SwiftUI

public struct CueBallGuideView: View {
    /// Tip contact: x right, y up, unit = ball radius (−1...1).
    public let tipOffset: Vec2
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(tipOffset: Vec2) {
        self.tipOffset = tipOffset
    }

    private var word: HUDCopy.GuideWord? { HUDCopy.guideWord(tipOffset: tipOffset) }
    private var faceDiameter: CGFloat { sizeClass == .regular ? 64 : 48 }

    /// Nothing for a centre hit: the default does not earn a tile.
    public var body: some View {
        if let word {
            VStack(spacing: 4) {
                face
                Text(word.rawValue)
                    .hudFont(.body, weight: .bold)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius - 4,
                                         style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius - 4,
                                      style: .continuous)
                .stroke(Theme.hudTextSecondary.color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(Theme.hudText.color)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cue ball: hit \(word.rawValue.lowercased())")
            .accessibilityIdentifier("cue-ball-guide")
        }
    }

    private var face: some View {
        ZStack {
            // A dark disc: a white one was the loudest thing on screen.
            Circle()
                .fill(Color(red: 0.20, green: 0.22, blue: 0.25))
                .overlay(Circle().stroke(Theme.hudTextSecondary.color.opacity(0.8), lineWidth: 2))
            // Edge ticks (top/bottom/left/right).
            Path { path in
                let c = faceDiameter / 2
                for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
                    path.move(to: CGPoint(x: c + dx * (c - 8), y: c - dy * (c - 8)))
                    path.addLine(to: CGPoint(x: c + dx * (c - 3), y: c - dy * (c - 3)))
                }
            }
            .stroke(Theme.hudTextSecondary.color.opacity(0.7), lineWidth: 2)
            // Recommended tip contact (screen y is down; offset y is up).
            Circle()
                .fill(Theme.easyText.color)
                .frame(width: 14, height: 14)
                .offset(x: CGFloat(tipOffset.x) * (faceDiameter / 2 - 10),
                        y: CGFloat(-tipOffset.y) * (faceDiameter / 2 - 10))
        }
        .frame(width: faceDiameter, height: faceDiameter)
    }
}
#endif
