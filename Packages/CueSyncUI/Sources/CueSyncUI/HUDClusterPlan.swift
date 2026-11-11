//
//  HUDClusterPlan.swift
//  CueSyncUI
//
//  Where the shot cluster (cue-ball guide and shot card) goes, given where
//  the TABLE is on the screen.
//
//  `HUDPlacement.clusterSide` only dodges the pockets along the bottom edge.
//  On a tripod that is not enough: the table fills the lower middle of the
//  screen, and an ~800 x 230 px card at the bottom centre still sits on the
//  near cloth (measured on the iPad, 2160 x 1620). So the plan works from the
//  table's projected quad: it walks a fixed list of places in order of
//  preference (bottom edge, the band under the status capsule, a side
//  column) and takes the first whose rectangle does not touch the table. If
//  the panel fits nowhere it shrinks to the one-line pill and tries the same
//  places again; if even the pill touches cloth everywhere it still draws
//  the pill (never hides) where the card has always been.
//
//  Pure: the app hands in projected points and the sizes it expects to
//  draw. Nothing here knows about SwiftUI.
//

import CueSyncCore
import Foundation

/// An axis-aligned rectangle in screen points, y down.
public struct HUDRect: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midX: Double { minX + width / 2 }
    public var midY: Double { minY + height / 2 }

    /// The same rectangle grown by `amount` on every side.
    public func inflated(by amount: Double) -> HUDRect {
        HUDRect(minX: minX - amount, minY: minY - amount,
                width: width + 2 * amount, height: height + 2 * amount)
    }
}

/// How much of the cluster is shown.
public enum HUDClusterStyle: Sendable, Equatable {
    /// Guide beside a three-line card, in a wide strip.
    case wide
    /// The same two pieces stacked in a narrow side column.
    case column
    /// One line: tier word and "Blue ball → right side pocket".
    case pill
}

/// A place on the screen the cluster can sit.
public enum HUDClusterAnchor: Sendable, Equatable, CaseIterable {
    case bottomLeading
    case bottomCenter
    case bottomTrailing
    /// Centred, under the status capsule.
    case topCenter
    /// Against the leading edge, bottom-aligned above the control bar.
    case leadingColumn
    case trailingColumn
}

/// What the plan decided.
public struct HUDClusterPlan: Sendable, Equatable {
    public var style: HUDClusterStyle
    public var anchor: HUDClusterAnchor
    /// The rectangle the cluster is expected to take, in screen points.
    public var frame: HUDRect
    /// True when `frame` is known to be clear of the table (or no table is
    /// known yet); false when every place covered cloth and this is the
    /// pill in its default spot.
    public var clearOfTable: Bool
}

/// The sizes the app expects each style to draw at, in points.
public struct HUDClusterSizes: Sendable, Equatable {
    public var wide: Vec2
    public var column: Vec2
    public var pill: Vec2

    public init(wide: Vec2, column: Vec2, pill: Vec2) {
        self.wide = wide
        self.column = column
        self.pill = pill
    }
}

/// What is already spoken for around the edges, in points.
public struct HUDClusterInsets: Sendable, Equatable {
    /// From the top edge down: safe area, status capsule, one toast.
    public var top: Double
    /// From the bottom edge up: safe area and the control bar.
    public var bottom: Double
    /// From the left and right edges.
    public var side: Double

    public init(top: Double, bottom: Double, side: Double) {
        self.top = top
        self.bottom = bottom
        self.side = side
    }
}

extension HUDPlacement {

    /// Screens smaller than this get the pill only: a phone, in either
    /// orientation, has no room for a panel that is not on the table.
    public static let panelMinimumWidth = 600.0
    public static let panelMinimumHeight = 500.0

    /// Pick where the cluster goes.
    ///
    /// - Parameters:
    ///   - tableQuad: the table (rails included) projected to the screen,
    ///     in points. Fewer than three points means the table is not known
    ///     (not calibrated, or behind the camera): the default applies.
    ///   - pockets: projected pocket centres, used for the default only.
    ///   - viewport: the screen size in points.
    ///   - sizes: how big each style draws.
    ///   - insets: edges already in use.
    ///   - preferred: the bottom position taken when nothing else matters.
    ///   - previous: the last plan; kept while it is still clear, so a card
    ///     does not hop about as the camera sways.
    ///   - gap: clearance to keep between the cluster and the cloth.
    public static func clusterPlan(tableQuad: [Vec2], pockets: [Vec2] = [], viewport: Vec2,
                                   sizes: HUDClusterSizes, insets: HUDClusterInsets,
                                   preferred: Side = .leading,
                                   previous: HUDClusterPlan? = nil,
                                   gap: Double = 12) -> HUDClusterPlan {
        let panelAllowed = viewport.x >= panelMinimumWidth && viewport.y >= panelMinimumHeight
        let hull = convexHull(tableQuad)
        let tableKnown = hull.count >= 3

        func frame(_ anchor: HUDClusterAnchor, _ size: Vec2) -> HUDRect {
            let bottomY = viewport.y - insets.bottom - size.y
            switch anchor {
            case .bottomLeading:
                return HUDRect(minX: insets.side, minY: bottomY, width: size.x, height: size.y)
            case .bottomCenter:
                return HUDRect(minX: (viewport.x - size.x) / 2, minY: bottomY,
                               width: size.x, height: size.y)
            case .bottomTrailing:
                return HUDRect(minX: viewport.x - insets.side - size.x, minY: bottomY,
                               width: size.x, height: size.y)
            case .topCenter:
                return HUDRect(minX: (viewport.x - size.x) / 2, minY: insets.top,
                               width: size.x, height: size.y)
            case .leadingColumn:
                return HUDRect(minX: insets.side, minY: bottomY, width: size.x, height: size.y)
            case .trailingColumn:
                return HUDRect(minX: viewport.x - insets.side - size.x, minY: bottomY,
                               width: size.x, height: size.y)
            }
        }

        func fits(_ rect: HUDRect) -> Bool {
            rect.minX >= 0 && rect.minY >= insets.top - 0.5
                && rect.maxX <= viewport.x && rect.maxY <= viewport.y
        }

        func isClear(_ rect: HUDRect) -> Bool {
            !tableKnown || !intersects(rect.inflated(by: gap), hull: hull)
        }

        let bottoms = bottomOrder(preferred)
        var candidates: [(HUDClusterStyle, HUDClusterAnchor)] = []
        if panelAllowed {
            candidates += bottoms.map { (.wide, $0) }
            candidates.append((.wide, .topCenter))
            candidates += [(.column, .leadingColumn), (.column, .trailingColumn)]
        }
        candidates += bottoms.map { (.pill, $0) }
        candidates.append((.pill, .topCenter))

        func size(_ style: HUDClusterStyle) -> Vec2 {
            switch style {
            case .wide: sizes.wide
            case .column: sizes.column
            case .pill: sizes.pill
            }
        }
        let placed: [HUDClusterPlan] = candidates.compactMap { style, anchor in
            let rect = frame(anchor, size(style))
            guard fits(rect) else { return nil }
            return HUDClusterPlan(style: style, anchor: anchor, frame: rect,
                                  clearOfTable: isClear(rect))
        }

        // No table on screen: nothing to avoid, so keep the old behaviour
        // (the pocket dodge along the bottom edge) with the style the
        // screen allows.
        if !tableKnown {
            let style: HUDClusterStyle = panelAllowed ? .wide : .pill
            let side = clusterSide(pockets: pockets, viewport: viewport, preferred: preferred,
                                   widthFraction: min(0.9, size(style).x / max(viewport.x, 1)),
                                   heightFraction: min(0.6, (size(style).y + insets.bottom)
                                                       / max(viewport.y, 1)))
            let anchor = anchor(for: side)
            return HUDClusterPlan(style: style, anchor: anchor,
                                  frame: frame(anchor, size(style)), clearOfTable: true)
        }

        // Keep last time's choice while it is still clear.
        if let previous,
           let kept = placed.first(where: { $0.style == previous.style
                                            && $0.anchor == previous.anchor && $0.clearOfTable }) {
            return kept
        }
        if let clear = placed.first(where: { $0.clearOfTable }) { return clear }

        // Cloth everywhere: the pill where the card used to be, readable
        // and never hidden.
        let anchor = anchor(for: preferred)
        return HUDClusterPlan(style: .pill, anchor: anchor,
                              frame: frame(anchor, sizes.pill), clearOfTable: false)
    }

    private static func bottomOrder(_ preferred: Side) -> [HUDClusterAnchor] {
        let first = anchor(for: preferred)
        let rest: [HUDClusterAnchor] = [.bottomCenter, .bottomLeading, .bottomTrailing]
        return [first] + rest.filter { $0 != first }
    }

    private static func anchor(for side: Side) -> HUDClusterAnchor {
        switch side {
        case .leading: .bottomLeading
        case .center: .bottomCenter
        case .trailing: .bottomTrailing
        }
    }

    // MARK: - Geometry

    /// Convex hull (Andrew's monotone chain), so a quad given in any order,
    /// or with a stray point, still tests as the solid it covers.
    static func convexHull(_ points: [Vec2]) -> [Vec2] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [Vec2] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Vec2] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Whether `rect` and the convex polygon `hull` overlap (separating
    /// axis test; touching edges do not count).
    static func intersects(_ rect: HUDRect, hull: [Vec2]) -> Bool {
        guard hull.count >= 3 else { return false }
        // Axes of the rectangle.
        if hull.map(\.x).max()! <= rect.minX || hull.map(\.x).min()! >= rect.maxX { return false }
        if hull.map(\.y).max()! <= rect.minY || hull.map(\.y).min()! >= rect.maxY { return false }
        // Axes of the polygon's edges.
        let corners = [Vec2(rect.minX, rect.minY), Vec2(rect.maxX, rect.minY),
                       Vec2(rect.maxX, rect.maxY), Vec2(rect.minX, rect.maxY)]
        for i in hull.indices {
            let a = hull[i]
            let b = hull[(i + 1) % hull.count]
            let normal = Vec2(b.y - a.y, a.x - b.x)
            func project(_ p: Vec2) -> Double { p.x * normal.x + p.y * normal.y }
            let polygon = hull.map(project)
            let box = corners.map(project)
            if polygon.max()! <= box.min()! || box.max()! <= polygon.min()! { return false }
        }
        return true
    }
}
