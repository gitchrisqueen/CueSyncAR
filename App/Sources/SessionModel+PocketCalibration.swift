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

import ARExperience
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
        // THE TAPS DECIDE THE HEIGHT, not the balls.
        //
        // Two or more pockets and a known table size determine the plane
        // exactly: rays from one place fan out, so only one depth cuts a
        // shape 2.34 m by 1.17 m out of them. Measured on device, that
        // solve agreed with itself to 1.5 mm across two independent pairs
        // of pockets, while the ball estimate ranged over 283 mm in the
        // same session and settled 158 mm wrong. An explicit `h` still
        // wins, because that is a person overriding on purpose.
        let ballHeight = estimateClothPlane()?.height
        let solvedHeight = pocketHeightFromTaps(sightings, size: size, coordinator: coordinator)
        guard let height = planeHeight ?? solvedHeight?.height ?? ballHeight else {
            showRemoteFeedback("Nothing to put the cloth on yet — tap at least "
                               + "two pockets, or pass h")
            return false
        }
        // The pockets cannot tell one standard size from another (they are
        // all 2:1, so a bigger table is the same shape further away). The
        // balls can, crudely, and this is the only thing they are asked.
        if let solvedHeight, let ballHeight,
           let better = betterFittingSize(than: size, ballHeight: ballHeight,
                                          solved: solvedHeight, sightings: sightings,
                                          coordinator: coordinator) {
            showRemoteFeedback("This looks more like a \(Self.sizeName(better)) table "
                               + "than a \(Self.sizeName(size)) one — check the size setting")
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
            // REFUSE A BAD FIT INSTEAD OF PROPOSING IT.
            //
            // A rigid fit always returns a table -- that is why the solver
            // reports a residual at all. Observed on device: two pockets
            // sighted from 3-4 m away produced "fit 429 mm rms", a table 43
            // cm out, and the old code proposed it anyway, leaving the user
            // looking at a wrong quad with no explanation.
            //
            // The cause is not the solver. The pocket unprojection is only
            // as good as the cloth height it is cast against, and the cloth
            // estimator's precision falls off with range.
            //
            // The refusal SAYS WHICH TAP AND WHY. It used to print one
            // number and then guess -- "stand closer, or sight a third
            // pocket" -- when on device the dominant error was neither
            // range nor pocket count but the cloth height. `spanReport`
            // separates the two without needing the fit to have worked.
            guard solution.residual <= Self.pocketFitLimit else {
                let refusal = Self.pocketRefusalText(
                    residual: solution.residual, height: height,
                    report: PocketCalibration.spanReport(placed, size: size))
                showRemoteFeedback(refusal)
                Self.log.error("\(refusal, privacy: .public)")
                notePocketFit(refusal)
                return false
            }
            // Propose, do not restore. `.cornersProposed` only fires from
            // `.planeFound`, so the reset has to walk back through it.
            // `preferredSize` is set FIRST because `.lockRequested`
            // re-derives the size from these corners and would otherwise be
            // free to snap to a different standard one.
            calibration.handle(.resetRequested)
            calibration.handle(.planeDetected)
            calibration.preferredSize = size
            // Record where the height came from BEFORE proposing, so a
            // calibration built on 7 mm of pocket geometry never again
            // reads the same as one built on nothing.
            placement.adopt(height: height, source: solvedHeight.map {
                .pocketGeometry(spans: $0.spanCount,
                                residualMillimetres: Int(($0.residual * 1000).rounded()))
            } ?? (ballHeight != nil ? currentClothHeight().source : .unconstrained))
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
                // CHECK that the propose actually landed. The transition
                // walks three events, and if any is refused the user is left
                // staring at an unchanged screen with a success toast --
                // which is what "Find my table does not work" looked like.
                guard case .adjusting = calibration.state else {
                    showRemoteFeedback("The fit did not take - the flow was not "
                                       + "ready. Tap Set up table first.")
                    return false
                }
                calibrationVisible = true
            }
            // The residual is the whole point of reporting rather than
            // just succeeding: a rigid fit always returns a table, and
            // this is how anyone finds out whether to believe it.
            // A one-pocket fit reproduces its single point exactly, so
            // its residual is meaningless and must not be printed as if
            // it were evidence.
            let source = planeHeight != nil ? "given"
                : (solvedHeight != nil ? "from the taps" : "from the balls")
            let line = placed.count == 1
                ? String(format: "Pockets: 1 (%@) + rail heading, cloth y=%.3f (%@) — "
                         + "no residual to check, verify by where the balls land",
                         solution.worstPocket.rawValue, height, source)
                : String(format: "Pockets: %d sighted, cloth y=%.3f (%@), fit %.0f mm rms, worst %@ %.0f mm",
                         placed.count, height, source, solution.residual * 1000,
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

    /// The cloth height the tapped pockets imply, or nil when they cannot
    /// say (fewer than two distinct pockets, or rays too alike to pin a
    /// depth down).
    ///
    /// Uses the RAYS, not the unprojected points — the points would need
    /// a height to exist, which is the thing being solved for.
    func pocketHeightFromTaps(_ sightings: [(PocketID, CGPoint)],
                              size: TableSize,
                              coordinator: ARSessionCoordinator)
    -> PocketCalibration.SolvedHeight? {
        let rays = sightings.compactMap { pocket, point -> (pocket: PocketID, ray: TapRay)? in
            coordinator.worldRay(through: point).map { (pocket, $0) }
        }
        // Every outcome is recorded, including the refusals. A silent nil
        // here reads downstream as "the balls were used", which is the
        // same thing a working solve that was never attempted looks like.
        guard rays.count == sightings.count else {
            placement.noteProbe("height: only \(rays.count) of \(sightings.count) "
                                + "taps produced a ray")
            return nil
        }
        let solved: PocketCalibration.SolvedHeight
        do {
            solved = try PocketCalibration.solveHeight(rays: rays, size: size)
        } catch {
            placement.noteProbe("height: \(error)")
            return nil
        }
        // A shape that does not fit the declared table is not a height to
        // build on, however precisely it was found. 30 mm rms is already
        // twice anything a clean set of taps produces.
        guard solved.residual <= 0.03 else {
            placement.noteProbe(String(
                format: "height: %.4f rejected, shape is %.0f mm rms off a %@ table",
                solved.height, solved.residual * 1000, Self.sizeName(size)))
            return nil
        }
        placement.noteProbe(String(format: "height: %.4f from %d spans, %.1f mm rms",
                                   solved.height, solved.spanCount, solved.residual * 1000))
        return solved
    }

    /// A standard size that matches the balls better than the chosen one,
    /// or nil when the chosen one is fine.
    ///
    /// Deliberately conservative: it only speaks when another size is a
    /// clearly better match, because the ball estimate is worth about
    /// +/-15 cm and the sizes are 4-7 cm apart in implied height. It
    /// suggests; it never switches anything.
    func betterFittingSize(than chosen: TableSize,
                           ballHeight: Double,
                           solved: PocketCalibration.SolvedHeight,
                           sightings: [(PocketID, CGPoint)],
                           coordinator: ARSessionCoordinator) -> TableSize? {
        let rays = sightings.compactMap { pocket, point -> (pocket: PocketID, ray: TapRay)? in
            coordinator.worldRay(through: point).map { (pocket, $0) }
        }
        let ranked = PocketCalibration.sizeAgreeingWith(ballHeight: ballHeight, rays: rays)
        guard let best = ranked.first, best.size != chosen,
              let chosenRank = ranked.first(where: { $0.size == chosen }) else { return nil }
        // Twice as close AND at least 5 cm better, or it is noise.
        guard chosenRank.disagreement > best.disagreement * 2,
              chosenRank.disagreement - best.disagreement > 0.05 else { return nil }
        return best.size
    }

    static func sizeName(_ size: TableSize) -> String {
        switch size {
        case .sevenFoot: "7-foot"
        case .eightFoot: "8-foot"
        case .nineFoot: "9-foot"
        default: "custom"
        }
    }

    /// `/cmd?action=probe&x=320&y=177[&h=-0.367]` — where does that tap
    /// actually land?
    ///
    /// Answers the question every wrong calibration raises and none of
    /// them could answer: was the tap in the wrong place, or cast against
    /// the wrong plane? It reports the world point, its distance from the
    /// camera, and the plane height used, which between them separate the
    /// two. Probing a pair of pockets and subtracting also measures the
    /// table directly, with no fit involved — the check that says whether
    /// a refusal was the solver being fussy or the taps being wrong.
    func handleProbeCommand(_ params: [String: String]) -> Bool {
        guard let x = params["x"].flatMap(Double.init),
              let y = params["y"].flatMap(Double.init) else { return false }
        guard let coordinator = arCoordinator else {
            placement.noteProbe("no AR session")
            return true
        }
        guard let height = params["h"].flatMap(Double.init) ?? estimateClothPlane()?.height else {
            placement.noteProbe("no cloth height: put a few balls out, or pass h")
            return true
        }
        guard let world = coordinator.raycastHorizontalPlane(
            screenPoint: CGPoint(x: x, y: y), fallbackPlaneHeight: height) else {
            placement.noteProbe(String(format: "(%.0f, %.0f) missed the plane at y=%.3f", x, y, height))
            return true
        }
        // The ray origin IS the camera, so range comes free with the ray.
        let range = coordinator.worldRay(through: CGPoint(x: x, y: y))
            .map { ($0.origin - world).length }
        placement.noteProbe(String(format: "(%.0f, %.0f) -> %.4f %.4f %.4f  range %@ m  plane y=%.3f",
                                x, y, world.x, world.y, world.z,
                                range.map { String(format: "%.2f", $0) } ?? "?", height))
        Self.log.notice("probe \(self.placement.lastProbe ?? "?", privacy: .public)")
        return true
    }

    /// Why the fit was refused, in terms of something the user can act on.
    ///
    /// Two causes, told apart by whether the taps disagree with each other
    /// or only with the table. Taps that agree among themselves but come
    /// out uniformly small or large were cast against the wrong cloth
    /// height -- no amount of walking closer or tapping more pockets fixes
    /// that, which is what the old advice kept telling people to do. Taps
    /// that disagree with each other have one bad pocket in them, and the
    /// span report names it.
    static func pocketRefusalText(residual: Double, height: Double,
                                  report: PocketCalibration.SpanReport) -> String {
        let scale = report.medianRatio
        let head = String(format: "Fit is %.0f cm out. ", residual * 100)
        if let suspect = report.suspectPocket, report.worstDisagreement > 0.08 {
            return head + String(
                format: "%@ disagrees with the others by %.0f cm - re-tap it, "
                    + "or check it is the hole you meant.",
                suspect.rawValue, report.worstDisagreement * 100)
        }
        if scale > 0, abs(scale - 1) > 0.05 {
            let direction = scale < 1 ? "too small" : "too large"
            return head + String(
                format: "The taps agree with each other but land %.0f%% %@ - "
                    + "that is the cloth height (y=%.3f), not the pockets. "
                    + "Put a few balls on the table and look at them first.",
                abs(scale - 1) * 100, direction, height)
        }
        return head + String(
            format: "The taps are self-consistent at the right scale, so the "
                + "labels are probably swapped - check which rail is which. "
                + "(cloth y=%.3f)", height)
    }

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

    /// Worst rigid-fit residual worth proposing, metres. A pocket mouth is
    /// about 7 cm across, so a fit worse than that is placing pockets
    /// outside the holes they were sighted on.
    static let pocketFitLimit = 0.07

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
        // Once the solver only wants a side, the next tap IS the side —
        // regardless of which chip happens to be armed. Requiring the chip
        // to be cleared first meant the flow could sit waiting for a tap it
        // was already being given.
        if pocketFlow.readiness == .needTowardsPoint, pocketFlow.towards == nil {
            pocketFlow.setTowards(Vec2(screen.x, screen.y))
            showTapFeedback(pocketFlow.prompt)
            return
        }
        // No chip armed and nothing left to sight: a stray tap should say
        // what it wanted rather than vanish.
        guard let pocket = armedPocket else {
            showTapFeedback(pocketFlow.prompt)
            return
        }
        pocketFlow.sight(pocket, at: Vec2(screen.x, screen.y))
        // Advance to the next unsighted pocket so the common case is
        // tap-tap-tap without touching the picker.
        let sighted = Set(pocketFlow.sightings.map(\.pocket))
        armedPocket = PocketID.allCases.first { !sighted.contains($0) }
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
