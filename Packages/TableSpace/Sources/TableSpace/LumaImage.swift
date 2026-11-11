//
//  LumaImage.swift
//  TableSpace
//
//  An 8-bit luminance image: the camera's Y plane, copied out of the
//  pixel buffer so the image analysis that refines pocket taps
//  (PocketSnap) is pure and runs on Linux against synthetic images.
//

import CueSyncCore
import Foundation

/// A row-major 8-bit luminance image. Pixel (0, 0) is the top-left.
public struct LumaImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// `width * height` bytes, row-major.
    public let pixels: [UInt8]

    /// Nil when `pixels` does not hold `width * height` bytes.
    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The pixel at integer coordinates, or nil outside the image.
    public func value(_ x: Int, _ y: Int) -> Double? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return Double(pixels[y * width + x])
    }

    /// Bilinear sample at a sub-pixel position (pixel centres at integer
    /// coordinates), or nil when any of the four neighbours is outside.
    public func sample(_ p: Vec2) -> Double? {
        let x0 = Int(p.x.rounded(.down))
        let y0 = Int(p.y.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let fx = p.x - Double(x0)
        let fy = p.y - Double(y0)
        let row0 = y0 * width
        let row1 = row0 + width
        let a = Double(pixels[row0 + x0])
        let b = Double(pixels[row0 + x0 + 1])
        let c = Double(pixels[row1 + x0])
        let d = Double(pixels[row1 + x0 + 1])
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Mean of `count` samples spaced one pixel apart along `along`,
    /// centred on `p`; nil when fewer than half fall inside the image.
    /// Averaging along an edge suppresses the cloth's texture without
    /// blurring across the edge.
    func mean(at p: Vec2, along: Vec2, halfCount: Int = 3) -> Double? {
        var total = 0.0
        var used = 0
        for k in -halfCount...halfCount {
            if let v = sample(p + along * Double(k)) {
                total += v
                used += 1
            }
        }
        guard used * 2 > 2 * halfCount + 1 else { return nil }
        return total / Double(used)
    }
}
