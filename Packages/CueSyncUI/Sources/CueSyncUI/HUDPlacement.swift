//
//  HUDPlacement.swift
//  CueSyncUI
//
//  Where the shot cluster (cue-ball guide and shot card) sits, so it does
//  not cover the table.
//
//  It lives along the bottom edge, which on a parked iPad is exactly where
//  the two near pockets of the table are: seen from the head rail they sit
//  low on the screen at the far left and far right. A card on top of a
//  pocket hides the one thing the player is being asked to look at, so the
//  cluster takes the position (left, middle, right) with no pocket under
//  it. Pure: the app hands in where the pockets are on screen.
//

import CueSyncCore
import Foundation

public enum HUDPlacement {

    /// Where along the bottom edge the cluster sits.
    public enum Side: Sendable, Equatable, CaseIterable {
        case leading
        case center
        case trailing
    }

    /// The side to put the cluster on.
    ///
    /// Stays on `preferred` when no pocket is under it. Otherwise takes the
    /// first position, in the order centre, other edge, that has none; when
    /// every position covers a pocket it stays where it is rather than
    /// hopping about, because a card that jumps is worse than one that
    /// overlaps.
    ///
    /// - Parameters:
    ///   - pockets: pocket positions in screen points, y down.
    ///   - viewport: the screen size in points.
    ///   - widthFraction: how much of the screen width the cluster covers.
    ///   - heightFraction: how much of the screen height, from the bottom
    ///     (the control bar is inside this).
    public static func clusterSide(pockets: [Vec2], viewport: Vec2,
                                   preferred: Side = .leading,
                                   widthFraction: Double = 0.5,
                                   heightFraction: Double = 0.4) -> Side {
        guard viewport.x > 0, viewport.y > 0 else { return preferred }
        let top = viewport.y * (1 - heightFraction)
        let low = pockets.filter { $0.y >= top }

        func covered(_ side: Side) -> Int {
            let span = viewport.x * widthFraction
            let range: ClosedRange<Double> = switch side {
            case .leading: 0...span
            case .center: ((viewport.x - span) / 2)...((viewport.x + span) / 2)
            case .trailing: (viewport.x - span)...viewport.x
            }
            return low.filter { range.contains($0.x) }.count
        }

        guard covered(preferred) > 0 else { return preferred }
        let order: [Side] = [.center, .leading, .trailing].filter { $0 != preferred }
        return order.first { covered($0) == 0 } ?? preferred
    }
}
