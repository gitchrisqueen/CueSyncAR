//
//  TableSizeFromBalls.swift
//  TableSpace
//
//  Which standard table is this? Answered with the balls as a ruler.
//
//  Pockets cannot answer it: every standard table is 2:1, so the rays to
//  four pockets fit a 7, 8 or 9 ft table equally well, each at its own
//  depth. Seen from one camera position, a bigger table is the same shape
//  further away, and the depth below the camera that a size implies is
//  proportional to the size (similar triangles through the shared camera
//  centre).
//
//  A ball is a ruler of known length (57.15 mm). Its apparent size gives
//  its range independently of any table, and so a depth of the cloth below
//  the camera that owes nothing to the size setting. Comparing that depth
//  with the depth each candidate size implies gives the length of the
//  table directly:
//
//      impliedLength = length(S) * ballDepth / depth(S)
//
//  which should come out the same for every candidate S (it is one
//  measurement), and lands nearest the true size.
//

import CueSyncCore
import Foundation

public struct TableSizeFromBalls: Sendable, Equatable {
    /// Playing-field length the balls imply, metres.
    public var impliedLength: Double
    /// One-sigma uncertainty of `impliedLength`, metres.
    public var uncertainty: Double
    /// The standard size whose length is closest.
    public var nearest: TableSize
    /// Whether the evidence separates `nearest` from its neighbours: the
    /// implied length is closer to `nearest` than to any other size by
    /// at least two sigma.
    public var isDecisive: Bool

    public init(impliedLength: Double, uncertainty: Double, nearest: TableSize, isDecisive: Bool) {
        self.impliedLength = impliedLength
        self.uncertainty = uncertainty
        self.nearest = nearest
        self.isDecisive = isDecisive
    }

    /// - Parameters:
    ///   - cameraHeight: world Y of the camera when the pockets were sighted.
    ///   - ballClothHeight: world Y of the cloth measured from ball sizes.
    ///   - ballSpread: spread (half IQR) of that measurement, metres.
    ///   - solvedHeights: cloth height the pocket rays imply for each
    ///     candidate size (`PocketCalibration.solveHeight`).
    /// - Returns: nil when there is nothing to compare (no candidates, or
    ///   a cloth that is not below the camera).
    public static func classify(cameraHeight: Double,
                                ballClothHeight: Double,
                                ballSpread: Double,
                                solvedHeights: [(size: TableSize, height: Double)])
    -> TableSizeFromBalls? {
        let ballDepth = cameraHeight - ballClothHeight
        guard ballDepth > 0.05 else { return nil }
        let implied = solvedHeights.compactMap { entry -> Double? in
            let depth = cameraHeight - entry.height
            guard depth > 0.05 else { return nil }
            return entry.size.playField.width * ballDepth / depth
        }
        guard !implied.isEmpty else { return nil }
        let length = implied.reduce(0, +) / Double(implied.count)
        let sigma = length * max(ballSpread, 0) / ballDepth
        return classify(impliedLength: length, uncertainty: sigma)
    }

    /// Nearest standard size to a measured length, and whether it is
    /// separated from the others by at least two sigma of `uncertainty`.
    public static func classify(impliedLength length: Double,
                                uncertainty sigma: Double) -> TableSizeFromBalls {
        let sizes = TableSize.standardSizes.sorted { $0.playField.width < $1.playField.width }
        let ranked = sizes.sorted {
            abs($0.playField.width - length) < abs($1.playField.width - length)
        }
        let nearest = ranked[0]
        let nearestLength = nearest.playField.width
        // Distance from the implied length to the halfway line between
        // the nearest size and each neighbour; the smallest is the margin.
        let margins = sizes.filter { $0 != nearest }.map { other -> Double in
            let boundary = (other.playField.width + nearestLength) / 2
            return abs(boundary - length)
        }
        let margin = margins.min() ?? .infinity
        return TableSizeFromBalls(impliedLength: length, uncertainty: sigma,
                                  nearest: nearest, isDecisive: margin >= 2 * sigma)
    }

    /// One line for the mirror and the log.
    public var summary: String {
        let name = switch nearest {
        case .sevenFoot: "7 ft"
        case .eightFoot: "8 ft"
        case .nineFoot: "9 ft"
        default: "custom"
        }
        return String(format: "balls say %.2f +/- %.2f m long: %@%@", impliedLength,
                      uncertainty, name, isDecisive ? "" : " (not decisive)")
    }
}
