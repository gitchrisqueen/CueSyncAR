//
//  HUDComponents.swift
//  CueSyncUI
//
//  Glass HUD building blocks per 05-UX-DESIGN: status capsule, ball-count
//  chip, and the bottom control bar. Status text/icon mapping is pure
//  (HUDStatus) so it stays Linux-testable.
//

import CueSyncCore
import Foundation

/// Pure model behind the status capsule — one place for every user-facing
/// tracking state string, so copy stays consistent and testable.
public enum HUDStatus: Sendable, Equatable {
    case launching
    case findingTable
    case confirmingRails
    case tracking(ballCount: Int)
    case degraded(reason: DegradedReason)

    public enum DegradedReason: String, Sendable {
        case fastMotion
        case lowLight
        case trackingLost
    }

    public var label: String {
        switch self {
        case .launching: "Starting…"
        case .findingTable: "Point at the table"
        case .confirmingRails: "Adjust the corners, then lock"
        case .tracking(let count): "Tracking \(count) balls"
        case .degraded(.fastMotion): "Hold steady…"
        case .degraded(.lowLight): "Need more light"
        case .degraded(.trackingLost): "Re-finding the table…"
        }
    }

    public var systemImage: String {
        switch self {
        case .launching: "circle.dotted"
        case .findingTable: "camera.viewfinder"
        case .confirmingRails: "rectangle.dashed"
        case .tracking: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        }
    }

    /// Overlays fade when confidence is low (05-UX-DESIGN "confidence honesty").
    public var overlayOpacity: Double {
        if case .degraded = self { return 0.4 }
        return 1.0
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct StatusCapsule: View {
    public let status: HUDStatus

    public init(status: HUDStatus) {
        self.status = status
    }

    public var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("status-capsule")
    }
}

public struct BallCountChip: View {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Label("\(count)", systemImage: "circle.grid.3x3.fill")
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("\(count) balls tracked")
            .accessibilityIdentifier("ball-count-chip")
    }
}

/// Bottom glass control bar. Content lays out horizontally with standard
/// spacing and ≥44pt hit targets.
public struct HUDBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 16) {
            content
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
#endif
