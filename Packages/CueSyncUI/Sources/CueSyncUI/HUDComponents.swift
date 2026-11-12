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
    /// Tracking is running, but most detections now land off the table or
    /// on the rails: the locked calibration no longer matches the camera's
    /// view (device bumped, ARKit session reset). Tapping the capsule
    /// starts calibration again. Raised by `CalibrationHealthMonitor`
    /// (PerceptionKit), which waits for seconds of evidence first.
    case tableMoved

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
        case .tracking(let count): "Tracking \(HUDCopy.count(count, "ball"))"
        case .needsCalibration(let seeing):
            seeing > 0
                ? "Tap anywhere to calibrate — seeing \(HUDCopy.count(seeing, "object")), tracking none"
                : "Tap anywhere to calibrate the table"
        case .losingBalls(let seen, let peak, let dark):
            // Name the number rather than the fault: "seeing 2 of 6"
            // is checkable by looking at the table, and a player who
            // has genuinely pocketed four balls will know to ignore it.
            // The cause is only offered when the frames really are dim.
            dark
                ? "Only seeing \(seen) of \(HUDCopy.count(peak, "ball")) — more light would help"
                : "Only seeing \(seen) of \(HUDCopy.count(peak, "ball"))"
        case .degraded(.fastMotion): "Hold steady…"
        case .degraded(.lowLight): "Need more light"
        case .degraded(.trackingLost): "Re-finding the table…"
        case .tableMoved: "Table moved? Re-calibrate"
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
        case .tableMoved: "arrow.triangle.2.circlepath"
        }
    }

    /// Overlays fade when confidence is low (05-UX-DESIGN "confidence honesty").
    public var overlayOpacity: Double {
        if case .degraded = self { return 0.4 }
        // Overlays drawn from a third of the balls deserve the same
        // fading as overlays drawn on lost tracking: the guide may be
        // routed around a ball the app cannot currently see.
        if case .losingBalls = self { return 0.4 }
        // Guides drawn against a calibration that no longer fits the
        // table point at the wrong place. The layer clamps to its floor
        // (`OverlayStyle.layerOpacity`); the app also stops drawing them.
        if case .tableMoved = self { return 0 }
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
            .hudFont(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(minHeight: HUDMetrics.minimumTarget)
            .hudPlate(Capsule())
            .accessibilityIdentifier("status-capsule")
    }
}

public struct BallCountChip: View {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    /// "1 ball tracked", "6 balls tracked".
    var accessibilityText: String { "\(HUDCopy.count(count, "ball")) tracked" }

    public var body: some View {
        Label("\(count)", systemImage: "circle.grid.3x3.fill")
            .hudFont(.caption, weight: .semibold)
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .hudPlate(Capsule())
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("ball-count-chip")
    }
}

/// Bottom control bar on the HUD plate. Every control in it is given a
/// 44 pt minimum hit target (`HUDMetrics.minimumTarget`) by the bar itself,
/// so a control cannot forget to be tappable, with `HUDMetrics.barSpacing`
/// between neighbours. It is one row while everything fits and wraps to
/// more rows when it does not, so no label is ever truncated
/// (`HUDBarRows`).
public struct HUDBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HUDBarFlowLayout(spacing: HUDMetrics.barSpacing, rowSpacing: 2) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    subview.hudTapTarget()
                }
            }
        }
        .hudFont(.body, weight: .semibold)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        // A rounded rectangle, not a capsule: a capsule's end caps cut into
        // the second row's corners. One row is 52 pt high, where this is
        // indistinguishable from a capsule.
        .hudPlate(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// The bottom bar's shape: one quiet state line, and the buttons.
///
/// One row when the two fit side by side (an iPad), else the state line
/// above the buttons (a phone), so nothing is ever truncated or wrapped
/// mid-control. Every button is at least `HUDMetrics.minimumTarget` tall
/// (`HUDBarButtonStyle`).
public struct HUDBottomBar<StateLine: View, Buttons: View>: View {
    private let stateLine: StateLine
    private let buttons: Buttons

    public init(@ViewBuilder stateLine: () -> StateLine,
                @ViewBuilder buttons: () -> Buttons) {
        self.stateLine = stateLine()
        self.buttons = buttons()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                stateLine
                buttons
            }
            VStack(spacing: 4) {
                stateLine
                buttons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .hudPlate(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// The quiet grey state line: "8 ft · Free play · Any group". A label, in
/// the secondary text colour, at the caption size.
public struct HUDStateLineText: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .hudFont(.caption, weight: .regular)
            .foregroundStyle(Theme.hudTextSecondary.color)
            .lineLimit(1)
            .fixedSize()
            .frame(minHeight: HUDMetrics.minimumTarget)
            .accessibilityIdentifier("hud-state-line")
    }
}

/// A labelled bar button: icon and word, a visible outline so it reads as
/// a button, and a 44 pt minimum height and width.
public struct HUDBarButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hudFont(.body, weight: .semibold)
            .padding(.horizontal, 16)
            .frame(minWidth: HUDMetrics.minimumTarget, minHeight: HUDMetrics.minimumTarget)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.28 : 0.14)))
            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
    }
}
#endif
