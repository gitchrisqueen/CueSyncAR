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
///
/// The sizes are set for the way the iPad is used: parked on a tripod and
/// read from 1.5 to 3 m. A review measured the old 29 pt headline at 5.3
/// arcminutes from 2 m, at the floor of what an eye resolves, so every
/// regular-width size below is chosen to be read at a glance from there.
public enum HUDTextRole: CaseIterable, Sendable {
    /// The shot call: "BLUE → RIGHT SIDE".
    case headline
    /// The tier word in its chip: "EASY".
    case tier
    /// The status capsule, the bar buttons, the card's one-line labels.
    case body
    /// Quiet secondary lines: the bar's state line, hints.
    case caption
    /// "MADE IT": a made shot takes the card's slot for a moment.
    case payoff
    /// A miss or a scratch in the same slot, and the second line of a make.
    case payoffDetail

    /// Point size on a compact-width screen (a phone) at the default
    /// Dynamic Type size. Never below 17 pt: a phone is held, but it is
    /// held at arm's length over a table, not at reading distance.
    public var compactSize: Double {
        switch self {
        case .headline: 20
        case .tier: 18
        case .body: 17
        case .caption: 17
        case .payoff: 30
        case .payoffDetail: 22
        }
    }

    /// Point size on a regular-width screen (an iPad) at the default
    /// Dynamic Type size. The independent re-score measured 22 pt text at a
    /// 31 px cap height, one pixel under the 32 px floor, at 2 m. 28 pt is
    /// a cap of about 39 px: headline 36, tier chip 32, every other
    /// persistent string 28, a made shot 48 and a miss 34.
    public var regularSize: Double {
        switch self {
        case .headline: 36
        case .tier: 32
        case .body: 28
        case .caption: 28
        case .payoff: 48
        case .payoffDetail: 34
        }
    }

    /// The compact size, kept under its old name.
    public var baseSize: Double { compactSize }

    public func size(regularWidth: Bool) -> Double {
        regularWidth ? regularSize : compactSize
    }
}

public enum HUDMetrics {
    /// Smallest tappable height and width, in points (Apple's minimum).
    public static let minimumTarget = 44.0
    /// Space between two bar controls, so a fat thumb hits one of them.
    public static let barSpacing = 12.0
    /// Widest the shot card gets. The card is always this wide where the
    /// screen allows and the screen's width less the gutters where it does
    /// not, so it never changes size from one shot to the next.
    public static let cardWidthCompact = 420.0
    /// 780, not wider: on the 1080 pt iPad in use a 1000 pt card was a
    /// slab across 93 % of the screen (real-device still, 2026-11-12). 780
    /// still holds a typical 25-character headline on one line beside the
    /// guide tile (`HUDReadabilityTests.cardWidth`); longer calls wrap.
    public static let cardWidthRegular = 780.0
    /// Corner radius of a HUD plate.
    public static let cornerRadius = 16.0
}

#if canImport(SwiftUI)
import SwiftUI

private struct HUDFontModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric private var compact: CGFloat
    @ScaledMetric private var regular: CGFloat
    private let weight: Font.Weight

    init(_ role: HUDTextRole, weight: Font.Weight) {
        // `relativeTo` picks the Dynamic Type curve the size follows.
        let style: Font.TextStyle = switch role {
        case .headline: .title3
        case .tier: .headline
        case .body: .callout
        case .caption: .footnote
        case .payoff: .largeTitle
        case .payoffDetail: .title2
        }
        _compact = ScaledMetric(wrappedValue: CGFloat(role.compactSize), relativeTo: style)
        _regular = ScaledMetric(wrappedValue: CGFloat(role.regularSize), relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: sizeClass == .regular ? regular : compact, weight: weight))
    }
}

/// A status icon in a box of fixed size, so no glyph can change the height
/// of the line it sits in.
///
/// The called-shot capsule's crosshair is taller than the tick it replaces,
/// which made the capsule 11 px taller and pushed the shot card down 9 px
/// every time the aim crossed the line: a flicker, at exactly the moment the
/// player is fine-tuning the cue. Every glyph now gets the same box.
public struct HUDIcon: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric private var compact: CGFloat
    @ScaledMetric private var regular: CGFloat
    private let name: String
    private let weight: Font.Weight

    public init(_ systemName: String, role: HUDTextRole = .body, weight: Font.Weight = .regular) {
        name = systemName
        self.weight = weight
        _compact = ScaledMetric(wrappedValue: CGFloat(role.compactSize), relativeTo: .callout)
        _regular = ScaledMetric(wrappedValue: CGFloat(role.regularSize), relativeTo: .callout)
    }

    /// The box is a little taller than a line of the same text, so the icon
    /// (not the glyph) sets the line's height, and it is always the same.
    public static let boxFactor: CGFloat = 1.25

    public var body: some View {
        let size = sizeClass == .regular ? regular : compact
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .frame(width: size * Self.boxFactor, height: size * Self.boxFactor)
    }
}

private struct HUDCardWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Fills the width it is offered up to the card width, so the card is
    /// the same width in every state.
    func body(content: Content) -> some View {
        content.frame(maxWidth: sizeClass == .regular ? HUDMetrics.cardWidthRegular
                                                      : HUDMetrics.cardWidthCompact)
    }
}

extension View {
    /// A card's widest extent: wider on an iPad, where the text is bigger.
    /// Pair with `frame(maxWidth: .infinity)` inside to fill it.
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
