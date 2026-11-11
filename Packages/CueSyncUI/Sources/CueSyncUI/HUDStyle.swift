//
//  HUDStyle.swift
//  CueSyncUI
//
//  How the HUD is drawn: one dark plate, light text, text sizes that scale
//  with Dynamic Type AND with the screen, and hit targets that are never
//  smaller than a thumb.
//
//  The sizes and thresholds are plain values, not SwiftUI, so a test can
//  hold them (HUDContrastTests). The SwiftUI half below only applies them.
//
//  Why a plate and not a better material: the HUD sits on a live camera
//  feed. Thin material is a blur of whatever is behind it, so its contrast
//  is a property of the room, and two reviews measured it at 1.6 to 3.1 : 1
//  on a bright wall. A mostly opaque dark scrim makes the contrast a
//  property of the HUD instead (see Contrast.swift).
//

import Foundation

/// The type roles the HUD uses. Roles, not point sizes, so a view says
/// what the text IS and the scale decides how big that is here.
public enum HUDTextRole: CaseIterable, Sendable {
    /// The shot call: "Blue ball → right side pocket".
    case headline
    /// The status capsule, the bar, the tier word.
    case body
    /// Secondary lines: advice, hints, chips.
    case caption

    /// Point size on a compact-width screen (a phone) at the default
    /// Dynamic Type size.
    public var baseSize: Double {
        switch self {
        case .headline: 20
        case .body: 16
        case .caption: 14
        }
    }

    /// How much bigger the HUD is on a regular-width screen (an iPad).
    /// The iPad is read from the shooting position, 1.5 to 3 m from a
    /// parked screen, where 14 pt secondary text is 1.4 mm tall on the
    /// glass. 1.45 puts secondary text at about 20 pt.
    public static let regularWidthScale = 1.45
}

public enum HUDMetrics {
    /// Smallest tappable height and width, in points (Apple's minimum).
    public static let minimumTarget = 44.0
    /// Space between two bar controls, so a fat thumb hits one of them.
    public static let barSpacing = 12.0
    /// Widest a card gets, compact and regular width.
    public static let cardWidthCompact = 300.0
    public static let cardWidthRegular = 440.0
    /// Corner radius of a HUD plate.
    public static let cornerRadius = 16.0
}

#if canImport(SwiftUI)
import SwiftUI

private struct HUDFontModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(_ role: HUDTextRole, weight: Font.Weight) {
        // `relativeTo` picks the Dynamic Type curve the size follows.
        let style: Font.TextStyle = switch role {
        case .headline: .title3
        case .body: .callout
        case .caption: .footnote
        }
        _size = ScaledMetric(wrappedValue: CGFloat(role.baseSize), relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        let scale = sizeClass == .regular ? CGFloat(HUDTextRole.regularWidthScale) : 1
        return content.font(.system(size: size * scale, weight: weight))
    }
}

private struct HUDCardWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.frame(maxWidth: sizeClass == .regular ? HUDMetrics.cardWidthRegular
                                                      : HUDMetrics.cardWidthCompact,
                      alignment: .leading)
    }
}

extension View {
    /// A card's widest extent: wider on an iPad, where the text is bigger.
    public func hudCardWidth() -> some View {
        modifier(HUDCardWidthModifier())
    }

    /// HUD text at a role's size: scales with Dynamic Type, and with the
    /// screen on a regular-width iPad.
    public func hudFont(_ role: HUDTextRole, weight: Font.Weight = .medium) -> some View {
        modifier(HUDFontModifier(role, weight: weight))
    }

    /// Draw this on the HUD plate: dark scrim over a thin material, light
    /// text, and the dark colour scheme whatever the phone is set to (the
    /// plate is dark in light mode too; the camera behind it is not).
    public func hudPlate<S: Shape>(_ shape: S) -> some View {
        self
            .foregroundStyle(Theme.hudText.color)
            .tint(Theme.hudText.color)
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Theme.hudScrim.color.opacity(Theme.hudScrimOpacity))
                }
            }
            .environment(\.colorScheme, .dark)
    }

    /// Never smaller than a thumb, and the whole box is tappable.
    public func hudTapTarget() -> some View {
        self
            .frame(minWidth: HUDMetrics.minimumTarget, minHeight: HUDMetrics.minimumTarget)
            .contentShape(Rectangle())
    }
}
#endif
