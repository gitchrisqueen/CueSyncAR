//
//  ClipConfig.swift
//  CueSync AR
//
//  corners.json: the four marked PLAYING-FIELD corners (cushion noses) of a
//  clip, in pixels of the frame image (top-left origin), plus the table size.
//
//  Order follows the TableCalibration.fromCorners contract: c0->c1 and
//  c3->c2 are one pair of opposite edges. This tool additionally requires
//  c0->c1 to be a LONG edge (table-space x axis), so the field rectangle is
//  c0=(-w/2,-h/2), c1=(+w/2,-h/2), c2=(+w/2,+h/2), c3=(-w/2,+h/2). Mirroring
//  (clockwise vs counter-clockwise on screen) is harmless: the planner is
//  symmetric and overlays go back through the inverse map.
//

import CueSyncCore
import Foundation
import TableSpace

public struct ClipConfig: Codable, Sendable, Equatable {
    /// "sevenFoot", "eightFoot" or "nineFoot".
    public var tableSize: String
    /// Four [x, y] pixel pairs: c0, c1, c2, c3.
    public var corners: [[Double]]
    public var notes: String?

    public init(tableSize: String, corners: [[Double]], notes: String? = nil) {
        self.tableSize = tableSize
        self.corners = corners
        self.notes = notes
    }
}

public enum ClipConfigError: Error, CustomStringConvertible, Equatable {
    case unknownTableSize(String)
    case badCorners(String)

    public var description: String {
        switch self {
        case .unknownTableSize(let name): "unknown tableSize '\(name)' (sevenFoot|eightFoot|nineFoot)"
        case .badCorners(let reason): "bad corners: \(reason)"
        }
    }
}

/// Everything a replay needs from a ClipConfig: the pixel<->table maps and
/// the table.
public struct ClipGeometry: Sendable {
    public let size: TableSize
    public let table: Table
    public let pixelCorners: [Vec2]
    public let imageToTable: Homography
    public let tableToImage: Homography

    public init(config: ClipConfig) throws {
        switch config.tableSize {
        case "sevenFoot": size = .sevenFoot
        case "eightFoot": size = .eightFoot
        case "nineFoot": size = .nineFoot
        default: throw ClipConfigError.unknownTableSize(config.tableSize)
        }
        guard config.corners.count == 4, config.corners.allSatisfy({ $0.count == 2 }) else {
            throw ClipConfigError.badCorners("need four [x, y] pairs")
        }
        pixelCorners = config.corners.map { Vec2($0[0], $0[1]) }

        // Metric field rectangle in the same corner order, lifted to z = 0 and
        // run through the real calibration so the size snap is the app's.
        let (width, height) = size.playField
        let field = [Vec2(-width / 2, -height / 2), Vec2(width / 2, -height / 2),
                     Vec2(width / 2, height / 2), Vec2(-width / 2, height / 2)]
        let calibration = try TableCalibration.fromCorners(
            field.map { Vec3($0.x, $0.y, 0) }, preferredSize: size)
        table = Table(size: calibration.size)

        guard let forward = Homography(from: pixelCorners, to: field),
              let backward = forward.inverse else {
            throw ClipConfigError.badCorners("corners are degenerate (collinear?)")
        }
        imageToTable = forward
        tableToImage = backward
    }

    /// Loads `<clip dir>/corners.json`.
    public static func load(from url: URL) throws -> ClipGeometry {
        let config = try JSONDecoder().decode(ClipConfig.self, from: Data(contentsOf: url))
        return try ClipGeometry(config: config)
    }
}
