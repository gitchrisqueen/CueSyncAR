//
//  HUDBarLayout.swift
//  CueSyncUI
//
//  How the bottom bar breaks into rows.
//
//  At accessibility text sizes the bar's labels ("9-ft", "Free play",
//  "Stripes") stopped fitting one row on an iPhone and a 4.7-inch SE, and
//  SwiftUI answered by truncating the widest one to "Free pl...". A control
//  that cannot be read cannot be used, so the bar now wraps instead: it
//  keeps one row whenever everything fits, and otherwise starts a new row
//  rather than shortening any label. Every control keeps its full text and
//  its 44 pt target (HUDBar applies that), VoiceOver is unaffected.
//
//  The row-breaking decision is pure so a test can hold it.
//

import Foundation

public enum HUDBarRows {

    /// Break controls of the given widths into rows, in order, each row as
    /// wide as `available` allows.
    ///
    /// Greedy: a control joins the current row if it fits with `spacing`
    /// between neighbours, else it starts the next row. A control wider than
    /// `available` gets a row of its own (the view lets its text wrap there
    /// rather than cut it). When that takes more than one row the rows are
    /// then evened out, with the same number of rows, so a wrapped bar does
    /// not leave one lone icon on the second row. Returns the index ranges
    /// of the rows.
    public static func rows(widths: [Double], spacing: Double,
                            available: Double) -> [Range<Int>] {
        let greedyRows = greedy(widths: widths, spacing: spacing, available: available)
        guard greedyRows.count > 1, let widest = widths.max(), widest <= available else {
            return greedyRows
        }
        // Narrowest row width that still gives the same number of rows.
        var low = widest
        var high = available
        while high - low > 0.5 {
            let mid = (low + high) / 2
            if greedy(widths: widths, spacing: spacing, available: mid).count == greedyRows.count {
                high = mid
            } else {
                low = mid
            }
        }
        return greedy(widths: widths, spacing: spacing, available: high)
    }

    private static func greedy(widths: [Double], spacing: Double,
                               available: Double) -> [Range<Int>] {
        guard !widths.isEmpty else { return [] }
        var rows: [Range<Int>] = []
        var start = 0
        var used = 0.0
        for (index, width) in widths.enumerated() {
            let needed = index == start ? width : used + spacing + width
            if index > start, needed > available {
                rows.append(start..<index)
                start = index
                used = width
            } else {
                used = needed
            }
        }
        rows.append(start..<widths.count)
        return rows
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// An HStack that wraps. Children are measured at their ideal size; rows
/// are centred, and the whole thing is as wide as its widest row.
struct HUDBarFlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    private func rows(for subviews: Subviews, available: CGFloat) -> [Range<Int>] {
        let widths = subviews.map { Double($0.sizeThatFits(.unspecified).width) }
        return HUDBarRows.rows(widths: widths, spacing: Double(spacing),
                               available: Double(available))
    }

    /// A child's size in a row of `available` width: ideal, except one that
    /// is wider than the row, which is offered the row's width so its text
    /// wraps instead of overflowing.
    private func size(of subview: LayoutSubview, available: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > available else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        let groups = rows(for: subviews, available: available)
        for (rowIndex, range) in groups.enumerated() {
            let sizes = range.map { size(of: subviews[$0], available: available) }
            width = max(width, sizes.reduce(0) { $0 + $1.width }
                        + spacing * CGFloat(max(sizes.count - 1, 0)))
            height += (sizes.map(\.height).max() ?? 0) + (rowIndex > 0 ? rowSpacing : 0)
        }
        return CGSize(width: min(width, available), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let groups = rows(for: subviews, available: bounds.width)
        var y = bounds.minY
        for range in groups {
            let sizes = range.map { size(of: subviews[$0], available: bounds.width) }
            let rowWidth = sizes.reduce(0) { $0 + $1.width }
                + spacing * CGFloat(max(sizes.count - 1, 0))
            let rowHeight = sizes.map(\.height).max() ?? 0
            var x = bounds.midX - rowWidth / 2
            for (offset, index) in range.enumerated() {
                let child = sizes[offset]
                subviews[index].place(at: CGPoint(x: x, y: y + (rowHeight - child.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: child.width,
                                                                 height: child.height))
                x += child.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}
#endif
