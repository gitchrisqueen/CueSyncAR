//
//  BallGroup.swift
//  CoachKit
//
//  Which balls a player is shooting at. Lives here rather than in
//  CueSyncCore because it is a coaching/game concern, not a perception
//  contract — Core stays frozen (playbook rule 4).
//

import CueSyncCore
import Foundation

/// The set of object balls a player is currently entitled to shoot at.
///
/// `solids`/`stripes` are the two halves of an eight-ball rack; `eight` is
/// the end of that game; `any` is open-table play (or a practice session,
/// where every ball is fair game). The group is a *filter over the ranking*
/// — nothing here enforces rules, and nothing prevents the player from
/// tapping a ball outside their group.
public enum BallGroup: String, Sendable, Codable, CaseIterable, Equatable {
    case any
    case solids
    case stripes
    case eight

    /// Whether a ball of `kind` belongs to this group.
    ///
    /// `.unknown` is admitted by every group except `.eight`: until the
    /// appearance classifier can name a ball, refusing to rank it would
    /// hide shots the player can plainly see. The eight is excluded from
    /// `.solids`/`.stripes` because shooting it early loses the game.
    public func includes(_ kind: Ball.Kind) -> Bool {
        if kind == .cue { return false }
        switch self {
        case .any:
            return true
        case .eight:
            return kind == .eight
        case .solids:
            if case .solid = kind { return true }
            return kind == .unknown
        case .stripes:
            if case .stripe = kind { return true }
            return kind == .unknown
        }
    }

    /// The group a ball of `kind` belongs to, or nil for the cue ball and
    /// balls the classifier has not named.
    public static func of(_ kind: Ball.Kind) -> BallGroup? {
        switch kind {
        case .solid: .solids
        case .stripe: .stripes
        case .eight: .eight
        case .cue, .unknown: nil
        }
    }

    /// Short label for the HUD ("Solids", "Stripes", "8-ball", "Open").
    public var label: String {
        switch self {
        case .any: "Open"
        case .solids: "Solids"
        case .stripes: "Stripes"
        case .eight: "8-ball"
        }
    }

    /// The other half of the rack, for a one-tap switch. `any` and `eight`
    /// have no opposite and return themselves.
    public var opposite: BallGroup {
        switch self {
        case .solids: .stripes
        case .stripes: .solids
        case .any, .eight: self
        }
    }
}
