//
//  SessionModel+PocketCalibration.swift
//  CueSync AR
//
//  The calibration path that works on a black-cloth table.
//
//  Split out of SessionModel+Calibration because that file was already
//  over the length limit and this is a self-contained route: pockets in,
//  a table out, with its own mirror command. The geometry itself is pure
//  and lives in TableSpace.PocketCalibration, which explains why pockets
//  rather than cushion noses.
//

import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

#if canImport(UIKit)
import UIKit
#endif

extension SessionModel {
    /// Calibrate from the pockets, with the cloth height from the balls.
    ///
    /// The one that works on a black-cloth table. Every other constructor
    /// starts from a cushion nose, and on cloth-wrapped cushions over a
    /// black bed that line has no contrast to find — what a camera can see
    /// is the cloth-to-rail edge several centimetres further out, and
    /// calibrating from that oversizes the table. A pocket is a hole: dark
    /// against light rail wood, and its mouth centre IS a corner of the
    /// nose rectangle, so sighting pockets measures the noses without
    /// anyone seeing one.
    ///
    /// `sightings` are view points paired with which pocket each is.
    /// `towards` is any view point on the cloth — a ball will do — needed
    /// only when every sighted pocket is on the same rail, which is the
    /// usual case for a device parked at the side.
    @discardableResult
    func calibrateFromPockets(_ sightings: [(PocketID, CGPoint)],
                              towards: CGPoint?,
                              alongRail: (CGPoint, CGPoint)? = nil,
                              size: TableSize,
                              planeHeight: Double? = nil) -> Bool {
        guard let coordinator = arCoordinator else {
            showTapFeedback("No AR session to calibrate in")
            return false
        }
        guard let height = planeHeight ?? estimateClothPlane()?.height else {
            showTapFeedback("No cloth height: put a few balls on the table, or pass h (remote)")
            return false
        }
        func unproject(_ p: CGPoint) -> Vec3? {
            coordinator.raycastHorizontalPlane(screenPoint: p, fallbackPlaneHeight: height)
        }
        var placed: [PocketCalibration.Sighting] = []
        for (pocket, point) in sightings {
            guard let world = unproject(point) else {
                showTapFeedback("Pocket \(pocket.rawValue) missed the cloth plane (remote)")
                return false
            }
            placed.append(PocketCalibration.Sighting(pocket: pocket, world: world))
        }
        let hint = towards.flatMap(unproject)
        // The cloth is horizontal in ARKit's gravity-aligned world, so up
        // is the normal. Solved from the balls it would be within a degree
        // of this anyway, and using gravity keeps the table level even
        // when the ball fit is noisy.
        let normal = Vec3(0, 1, 0)
        do {
            let solution: PocketCalibration.Solution
            if let alongRail, let only = placed.first, placed.count == 1 {
                // One pocket and a rail. The rail's own EDGE is enough
                // here because only its direction is used, and the edge
                // runs parallel to the nose line it hides.
                guard let r0 = unproject(alongRail.0), let r1 = unproject(alongRail.1) else {
                    showTapFeedback("A rail point missed the cloth plane (remote)")
                    return false
                }
                guard let hint else {
                    showTapFeedback("One pocket needs a towards point on the cloth (remote)")
                    return false
                }
                solution = try PocketCalibration.solve(pocket: only, alongRail: r1 - r0,
                                                       size: size, planeNormal: normal,
                                                       towards: hint)
            } else {
                solution = try PocketCalibration.solve(placed, size: size,
                                                       planeNormal: normal, towards: hint)
            }
            calibration.handle(.resetRequested)
            calibration.handle(.restored(solution.calibration))
            CalibrationStore.saveTableSpec(size)
            if let anchorTransform = lockAnchorTransform {
                persistCalibration(solution.calibration, anchorTransform: anchorTransform)
            }
            restartPipelineForCalibrationChange()
            startLiveTrackingIfReady()
            // The residual is the whole point of reporting rather than
            // just succeeding: a rigid fit always returns a table, and
            // this is how anyone finds out whether to believe it.
            // A one-pocket fit reproduces its single point exactly, so
            // its residual is meaningless and must not be printed as if
            // it were evidence.
            let line = placed.count == 1
                ? String(format: "Pockets: 1 (%@) + rail heading, cloth y=%.3f — "
                         + "no residual to check, verify by where the balls land",
                         solution.worstPocket.rawValue, height)
                : String(format: "Pockets: %d sighted, cloth y=%.3f, fit %.0f mm rms, worst %@ %.0f mm",
                         placed.count, height, solution.residual * 1000,
                         solution.worstPocket.rawValue, solution.worstError * 1000)
            showTapFeedback(line + " (remote)")
            Self.log.notice("\(line, privacy: .public)")
            notePocketFit(line)
            return true
        } catch {
            showTapFeedback("Pocket calibration refused: \(error) (remote)")
            Self.log.error("pocket calibration refused: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

extension SessionModel {
    /// `/cmd?action=calibrateFromPockets&p=cornerTopLeft,412,318&p=sideTop,1042,300
    ///  &p=cornerTopRight,1663,296&towards=900,520&v=eightFoot`
    ///
    /// Repeated `p` parameters are not something a query string carries
    /// portably, so the sightings arrive as one `pockets=` list of
    /// `name:x:y` triples separated by semicolons. Names are the PocketID
    /// raw values, which is what `/state.json` already prints.
    func handlePocketCalibrationCommand(_ params: [String: String]) -> Bool {
        guard let list = params["pockets"], !list.isEmpty else { return false }
        var sightings: [(PocketID, CGPoint)] = []
        for entry in list.split(separator: ";") {
            let parts = entry.split(separator: ":")
            guard parts.count == 3,
                  let pocket = PocketID(rawValue: String(parts[0])),
                  let x = Double(parts[1]), let y = Double(parts[2]) else {
                showTapFeedback("Bad pocket \(entry) (remote)")
                return true
            }
            sightings.append((pocket, CGPoint(x: x, y: y)))
        }
        var towards: CGPoint?
        if let hint = params["towards"] {
            let parts = hint.split(separator: ":")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                showTapFeedback("Bad towards point (remote)")
                return true
            }
            towards = CGPoint(x: x, y: y)
        }
        let size: TableSize
        switch params["v"] ?? "eightFoot" {
        case "sevenFoot": size = .sevenFoot
        case "nineFoot": size = .nineFoot
        default: size = .eightFoot
        }
        var rail: (CGPoint, CGPoint)?
        if let raw = params["rail"] {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 4 else {
                showTapFeedback("Bad rail (want x0:y0:x1:y1) (remote)")
                return true
            }
            rail = (CGPoint(x: parts[0], y: parts[1]), CGPoint(x: parts[2], y: parts[3]))
        }
        calibrateFromPockets(sightings, towards: towards, alongRail: rail, size: size,
                             planeHeight: params["h"].flatMap(Double.init))
        return true
    }
}
