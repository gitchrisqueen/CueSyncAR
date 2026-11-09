//
//  ContactSheet.swift
//  CueSync AR
//
//  A grid of evenly spaced frames, scaled to a fixed cell width.
//

import CoreGraphics
import Foundation

public enum ContactSheet {
    /// `count` indices spread evenly across 0..<total (all of them if total <= count).
    public static func sampleIndices(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        if total <= count { return Array(0..<total) }
        return (0..<count).map { Int((Double($0) * Double(total - 1) / Double(count - 1)).rounded()) }
    }

    public static func make(images: [CGImage], columns: Int = 4, cellWidth: Int = 480) -> CGImage? {
        guard let first = images.first, columns > 0 else { return nil }
        let cellHeight = Int((Double(cellWidth) * Double(first.height) / Double(first.width)).rounded())
        let rows = (images.count + columns - 1) / columns
        guard let context = CGContext(
            data: nil, width: columns * cellWidth, height: rows * cellHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            // CGContext origin is bottom-left; row 0 goes on top.
            let rect = CGRect(x: column * cellWidth, y: (rows - 1 - row) * cellHeight,
                              width: cellWidth, height: cellHeight)
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }
}
