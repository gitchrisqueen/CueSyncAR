//
//  ShotAdvisorCard.swift
//  CueSyncUI
//
//  HUD card for the shot advisor: what to shoot, how hard it is, and a
//  button to step to the next-best option. Pure presentation — the
//  recommendation logic lives (tested) in CoachKit's ShotPlanner.
//

#if canImport(SwiftUI)
import SwiftUI

public struct ShotAdvisorCard: View {
    public let title: String
    public let detail: String
    public let color: ColorToken
    /// 1-based position of this option among `total`.
    public let position: Int
    public let total: Int
    public let onNext: () -> Void

    public init(title: String, detail: String, color: ColorToken,
                position: Int, total: Int, onNext: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.color = color
        self.position = position
        self.total = total
        self.onNext = onNext
    }

    public var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("SUGGESTED SHOT")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(color.color)
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if total > 1 {
                Button(action: onNext) {
                    VStack(spacing: 1) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(position)/\(total)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next shot suggestion")
                .accessibilityValue("\(position) of \(total)")
                .accessibilityIdentifier("next-shot-button")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        // Dark scrim + dark scheme: legible over any camera feed and in
        // both system appearances (HUD copy is white-on-dark, arcade style).
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(color.color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested shot: \(title), \(detail)")
        .accessibilityIdentifier("shot-advisor-card")
    }
}

#Preview("Shot advisor card") {
    VStack(spacing: 12) {
        ShotAdvisorCard(title: "5-ball → top-right corner", detail: "straight in · easy",
                        color: Theme.adviceEasy, position: 1, total: 3, onNext: {})
        ShotAdvisorCard(title: "8-ball → bottom side pocket", detail: "48° cut · hard",
                        color: Theme.adviceHard, position: 3, total: 3, onNext: {})
    }
    .padding()
    .background(Color.black)
}
#endif
