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
    /// Plane found; waiting for the user to tap the four playing-field
    /// corners — where the cushion NOSES meet, not the outer rail edge
    /// (standard sizes are nose-to-nose; rail taps oversize the table).
    /// `placed` counts corners already down (0...3).
    case placingCorners(placed: Int)
    case confirmingRails
    /// Live tracking is running but no cue ball is on the table — nothing
    /// can be aimed or predicted until it appears.
    case awaitingCueBall
    /// Called-shot mode: the prediction sends an object ball into the
    /// called pocket.
    case onLine
    case tracking(ballCount: Int)
    /// A detector is loaded and firing, but the table is not calibrated,
    /// so the pipeline is not running and NOTHING is being tracked.
    ///
    /// This state exists because the capsule used to report the raw
    /// detector's box count as "Tracking N balls" here. Off a calibrated
    /// table there is no playing surface to gate against, so those boxes
    /// land on floor tiles, window frames and furniture — and the player
    /// was told the app was tracking twenty balls while it tracked none.
    /// `seeing` is deliberately called objects, not balls.
    case needsCalibration(seeing: Int)
    /// Tracking is running, but the app is seeing a fraction of the balls
    /// it recently could. Distinct from `.degraded` because ARKit is
    /// fine — it is the ball detector that has gone quiet, and the two
    /// have different causes and different advice. See DetectionHealth.
    case losingBalls(seen: Int, peak: Int, dark: Bool)
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
        case .placingCorners(let placed): "Tap the cushion-nose corners (\(placed)/4)"
        case .confirmingRails: "Drag dots onto the cushion noses, then lock"
        case .awaitingCueBall: "Place the cue ball — or tap a ball to mark it"
        case .onLine: "On line — send it"
        case .tracking(let count): "Tracking \(count) balls"
        case .needsCalibration(let seeing):
            seeing > 0
                ? "Tap anywhere to calibrate — seeing \(seeing) objects, tracking none"
                : "Tap anywhere to calibrate the table"
        case .losingBalls(let seen, let peak, let dark):
            // Name the number rather than the fault: "seeing 2 of 6"
            // is checkable by looking at the table, and a player who
            // has genuinely pocketed four balls will know to ignore it.
            // The cause is only offered when the frames really are dim.
            dark
                ? "Only seeing \(seen) of \(peak) balls — more light would help"
                : "Only seeing \(seen) of \(peak) balls"
        case .degraded(.fastMotion): "Hold steady…"
        case .degraded(.lowLight): "Need more light"
        case .degraded(.trackingLost): "Re-finding the table…"
        }
    }

    public var systemImage: String {
        switch self {
        case .launching: "circle.dotted"
        case .findingTable: "camera.viewfinder"
        case .placingCorners: "hand.tap"
        case .confirmingRails: "rectangle.dashed"
        case .awaitingCueBall: "circle.dashed"
        case .onLine: "target"
        case .tracking: "checkmark.circle"
        // Not a checkmark: nothing is working yet, and the icon should not
        // say otherwise before the words are read.
        case .needsCalibration: "rectangle.dashed"
        // Not the warning triangle: nothing is broken and nothing was
        // lost. The app is seeing less than it was, which is what a
        // half-filled icon says.
        case .losingBalls: "circle.lefthalf.filled"
        case .degraded: "exclamationmark.triangle"
        }
    }

    /// Overlays fade when confidence is low (05-UX-DESIGN "confidence honesty").
    public var overlayOpacity: Double {
        if case .degraded = self { return 0.4 }
        // Overlays drawn from a third of the balls deserve the same
        // fading as overlays drawn on lost tracking: the guide may be
        // routed around a ball the app cannot currently see.
        if case .losingBalls = self { return 0.4 }
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
