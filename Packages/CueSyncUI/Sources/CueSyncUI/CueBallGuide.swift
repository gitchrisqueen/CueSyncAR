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

    /// A dead-centre hit is the default, so it does not earn a big tile:
    /// the guide collapses to a small chip with the dot and no label, and
    /// expands only when the advice is to hit somewhere else.
    var isCentreHit: Bool {
        abs(tipOffset.x) < 0.05 && abs(tipOffset.y) < 0.05
    }

    private var faceDiameter: CGFloat { isCentreHit ? 52 : 74 }

    public var body: some View {
        VStack(spacing: 6) {
            face
            if !isCentreHit {
                Text(headline)
                    .hudFont(.caption, weight: .semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let cut = cutAngleDegrees {
                    Text("cut \(Int(cut.rounded()))°")
                        .hudFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.hudTextSecondary.color)
                }
            }
        }
        .padding(isCentreHit ? 6 : 10)
        .frame(width: isCentreHit ? nil : 130)
        .hudPlate(RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cue ball strike guide: \(headline)")
        .accessibilityIdentifier("cue-ball-guide")
    }

    private var face: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.95))
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
            // Crosshair + edge ticks (top/bottom/left/right).
            Path { path in
                let c = faceDiameter / 2
                for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
                    path.move(to: CGPoint(x: c + dx * (c - 8), y: c - dy * (c - 8)))
                    path.addLine(to: CGPoint(x: c + dx * (c - 2), y: c - dy * (c - 2)))
                }
            }
            .stroke(.black.opacity(0.45), lineWidth: 2)
            // Recommended tip contact (screen y is down; offset y is up).
            Circle()
                .fill(Theme.feltGreen.color)
                .frame(width: 14, height: 14)
                .offset(x: CGFloat(tipOffset.x) * (faceDiameter / 2 - 10),
                        y: CGFloat(-tipOffset.y) * (faceDiameter / 2 - 10))
                .animation(.snappy, value: tipOffset.x)
                .animation(.snappy, value: tipOffset.y)
        }
        .frame(width: faceDiameter, height: faceDiameter)
    }
}
#endif
