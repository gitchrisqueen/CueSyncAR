//
//  FarTilePlacement.swift
//  PerceptionKit
//
//  Where to put the far-tile window, from the locked table instead of a fixed
//  rectangle. The playing field is projected into the frame with the frame's
//  own pose and intrinsics; the window covers the part of the table where a
//  ball is narrower than `narrowerThanPixels` (the model's weak range: a
//  ball under about 32 px in the frame is under about 14 px in its 640-wide
//  input), plus one ball of margin so a ball on the edge is whole.
//
//  The window keeps the FRAME'S ASPECT RATIO (`FarTileRegion` is the same
//  fraction of the width and of the height), because
//  `imageCropAndScaleOption = .scaleFill` must keep matching the training
//  data's stretch to 640 x 640 (CLAUDE.md).
//

import CueSyncCore
import Foundation
import TableSpace

public enum FarTilePlacement {
    /// A placed window and what it was placed to cover.
    public struct Plan: Sendable, Equatable {
        public var region: FarTileRegion
        /// Sampled ball positions inside the frame, and how many of them are
        /// narrower than the threshold (the ones the window must cover).
        public var visibleSamples: Int
        public var narrowSamples: Int
        /// Apparent ball width in frame pixels at the farthest and nearest
        /// visible samples.
        public var narrowestPixels: Double
        public var widestPixels: Double
    }

    /// Smallest and largest window, as a fraction of the frame. Below 0.4 the
    /// zoom (2.5x or more) puts a ball outside the size range the model was
    /// trained on; above 0.75 the tile gains too little to pay for itself.
    public static let sizeRange = 0.4...0.75

    /// The window for this frame, or nil when there is nothing for it to do:
    /// no intrinsics, no part of the table in view, or no ball narrower than
    /// `narrowerThanPixels` anywhere in view.
    public static func plan(calibration: TableCalibration,
                            frame: CapturedFrame,
                            narrowerThanPixels: Double = 32) -> Plan? {
        guard let k = frame.intrinsics, k.imageWidth > 0, k.imageHeight > 0 else { return nil }
        // Frame pixels vs the intrinsics' pixel grid (identical for ARKit).
        let scale = (frame.image?.width).map { Double($0) / k.imageWidth } ?? 1
        let transform = frame.cameraTransform
        let radius = Ball.standardRadius
        let lift = calibration.normal * radius
        let (fieldWidth, fieldHeight) = calibration.size.playField
        let halfX = fieldWidth / 2 - radius
        let halfY = fieldHeight / 2 - radius
        guard halfX > 0, halfY > 0 else { return nil }

        var visible = 0
        var narrow: [(x: Double, y: Double, pixels: Double)] = []
        var narrowest = Double.infinity
        var widest = 0.0
        let columns = 13, rows = 7
        for column in 0..<columns {
            for row in 0..<rows {
                let table = Vec2(-halfX + 2 * halfX * Double(column) / Double(columns - 1),
                                 -halfY + 2 * halfY * Double(row) / Double(rows - 1))
                let world = calibration.tableToWorld(table) + lift
                let offset = world - transform.translation
                let depth = -offset.dot(transform.axis(2)) // camera looks along -z
                guard depth > 1e-6 else { continue }
                let x = (k.principalX + k.focalX * offset.dot(transform.axis(0)) / depth) / k.imageWidth
                let y = (k.principalY - k.focalY * offset.dot(transform.axis(1)) / depth) / k.imageHeight
                guard (0...1).contains(x), (0...1).contains(y) else { continue }
                let pixels = k.focalX * scale * 2 * radius / depth
                visible += 1
                narrowest = min(narrowest, pixels)
                widest = max(widest, pixels)
                if pixels < narrowerThanPixels { narrow.append((x, y, pixels)) }
            }
        }
        guard !narrow.isEmpty else { return nil }

        // Bounding box of the narrow samples, grown by one ball diameter.
        let imageWidth = k.imageWidth * scale, imageHeight = k.imageHeight * scale
        let left = narrow.map { $0.x - $0.pixels / imageWidth }.min()!
        let right = narrow.map { $0.x + $0.pixels / imageWidth }.max()!
        let top = narrow.map { $0.y - $0.pixels / imageHeight }.min()!
        let bottom = narrow.map { $0.y + $0.pixels / imageHeight }.max()!
        // One fraction for both axes keeps the frame's aspect ratio.
        let size = min(max(max(right - left, bottom - top), sizeRange.lowerBound), sizeRange.upperBound)
        let originX = min(max((left + right) / 2 - size / 2, 0), 1 - size)
        let originY = min(max((top + bottom) / 2 - size / 2, 0), 1 - size)
        guard let region = FarTileRegion(x: originX, y: originY, size: size) else { return nil }
        return Plan(region: region, visibleSamples: visible, narrowSamples: narrow.count,
                    narrowestPixels: narrowest, widestPixels: widest)
    }
}
