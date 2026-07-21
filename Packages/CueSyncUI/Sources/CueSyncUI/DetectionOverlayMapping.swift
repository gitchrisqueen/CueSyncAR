//
//  DetectionOverlayMapping.swift
//  CueSyncUI
//
//  Maps detector bounding boxes (normalized, in raw camera-image space) onto
//  a view that displays the camera aspect-filled — the math behind the
//  Detection Preview debug overlay. The camera sensor image is rotated
//  relative to the UI (ARKit delivers landscape buffers in portrait UI), so
//  a rotation step precedes the aspect-fill mapping. The correct rotation is
//  confirmed on-device; the preview UI can cycle it live.
//

import CueSyncCore
import Foundation

/// Quarter-turn rotations applied to normalized image coordinates
/// (top-left origin) to bring them into view orientation.
public enum NormalizedRotation: Int, Sendable, CaseIterable, Codable {
    case none = 0
    case clockwise90 = 90
    case half = 180
    case counterClockwise90 = 270

    public var next: NormalizedRotation {
        switch self {
        case .none: .clockwise90
        case .clockwise90: .half
        case .half: .counterClockwise90
        case .counterClockwise90: .none
        }
    }

    /// Rotate a normalized rect within the unit square.
    public func apply(_ r: NormalizedRect) -> NormalizedRect {
        switch self {
        case .none:
            r
        case .clockwise90:
            // (u,v) → (1-v, u); size swaps.
            NormalizedRect(x: 1 - r.y - r.height, y: r.x,
                           width: r.height, height: r.width)
        case .half:
            NormalizedRect(x: 1 - r.x - r.width, y: 1 - r.y - r.height,
                           width: r.width, height: r.height)
        case .counterClockwise90:
            // (u,v) → (v, 1-u); size swaps.
            NormalizedRect(x: r.y, y: 1 - r.x - r.width,
                           width: r.height, height: r.width)
        }
    }

    /// Whether this rotation swaps the image's width and height.
    public var swapsDimensions: Bool {
        self == .clockwise90 || self == .counterClockwise90
    }

    /// Compose two quarter-turn rotations (angles add mod 360). Lets an
    /// automatic orientation-derived rotation carry a user trim on top.
    public func combined(with other: NormalizedRotation) -> NormalizedRotation {
        NormalizedRotation(rawValue: (rawValue + other.rawValue) % 360) ?? .none
    }
}

public enum AspectFillMapping {
    /// Map a normalized rect (already in view orientation, relative to an
    /// image of `imageWidth`×`imageHeight`) onto a view of
    /// `viewWidth`×`viewHeight` displayed aspect-FILL (centered crop).
    /// Returns view-space (x, y, width, height) in points.
    public static func mapRect(_ r: NormalizedRect,
                               imageWidth: Double, imageHeight: Double,
                               viewWidth: Double, viewHeight: Double)
    -> (x: Double, y: Double, width: Double, height: Double) {
        guard imageWidth > 0, imageHeight > 0, viewWidth > 0, viewHeight > 0 else {
            return (0, 0, 0, 0)
        }
        let scale = Swift.max(viewWidth / imageWidth, viewHeight / imageHeight)
        let scaledW = imageWidth * scale
        let scaledH = imageHeight * scale
        let offsetX = (viewWidth - scaledW) / 2
        let offsetY = (viewHeight - scaledH) / 2
        return (x: offsetX + r.x * scaledW,
                y: offsetY + r.y * scaledH,
                width: r.width * scaledW,
                height: r.height * scaledH)
    }
}
