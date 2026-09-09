//
//  TrackingCondition.swift
//  CueSyncUI
//
//  What ARKit's camera tracking is doing, in a form with no ARKit in it.
//
//  `HUDStatus.degraded` shipped with good copy — "Need more light",
//  "Hold steady…" — and for months nothing could produce it, because the
//  only thing that knew tracking was in trouble published a string built
//  with `String(describing: reason)`. So a player in a dim room read
//  "Tracking limited: insufficientFeatures": an enum name, in an orange
//  capsule, about a problem they could have fixed by turning on a lamp.
//
//  The translation is a small total function over a closed set of states,
//  which is exactly the kind of thing that should be decided once and
//  tested on Linux rather than written inline in an ARKit delegate that
//  can only run on a device.
//

import Foundation

/// The tracking states ARKit can report, named after their causes rather
/// than their symptoms.
///
/// One case per `ARCamera.TrackingState`, flattened: `.normal`,
/// `.notAvailable`, and the four `.limited(reason:)` cases. The ARKit
/// switch that produces one of these is the only part of this that cannot
/// be tested off a device, and it is four lines long.
public enum TrackingCondition: String, Sendable, Equatable, CaseIterable {
    /// Tracking is fine.
    case normal
    /// ARKit is still finding its feet. Not a fault, and not worth
    /// interrupting the player over: the launch and find-the-table copy
    /// already covers this moment.
    case initializing
    /// Matching against a saved world map (a remembered table).
    case relocalizing
    /// The device is moving too fast for the camera to track.
    case excessiveMotion
    /// Too little visual detail to track — nearly always too little light.
    case insufficientFeatures
    /// Tracking is not running at all.
    case unavailable

    /// What the status capsule should say, or nil when there is nothing
    /// the player needs to be told.
    ///
    /// `.initializing` maps to nil deliberately: it happens on every cold
    /// start, it resolves itself in a second or two, and a warning about
    /// it would be the first thing every player ever saw.
    public var degradedReason: HUDStatus.DegradedReason? {
        switch self {
        case .normal, .initializing: nil
        case .excessiveMotion: .fastMotion
        case .insufficientFeatures: .lowLight
        case .relocalizing, .unavailable: .trackingLost
        }
    }

    /// True while ARKit's world tracking cannot be relied on — the states
    /// where a hit-test returns nothing, so a tap cannot land.
    public var blocksRaycasts: Bool {
        degradedReason != nil
    }

    /// One line for the log and the debug mirror — never for the player.
    ///
    /// Written out in words rather than interpolating a case name, so that
    /// a developer reading a mirror at the table gets the same sentence
    /// whatever ARKit calls the reason internally.
    public var diagnostic: String? {
        switch self {
        case .normal: nil
        case .initializing: "Tracking limited: still initializing"
        case .relocalizing: "Tracking limited: relocalizing against the saved table"
        case .excessiveMotion: "Tracking limited: device moving too fast"
        case .insufficientFeatures: "Tracking limited: not enough visual detail"
        case .unavailable: "Tracking unavailable: the session is not tracking"
        }
    }

    /// Why a tap found nothing, in terms of what to do about it.
    ///
    /// While tracking is degraded ARKit returns nothing from a hit-test at
    /// all, so a corner tap cannot succeed no matter where it lands.
    /// Saying which of those seconds this is, is the difference between
    /// "this app ignores me" and "hold still for a second".
    public var missedTapAdvice: String {
        switch degradedReason {
        case .fastMotion: "Hold the device still, then tap the corner again"
        case .lowLight: "Too dark to place a corner — more light on the table"
        case .trackingLost: "Finding the table again — tap the corner in a moment"
        case nil: "Aim at the cloth inside the cushions, then tap the corner"
        }
    }
}
