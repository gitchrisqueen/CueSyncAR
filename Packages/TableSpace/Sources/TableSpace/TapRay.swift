//
//  TapRay.swift
//  CueSync AR
//
//  What a corner tap actually is, kept so it can be asked again later.
//
//  A tap is a RAY, not a point. It becomes a point only once you decide
//  which plane it hits — and the height of that plane is the thing this
//  app is least sure about at the moment the tap happens, because the
//  cloth estimate improves for as long as balls are visible.
//
//  Storing the world-space ray rather than the resulting point is what
//  lets a locked calibration be re-derived at a better height later. The
//  screen point alone would not do: it only means something together with
//  the camera pose it was taken from, and by the time a better estimate
//  arrives the device has moved. The ray is already in world space, so it
//  survives the move.
//

import CueSyncCore
import Foundation

/// A tap, in world space, before it was turned into a point.
public struct TapRay: Sendable, Equatable, Codable {
    public var origin: Vec3
    /// Unit direction. Stored normalized so the intersection parameter is a
    /// distance in metres, which makes a sanity check on it meaningful.
    public var direction: Vec3

    public init(origin: Vec3, direction: Vec3) {
        self.origin = origin
        self.direction = direction.length > 1e-9 ? direction.normalized : direction
    }

    /// Where this ray meets a horizontal plane at `planeHeight`.
    ///
    /// Nil when the ray runs parallel to the plane (a grazing sightline
    /// from a device resting on the rail) or when the plane is behind the
    /// camera — in both cases there is no honest answer, and returning a
    /// point anyway is how a corner ends up on the far side of the room.
    public func intersect(planeHeight: Double) -> Vec3? {
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (planeHeight - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }
}
