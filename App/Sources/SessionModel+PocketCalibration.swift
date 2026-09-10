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
    /// - Parameter lockAfterProposing: whether to commit the solved table
    ///   immediately. The mirror route says true, because the operator
    ///   drives it with one URL and expects a locked table back. The in-app
    ///   route says false, so the solve lands in `.adjusting` with four
    ///   draggable handles and the user gets a chance to correct it.
    ///
    ///   Either way the solve now goes through `.cornersProposed` rather
    ///   than `.restored`. That used to jump straight to `.locked`, which
    ///   skipped the correction UI entirely — fine for a debug command
    ///   typed by a careful operator, wrong for a user, because the table
    ///   locked with no way to fix it and the residual arrived as a toast
    ///   nobody could act on. One code path also means the corner round
    ///   trip is exercised by both routes rather than only the manual one.
    func calibrateFromPockets(_ sightings: [(PocketID, CGPoint)],
                              towards: CGPoint?,
                              alongRail: (CGPoint, CGPoint)? = nil,
                              size: TableSize,
                              planeHeight: Double? = nil,
                              lockAfterProposing: Bool = true) -> Bool {
        guard let coordinator = arCoordinator else {
            showTapFeedback("No AR session to calibrate in")
            return false
        }
        guard let height = planeHeight ?? estimateClothPlane()?.height else {
            showRemoteFeedback("No cloth height: put a few balls on the table, or pass h")
            return false
        }
        func unproject(_ p: CGPoint) -> Vec3? {
            coordinator.raycastHorizontalPlane(screenPoint: p, fallbackPlaneHeight: height)
        }
        var placed: [PocketCalibration.Sighting] = []
        for (pocket, point) in sightings {
            guard let world = unproject(point) else {
                showRemoteFeedback("Pocket \(pocket.rawValue) missed the cloth plane")
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
                    showRemoteFeedback("A rail point missed the cloth plane")
                    return false
                }
                guard let hint else {
                    showRemoteFeedback("One pocket needs a towards point on the cloth")
                    return false
                }
                solution = try PocketCalibration.solve(pocket: only, alongRail: r1 - r0,
                                                       size: size, planeNormal: normal,
                                                       towards: hint)
            } else {
                solution = try PocketCalibration.solve(placed, size: size,
                                                       planeNormal: normal, towards: hint)
            }
            // Propose, do not restore. `.cornersProposed` only fires from
            // `.planeFound`, so the reset has to walk back through it.
            // `preferredSize` is set FIRST because `.lockRequested`
            // re-derives the size from these corners and would otherwise be
            // free to snap to a different standard one.
            calibration.handle(.resetRequested)
            calibration.handle(.planeDetected)
            calibration.preferredSize = size
            calibration.handle(.cornersProposed(solution.calibration.worldCorners))
            if lockAfterProposing {
                guard requestCalibrationLock(), let locked = tableCalibration else {
                    let reason = calibration.lastError
                        .map { Self.lockRefusalText($0) } ?? "unknown reason"
                    showRemoteFeedback("Pocket fit would not lock — \(reason)")
                    return false
                }
                // `requestCalibrationLock` deliberately does not anchor or
                // persist — the AR layer owns that, because it is the one
                // holding the coordinator. The mirror route has no AR layer
                // above it, so it does the same work here.
                if let anchorTransform = lockAnchorTransform {
                    persistCalibration(locked, anchorTransform: anchorTransform)
                }
                restartPipelineForCalibrationChange()
                startLiveTrackingIfReady()
            } else {
                // Leave it in `.adjusting` with the overlay up: four
                // draggable handles over a table the solver already found,
                // which is the correction step the old route skipped.
                calibrationVisible = true
            }
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
            showRemoteFeedback(line)
            Self.log.notice("\(line, privacy: .public)")
            notePocketFit(line)
            return true
        } catch {
            showRemoteFeedback("Pocket calibration refused: \(error)")
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
                showRemoteFeedback("Bad pocket \(entry)")
                return true
            }
            sightings.append((pocket, CGPoint(x: x, y: y)))
        }
        var towards: CGPoint?
        if let hint = params["towards"] {
            let parts = hint.split(separator: ":")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                showRemoteFeedback("Bad towards point")
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
                showRemoteFeedback("Bad rail (want x0:y0:x1:y1)")
                return true
            }
            rail = (CGPoint(x: parts[0], y: parts[1]), CGPoint(x: parts[2], y: parts[3]))
        }
        calibrateFromPockets(sightings, towards: towards, alongRail: rail, size: size,
                             planeHeight: params["h"].flatMap(Double.init))
        return true
    }

    /// Why a lock was refused, in words rather than an enum case.
    static func lockRefusalText(_ error: CalibrationError) -> String {
        switch error {
        case .needFourCorners:
            "the fit did not produce four corners"
        case .degenerateCorners:
            "the fitted corners are not a rectangle"
        case .unrecognizedTableSize(let width, let height):
            String(format: "%.2f x %.2f m is not a standard table", width, height)
        }
    }
}

// MARK: - Tapping pockets instead of cushion noses (C2b)
//
// The four-tap corner flow asks the user to find the cushion NOSE line —
// which, on a table with cloth-wrapped cushions, they cannot see. That is
// the whole reason the pocket solver exists. This is the same solver,
// reachable with a finger instead of a debug URL.

extension SessionModel {

    /// Enter pocket-sighting mode.
    func beginPocketSighting() {
        pocketFlow.reset()
        armedPocket = PocketID.allCases.first
        pocketSightingActive = true
        calibrationVisible = true
        noteCalibrationStarted()
        showTapFeedback(pocketFlow.prompt)
    }

    func cancelPocketSighting() {
        pocketSightingActive = false
        pocketFlow.reset()
    }

    /// Arm which pocket the next tap means. The user names the pocket
    /// BEFORE tapping it, rather than the app guessing from position —
    /// guessing is what a wrong table looks like, and a person standing at
    /// the table knows which hole is which without being told.
    func armPocket(_ pocket: PocketID) { armedPocket = pocket }

    /// A tap on the cloth while sighting.
    func notePocketTap(at screen: CGPoint) {
        guard pocketSightingActive else { return }
        if pocketFlow.readiness == .needTowardsPoint || pocketFlow.canSolve,
           pocketFlow.towards == nil, armedPocket == nil {
            pocketFlow.setTowards(Vec2(screen.x, screen.y))
            showTapFeedback(pocketFlow.prompt)
            return
        }
        guard let pocket = armedPocket else { return }
        pocketFlow.sight(pocket, at: Vec2(screen.x, screen.y))
        // Advance to the next unsighted pocket so the common case is
        // tap-tap-tap without touching the picker.
        let sighted = Set(pocketFlow.sightings.map(\.pocket))
        armedPocket = PocketID.allCases.first { !sighted.contains($0) }
        if pocketFlow.readiness == .needTowardsPoint { armedPocket = nil }
        showTapFeedback(pocketFlow.prompt)
    }

    func undoPocketSighting() {
        pocketFlow.undoLastSighting()
        let sighted = Set(pocketFlow.sightings.map(\.pocket))
        armedPocket = PocketID.allCases.first { !sighted.contains($0) }
        showTapFeedback(pocketFlow.prompt)
    }

    /// Solve from what has been sighted and hand the result to the
    /// correction UI. Does NOT lock: the user gets four draggable handles
    /// over the solver's answer, which is the step the mirror route used to
    /// skip.
    @discardableResult
    func commitPocketSighting(size: TableSize) -> Bool {
        guard pocketFlow.canSolve else {
            showTapFeedback(pocketFlow.prompt)
            return false
        }
        let sightings = pocketFlow.sightings.map {
            ($0.pocket, CGPoint(x: $0.screen.x, y: $0.screen.y))
        }
        let towards = pocketFlow.towards.map { CGPoint(x: $0.x, y: $0.y) }
        let rail = pocketFlow.railHeading.map {
            (CGPoint(x: $0.from.x, y: $0.from.y), CGPoint(x: $0.to.x, y: $0.to.y))
        }
        let solved = calibrateFromPockets(sightings, towards: towards, alongRail: rail,
                                          size: size, lockAfterProposing: false)
        if solved { pocketSightingActive = false }
        return solved
    }
}
