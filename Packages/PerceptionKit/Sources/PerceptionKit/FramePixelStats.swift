//
//  FramePixelStats.swift
//  PerceptionKit
//
//  The two coarse reads the pipeline takes off every frame's pixels: a
//  fingerprint for the unchanged-frame gate and a mean brightness. Both use
//  a sparse 24 x 24 grid. Moved out of `PerceptionPipeline` unchanged so
//  that file stays inside the lint ceiling.
//

import CueSyncCore
import Foundation
import TableSpace

enum FramePixelStats {
    private static let steps = 24

    /// A coarse fingerprint of the frame for `FrameChangeGate`. Nil when
    /// the pixels cannot be read, which the gate treats as "process it".
    static func signature(of frame: CapturedFrame, enabled: Bool) -> FrameSignature? {
        #if canImport(CoreVideo)
        guard enabled else { return nil }
        guard let image = frame.image as? PixelBufferImage else { return nil }
        return image.withReader { reader -> FrameSignature? in
            guard reader.pixelWidth > steps, reader.pixelHeight > steps else { return nil }
            let dx = reader.pixelWidth / steps
            let dy = reader.pixelHeight / steps
            var cells: [Double] = []
            cells.reserveCapacity(steps * steps)
            for row in 0..<steps {
                for column in 0..<steps {
                    guard let rgb = reader.rgb(x: column * dx, y: row * dy) else { return nil }
                    cells.append(0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z)
                }
            }
            return FrameSignature(cells: cells)
        } ?? nil
        #else
        return nil
        #endif
    }

    /// Mean brightness of a frame, from a sparse grid.
    ///
    /// A grid rather than every pixel: this runs on the pipeline actor
    /// once a frame, and a few hundred samples give the mean to well
    /// inside the precision anyone needs to answer "is this room dark".
    /// Measured on the owner's table, afternoon against dusk: 0.528 and
    /// 0.399 over the whole frame.
    static func luminance(of frame: CapturedFrame) -> Double? {
        #if canImport(CoreVideo)
        guard let image = frame.image as? PixelBufferImage else { return nil }
        return image.withReader { reader -> Double? in
            guard reader.pixelWidth > steps, reader.pixelHeight > steps else { return nil }
            let dx = reader.pixelWidth / steps
            let dy = reader.pixelHeight / steps
            var total = 0.0
            var count = 0
            for row in 0..<steps {
                for column in 0..<steps {
                    guard let rgb = reader.rgb(x: column * dx, y: row * dy) else { continue }
                    // Rec. 601 luma, matching the buffers this reads.
                    total += 0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : nil
        } ?? nil
        #else
        return nil
        #endif
    }
}
