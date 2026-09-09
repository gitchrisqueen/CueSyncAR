//
//  ClothPlaneEstimator.swift
//  PerceptionKit
//
//  Where the cloth is, measured from the balls sitting on it.
//
//  A ball's apparent size gives its range: it is a sphere of known
//  radius, so the silhouette's angular radius is asin(r / d) and the
//  distance follows. Every detected ball therefore reports the height of
//  the surface it is resting on, and the median over several balls and
//  frames is a robust estimate of the cloth.
//
//  This exists because the alternatives are worse. ARKit's plane
//  detection needs parallax and a device on a tripod never provides any —
//  it can sit for minutes with the table filling the frame and report
//  nothing. Taps on the cushion noses work, but a tap a few pixels inside
//  the nose shortens the measured rail, which pushes the solved plane
//  further away and inflates every distance on the cloth: measured on the
//  owner's table as ball centres spread 2.40 m across a 2.34 m field,
//  which is impossible, and which put a third of the balls outside the
//  playing-surface envelope so they were never tracked at all.
//
//  The balls need no taps and no motion.
//

import CueSyncCore
import Foundation

/// The cloth's height in world space, with enough context to judge it.
public struct ClothPlaneEstimate: Sendable, Equatable {
    /// World Y of the playing surface.
    public var height: Double
    /// How many ball observations survived filtering.
    public var sampleCount: Int
    /// Half the interquartile range of the per-ball heights, metres — the
    /// spread of the estimates that produced `height`. A table's balls all
    /// rest on the same surface, so a large spread means the samples are
    /// not all balls, or the intrinsics are wrong.
    public var spread: Double
    /// Range to the nearest and furthest ball used, metres. Reported
    /// because the estimate's precision falls off with distance: the same
    /// one-pixel error in the silhouette is worth far more at 3 m.
    public var nearestRange: Double
    public var furthestRange: Double

    public init(height: Double, sampleCount: Int, spread: Double,
                nearestRange: Double, furthestRange: Double) {
        self.height = height
        self.sampleCount = sampleCount
        self.spread = spread
        self.nearestRange = nearestRange
        self.furthestRange = furthestRange
    }
}

public enum ClothPlaneEstimator {
    public struct Config: Sendable, Equatable {
        /// Fewest balls that may produce an estimate. Three is the point
        /// at which a stray detection stops being able to carry the median.
        public var minimumSamples: Int
        /// Detections below this confidence are ignored.
        public var confidenceFloor: Double
        /// A ball's silhouette is round. Boxes further than this from
        /// square are merged balls, clipped at the frame edge, or not
        /// balls, and their size does not mean what the range formula
        /// assumes.
        public var maximumAspect: Double
        /// Silhouettes smaller than this carry too little signal: at the
        /// owner's shooting distance a ball is 16 px across, and one pixel
        /// of box error is already 6 % of range.
        public var minimumRadiusPixels: Double
        /// Estimates further than this from the median are dropped before
        /// the final average.
        public var outlierMetres: Double

        public init(minimumSamples: Int = 3,
                    confidenceFloor: Double = 0.35,
                    maximumAspect: Double = 1.6,
                    minimumRadiusPixels: Double = 4,
                    outlierMetres: Double = 0.05) {
            self.minimumSamples = minimumSamples
            self.confidenceFloor = confidenceFloor
            self.maximumAspect = maximumAspect
            self.minimumRadiusPixels = minimumRadiusPixels
            self.outlierMetres = outlierMetres
        }

        public static let `default` = Config()
    }

    /// Range to a sphere from the ANGULAR radius of its silhouette.
    ///
    /// `angularRadius` is the half-angle of the tangent cone, so
    /// `sin(angularRadius) = radius / range` exactly, at any position in
    /// the frame.
    public static func range(angularRadius: Double,
                             radius: Double = Ball.standardRadius) -> Double? {
        let sine = sin(angularRadius)
        guard angularRadius > 0, sine > 1e-9, radius > 0 else { return nil }
        return radius / sine
    }

    /// The silhouette's angular radius, measured from the detection box.
    ///
    /// Pixels are the wrong unit here and that is not a detail. A sphere's
    /// silhouette is a cone, and a pinhole images a cone as an ellipse
    /// that grows the further off axis it sits — so `f · r / d`, which is
    /// exact on the optical axis, reads 13 % small for a ball 24 degrees
    /// off it. Measured on the synthetic harness: -0.1 % near the axis,
    /// -2.0 % at 3 m, -13.1 % in the corner of the frame.
    ///
    /// Converting the box's edges back into ray directions and measuring
    /// the angle between them removes that entirely, because the angle
    /// between two rays does not care where in the frame they fall. The
    /// LARGER of the horizontal and vertical extents is taken: the
    /// ellipse's long axis lies along the radial direction, and the box —
    /// being axis-aligned — under-reports whichever axis is oblique to it.
    public static func angularRadius(of box: NormalizedRect,
                                     intrinsics k: CameraIntrinsics) -> Double? {
        guard box.width > 0, box.height > 0 else { return nil }
        func direction(_ px: Double, _ py: Double) -> Vec3 {
            Vec3((px - k.principalX) / k.focalX,
                 -((py - k.principalY) / k.focalY),
                 -1).normalized
        }
        let minX = box.x * k.imageWidth
        let maxX = (box.x + box.width) * k.imageWidth
        let minY = box.y * k.imageHeight
        let maxY = (box.y + box.height) * k.imageHeight
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        func halfAngle(_ a: Vec3, _ b: Vec3) -> Double {
            atan2(a.cross(b).length, a.dot(b)) / 2
        }
        let horizontal = halfAngle(direction(minX, midY), direction(maxX, midY))
        let vertical = halfAngle(direction(midX, minY), direction(midX, maxY))
        return Swift.max(horizontal, vertical)
    }

    /// Estimate the cloth's height from the balls in one or more frames.
    ///
    /// The cloth is horizontal — ARKit's world Y is gravity-aligned and a
    /// pool table is level — so the plane has one unknown, and each ball
    /// measures it independently. That is what makes this robust: no
    /// fitting, no minimisation, just a median over direct measurements.
    public static func estimate(frames: [(detections: [Detection2D], frame: CapturedFrame)],
                                radius: Double = Ball.standardRadius,
                                config: Config = .default) -> ClothPlaneEstimate? {
        var heights: [Double] = []
        var ranges: [Double] = []
        for (detections, frame) in frames {
            guard let k = frame.intrinsics else { continue }
            for detection in detections {
                guard !detection.isCueStick,
                      detection.confidence >= config.confidenceFloor else { continue }
                let box = detection.boundingBox
                let halfWidth = box.width * k.imageWidth / 2
                let halfHeight = box.height * k.imageHeight / 2
                guard halfWidth >= config.minimumRadiusPixels,
                      halfHeight >= config.minimumRadiusPixels else { continue }
                let aspect = max(halfWidth, halfHeight) / min(halfWidth, halfHeight)
                guard aspect <= config.maximumAspect else { continue }
                guard let alpha = angularRadius(of: box, intrinsics: k),
                      let distance = range(angularRadius: alpha, radius: radius) else { continue }
                // Ray through the box centre, in world space.
                let centre = box.center
                let xc = (centre.x * k.imageWidth - k.principalX) / k.focalX
                let yc = -((centre.y * k.imageHeight - k.principalY) / k.focalY)
                let direction = frame.cameraTransform
                    .transformDirection(Vec3(xc, yc, -1)).normalized
                let sphereCentre = frame.cameraTransform.translation + direction * distance
                heights.append(sphereCentre.y - radius)
                ranges.append(distance)
            }
        }
        guard heights.count >= config.minimumSamples else { return nil }
        let median = Self.median(heights)
        let kept = zip(heights, ranges).filter { abs($0.0 - median) <= config.outlierMetres }
        guard kept.count >= config.minimumSamples else { return nil }
        let keptHeights = kept.map(\.0)
        let keptRanges = kept.map(\.1)
        return ClothPlaneEstimate(height: Self.median(keptHeights),
                                  sampleCount: kept.count,
                                  spread: Self.halfInterquartileRange(keptHeights),
                                  nearestRange: keptRanges.min() ?? 0,
                                  furthestRange: keptRanges.max() ?? 0)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    static func halfInterquartileRange(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let sorted = values.sorted()
        let lower = sorted[sorted.count / 4]
        let upper = sorted[(sorted.count * 3) / 4]
        return (upper - lower) / 2
    }
}
