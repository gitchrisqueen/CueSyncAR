//
//  FarTile.swift
//  PerceptionKit
//
//  Pure geometry for the far-tile detection pass: far-row balls are only
//  ~21-26 px wide in the camera frame, ~9-12 px after the stretch to the
//  model's 640 x 640 input. A zoomed crop of the table, run through the same
//  model, hands those balls 2x or more of the model's resolution.
//
//  Three pieces, all platform-independent so Linux CI covers them:
//    - FarTileRegion / FarTilePixelCrop: which part of the frame, and the
//      mapping of a tile-space box back to full-frame space.
//    - FarTileMerge: drop edge-clipped and stick boxes from the tile, then
//      fold the rest into the full-frame result (one box per ball).
//    - FarTileSchedule: run the tile every Nth frame only.
//
//  The tile keeps the FULL FRAME'S ASPECT RATIO (width and height are the
//  same fraction of the frame). The model was trained on frames stretched to
//  640 x 640 (`imageCropAndScaleOption = .scaleFill`, see CLAUDE.md), so a
//  tile with another aspect ratio would be distorted differently and would
//  not match the training data.
//

import CueSyncCore
import Foundation

/// A square-in-fraction window onto the frame. `size` is the fraction of the
/// frame width AND of the frame height, so the crop has the frame's aspect.
public struct FarTileRegion: Sendable, Equatable {
    /// Top-left corner, fraction of frame width / height (top-left origin).
    public let x: Double
    public let y: Double
    /// Fraction of frame width and of frame height.
    public let size: Double

    /// Centre-weighted default: x 0.25...0.75, y 0.20...0.70 of the frame.
    /// Covers the whole table on a parked-camera framing and doubles the
    /// scale the model sees. Measured in the 2026-11-12 grid capture; other
    /// framings may want another window.
    public static let `default` = FarTileRegion(x: 0.25, y: 0.20, size: 0.5)!

    /// nil unless the window lies inside the frame and is at least 10 % of it.
    public init?(x: Double, y: Double, size: Double) {
        guard size >= 0.1, size <= 1, x >= 0, y >= 0,
              x + size <= 1 + 1e-9, y + size <= 1 + 1e-9 else { return nil }
        self.x = x
        self.y = y
        self.size = size
    }

    /// The integer pixel window for a frame of this size. Origin and size are
    /// even (required by 4:2:0 chroma planes). The window has the frame's
    /// aspect ratio EXACTLY whenever the frame's reduced ratio allows it
    /// (1440 x 1080 is 4:3, so widths in steps of 8 px: 720 x 540, 576 x 432),
    /// otherwise to within one pixel pair.
    public func pixelCrop(frameWidth: Int, frameHeight: Int) -> FarTilePixelCrop? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        let wanted = size * Double(frameWidth)
        var width = min(even(wanted), frameWidth / 2 * 2)
        var height = min(even(Double(width) * Double(frameHeight) / Double(frameWidth)),
                         frameHeight / 2 * 2)
        // Exact aspect: the smallest even-sided window with the frame's
        // reduced ratio, then the nearest multiple of it.
        let divisor = Self.gcd(frameWidth, frameHeight)
        var unitWidth = frameWidth / divisor, unitHeight = frameHeight / divisor
        if unitWidth % 2 != 0 || unitHeight % 2 != 0 { unitWidth *= 2; unitHeight *= 2 }
        if Double(unitWidth) <= wanted {
            let steps = max(1, Int((wanted / Double(unitWidth)).rounded()))
            let exactWidth = steps * unitWidth, exactHeight = steps * unitHeight
            if exactWidth <= frameWidth, exactHeight <= frameHeight {
                width = exactWidth
                height = exactHeight
            }
        }
        let originX = min(Int((x * Double(frameWidth) / 2).rounded()) * 2, frameWidth - width)
        let originY = min(Int((y * Double(frameHeight) / 2).rounded()) * 2, frameHeight - height)
        guard width >= 2, height >= 2 else { return nil }
        return FarTilePixelCrop(x: max(0, originX / 2 * 2), y: max(0, originY / 2 * 2),
                                width: width, height: height,
                                frameWidth: frameWidth, frameHeight: frameHeight)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

/// An exact integer crop of a frame, and the tile-to-frame mapping for it.
public struct FarTilePixelCrop: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let frameWidth: Int
    public let frameHeight: Int

    /// Full-frame normalized box (top-left origin) of a box given in the
    /// tile's own normalized space (top-left origin).
    public func frameBox(fromTileBox box: NormalizedRect) -> NormalizedRect {
        let fw = Double(frameWidth), fh = Double(frameHeight)
        return NormalizedRect(x: (Double(x) + box.x * Double(width)) / fw,
                              y: (Double(y) + box.y * Double(height)) / fh,
                              width: box.width * Double(width) / fw,
                              height: box.height * Double(height) / fh)
    }
}

/// Folds tile detections into a full-frame result.
public enum FarTileMerge {
    /// Boxes whose edge lies within this fraction of the tile edge are
    /// clipped by the crop (a ball cut in half is not a ball); the full
    /// frame sees those balls whole.
    public static let edgeMargin = 0.01
    /// Intersection over the SMALLER box at or above which two boxes are the
    /// same ball. The tile box is tighter at higher resolution, so plain IoU
    /// would under-match a ball seen at two scales.
    public static let sameBallOverlap = 0.5

    /// Tile detections, mapped into full-frame space. Drops stick boxes (a
    /// stick is much larger than the tile can show) and boxes clipped by the
    /// tile edge.
    public static func frameDetections(fromTile tile: [Detection2D],
                                       crop: FarTilePixelCrop) -> [Detection2D] {
        tile.compactMap { detection in
            guard !detection.isCueStick else { return nil }
            let box = detection.boundingBox
            let m = edgeMargin
            guard box.x > m, box.y > m,
                  box.x + box.width < 1 - m, box.y + box.height < 1 - m else { return nil }
            return Detection2D(classLabel: detection.classLabel,
                               boundingBox: crop.frameBox(fromTileBox: box),
                               confidence: detection.confidence)
        }
    }

    /// Full-frame boxes at or above this confidence are trusted as they are.
    /// Equal to the pipeline's default confidence floor
    /// (`PerceptionConfig.confidenceFloor`): below it the pipeline discards a
    /// box anyway, so nothing is lost by replacing it.
    public static let trustedConfidence = 0.35

    /// `full` plus whatever `tile` (already in frame space) adds.
    ///
    /// A trusted full-frame box is NEVER moved or replaced: measured on a
    /// parked-camera capture, a zoomed box on a large near ball can sit a
    /// dozen pixels off the full-frame one, and swapping it in would shift the
    /// ball's table position. So, for a tile box that overlaps a full-frame box:
    ///   - the full-frame box is trusted (>= `trustedConfidence`): the tile box
    ///     is dropped, one box per ball;
    ///   - the full-frame box is below that: the pipeline would discard it, so
    ///     a more confident tile box takes its place (this is what lifts a
    ///     borderline cue ball and a missed far ball over the floor). It also
    ///     means sub-floor junk the model emits at a lowered confidence
    ///     threshold cannot swallow a real tile detection.
    /// A tile box overlapping nothing is added. Two tile boxes on one ball add
    /// it once. Full-frame stick boxes never match (they are huge and would
    /// swallow a ball). With an empty `tile` the result equals `full` exactly,
    /// in order.
    public static func merge(full: [Detection2D], tile: [Detection2D]) -> [Detection2D] {
        var result = full
        for candidate in tile.sorted(by: { $0.confidence > $1.confidence }) {
            var best: (index: Int, overlap: Double)?
            for (index, existing) in result.enumerated() where !existing.isCueStick {
                let overlap = overlapOverSmaller(existing.boundingBox, candidate.boundingBox)
                if overlap >= sameBallOverlap, overlap > (best?.overlap ?? 0) {
                    best = (index, overlap)
                }
            }
            if let best {
                let existing = result[best.index]
                if existing.confidence < trustedConfidence, candidate.confidence > existing.confidence {
                    result[best.index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    /// Intersection area divided by the smaller box's area; 0 when disjoint.
    public static func overlapOverSmaller(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        guard smaller > 0 else { return 0 }
        return width * height / smaller
    }
}

/// Runs the tile on every `period`-th frame (frames 0, period, 2 * period...);
/// period 1 is every frame.
public struct FarTileSchedule: Sendable, Equatable {
    public private(set) var period: Int
    public private(set) var frameIndex = 0

    /// `period` below 1 is treated as 1 (every frame).
    public init(period: Int) {
        self.period = max(1, period)
    }

    /// Change the period without disturbing the frame count.
    public mutating func setPeriod(_ period: Int) {
        self.period = max(1, period)
    }

    /// Whether this frame gets a tile pass. The counter advances on every
    /// call, enabled or not, so toggling never shifts the rhythm.
    public mutating func advance(enabled: Bool) -> Bool {
        defer { frameIndex += 1 }
        return enabled && frameIndex % period == 0
    }
}

/// Picks the tile period from MEASURED pass times so the average detect time
/// stays inside a budget.
///
/// The average per frame is `full + tile / period`, so the smallest period
/// that meets `budget` is `ceil(tile / (budget - full))`. On the iPad the
/// full pass is about 27 ms and the tile pass about 57 ms: a 45 ms budget
/// gives period 4 (27 + 14 = 41 ms), where period 1 gives 84 ms. Measuring
/// rather than hard-coding means a faster device (or a cheaper tile) gets
/// more tile passes for the same budget.
public struct FarTileBudget: Sendable, Equatable {
    public let budgetMilliseconds: Double
    public let maxPeriod: Int
    /// Samples ignored before averaging: the first inferences include model
    /// specialization (seconds) and would swamp the average.
    public static let warmupSamples = 2
    /// Smoothing of the running averages (weight of the newest sample).
    public static let smoothing = 0.2
    /// Period used until both passes have been measured.
    public static let startingPeriod = 2

    public private(set) var fullMilliseconds: Double?
    public private(set) var tileMilliseconds: Double?
    private var fullSeen = 0
    private var tileSeen = 0

    public init(budgetMilliseconds: Double = 45, maxPeriod: Int = 8) {
        self.budgetMilliseconds = max(1, budgetMilliseconds)
        self.maxPeriod = max(1, maxPeriod)
    }

    public mutating func noteFullPass(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        fullSeen += 1
        if fullSeen > Self.warmupSamples { fullMilliseconds = smoothed(fullMilliseconds, milliseconds) }
    }

    public mutating func noteTilePass(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        tileSeen += 1
        if tileSeen > Self.warmupSamples { tileMilliseconds = smoothed(tileMilliseconds, milliseconds) }
    }

    private func smoothed(_ current: Double?, _ sample: Double) -> Double {
        current.map { $0 + Self.smoothing * (sample - $0) } ?? sample
    }

    /// The period to use now.
    public var period: Int {
        guard let full = fullMilliseconds, let tile = tileMilliseconds else { return Self.startingPeriod }
        let room = budgetMilliseconds - full
        // No room at all: the tile cannot fit; run it as rarely as allowed.
        guard room > 0 else { return maxPeriod }
        return min(maxPeriod, max(1, Int((tile / room).rounded(.up))))
    }

    /// Expected average detect time per frame at `period`, once measured.
    public var expectedMilliseconds: Double? {
        guard let full = fullMilliseconds, let tile = tileMilliseconds else { return nil }
        return full + tile / Double(period)
    }
}
