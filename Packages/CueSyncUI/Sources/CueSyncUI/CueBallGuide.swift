//
//  CueBallGuide.swift
//  CueSyncUI
//
//  The cue-ball face widget: a glass card showing where on the cue ball to
//  strike (tip-contact dot from CoachKit's ShotGuide), with top/bottom/
//  left/right tick marks and the cut-angle readout. Pure presentation —
//  all recommendation logic lives (tested) in CoachKit.
//

import CueSyncCore
import Foundation

#if canImport(SwiftUI)
import SwiftUI

public struct CueBallGuideView: View {
    /// Tip contact: x right, y up, unit = ball radius (−1...1).
    public let tipOffset: Vec2
    public let headline: String
    public let cutAngleDegrees: Double?

    public init(tipOffset: Vec2, headline: String, cutAngleDegrees: Double?) {
        self.tipOffset = tipOffset
        self.headline = headline
        self.cutAngleDegrees = cutAngleDegrees
    }

    private let faceDiameter: CGFloat = 74

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.9))
                    .overlay(Circle().stroke(.secondary.opacity(0.5), lineWidth: 1))
                // Crosshair + edge ticks (top/bottom/left/right).
                Path { path in
                    let c = faceDiameter / 2
                    for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
                        path.move(to: CGPoint(x: c + dx * (c - 8), y: c - dy * (c - 8)))
                        path.addLine(to: CGPoint(x: c + dx * (c - 2), y: c - dy * (c - 2)))
                    }
                }
                .stroke(.secondary.opacity(0.6), lineWidth: 2)
                // Recommended tip contact (screen y is down; offset y is up).
                Circle()
                    .fill(Color(red: Theme.feltGreen.red,
                                green: Theme.feltGreen.green,
                                blue: Theme.feltGreen.blue))
                    .frame(width: 14, height: 14)
                    .offset(x: CGFloat(tipOffset.x) * (faceDiameter / 2 - 10),
                            y: CGFloat(-tipOffset.y) * (faceDiameter / 2 - 10))
                    .animation(.snappy, value: tipOffset.x)
                    .animation(.snappy, value: tipOffset.y)
            }
            .frame(width: faceDiameter, height: faceDiameter)

            Text(headline)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let cut = cutAngleDegrees {
                Text("cut \(Int(cut.rounded()))°")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 120)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cue ball strike guide: \(headline)")
        .accessibilityIdentifier("cue-ball-guide")
    }
}
#endif
