//
//  SessionModel+ShotPresentation.swift
//  CueSync AR
//
//  How the offered shot reads to the player: the ball in colour words, the
//  pocket as seen from where they stand, the difficulty as a held word, and
//  what to show when there is no shot at all.
//
//  The rules are pure and tested in CoachKit (PocketViewNaming, BallNaming,
//  DifficultyHold, ShotAvailability) and CueSyncUI (HUDPlacement). This file
//  is the wiring: it feeds them what only the app knows (the ball's measured
//  colour, where the table's axes land on the screen) and holds the result
//  where the HUD can read it.
//
//  Its own file, with its own small `@Observable` type, because
//  SessionModel.swift is at SwiftLint's file-length limit and a slice of
//  state with its own lifecycle is the extraction that file asks for.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation
import Observation
import PerceptionKit
import TableSpace

/// The table on the screen, in points (y down), rounded to a few points so
/// an unmoving table is an unchanged value and does not redraw the HUD.
struct TableFootprint: Equatable {
    /// The table, rails included, as four screen points.
    var quad: [Vec2]
    /// The pocket centres.
    var pockets: [Vec2]

    init(quad: [Vec2], pockets: [Vec2]) {
        func snap(_ p: Vec2) -> Vec2 { Vec2((p.x / 4).rounded() * 4, (p.y / 4).rounded() * 4) }
        self.quad = quad.map(snap)
        self.pockets = pockets.map(snap)
    }
}

/// What the HUD reads to word and place the shot card.
@MainActor
@Observable
final class ShotPresentation {
    /// Pocket names as seen from where the player stands. Empty until the
    /// table has been seen on screen: no name beats one from the wrong side.
    private(set) var pocketNames: [PocketID: String] = [:]
    /// Where the table is on the screen, nil until it has been seen. The
    /// shot cluster is placed off it (HUDPlacement.clusterPlan).
    private(set) var footprint: TableFootprint?
    /// The difficulty word on show, held against calibration flicker.
    private(set) var heldDifficulty: ShotRating.Difficulty?
    @ObservationIgnored private var hold = DifficultyHold()
    @ObservationIgnored private var heldShot: String?
    @ObservationIgnored private var lastScreenUpdate: TimeInterval = -.infinity
    /// The last placement, so the cluster stays put while it is still clear.
    @ObservationIgnored private var lastPlan: HUDClusterPlan?

    /// Minimum seconds between recomputing the screen geometry. Naming
    /// depends on where the device is looking, which moves continuously
    /// while it is held and not at all while it is parked.
    static let screenUpdateInterval: TimeInterval = 0.25

    /// Assigns only on change: an unchanged value must not invalidate the
    /// views reading it thirty times a second.
    func setView(names: [PocketID: String], footprint: TableFootprint?) {
        if names != pocketNames { pocketNames = names }
        if footprint != self.footprint { self.footprint = footprint }
    }

    func setFootprint(_ footprint: TableFootprint?) {
        if footprint != self.footprint { self.footprint = footprint }
    }

    /// Where to put the shot cluster on a screen of this size.
    func clusterPlan(viewport: Vec2, sizes: HUDClusterSizes,
                     insets: HUDClusterInsets) -> HUDClusterPlan {
        let plan = HUDPlacement.clusterPlan(
            tableQuad: footprint?.quad ?? [], pockets: footprint?.pockets ?? [],
            viewport: viewport, sizes: sizes, insets: insets, previous: lastPlan)
        lastPlan = plan
        return plan
    }

    /// Run the held difficulty for the shot on offer (nil clears it).
    func noteShot(_ shot: ShotRating?, at now: TimeInterval) {
        guard let shot else {
            hold.reset()
            heldShot = nil
            if heldDifficulty != nil { heldDifficulty = nil }
            return
        }
        let resolved = hold.resolve(shot, at: now)
        heldShot = "\(shot.ball.rawValue).\(shot.pocket.rawValue)"
        if resolved != heldDifficulty { heldDifficulty = resolved }
    }

    /// The difficulty to show for `shot`: the held word when it is for this
    /// shot, else its own.
    func difficulty(for shot: ShotRating) -> ShotRating.Difficulty {
        heldShot == "\(shot.ball.rawValue).\(shot.pocket.rawValue)"
            ? (heldDifficulty ?? shot.difficulty) : shot.difficulty
    }

    /// True when enough time has passed to recompute the screen geometry.
    func shouldRefreshScreen(at now: TimeInterval) -> Bool {
        guard now - lastScreenUpdate >= Self.screenUpdateInterval else { return false }
        lastScreenUpdate = now
        return true
    }
}

extension SessionModel {

    // MARK: - Words

    /// The ball a rating is about, in the player's words.
    func ballName(for id: BallID) -> String {
        guard let ball = tableState?.ball(id) else { return "Ball" }
        return BallNaming.name(kind: ball.kind,
                               colour: ballIdentity.family(for: id)?.family.rawValue)
    }

    /// `rating` as the player says it: "Blue ball → right side pocket". The
    /// pocket is left out, not guessed, until the table has been seen on
    /// screen.
    func shotCall(for rating: ShotRating) -> ShotCall {
        ShotCall(ball: ballName(for: rating.ball),
                 pocket: presentation.pocketNames[rating.pocket])
    }

    /// The call for the shot on offer, for the card, the voice and the mirror.
    var activeShotCall: ShotCall? {
        guard let shot = activeShot, shot.blocker == nil else { return nil }
        return shotCall(for: shot)
    }

    /// The difficulty word for `rating`, held steady.
    func shownDifficulty(of rating: ShotRating) -> ShotRating.Difficulty {
        presentation.difficulty(for: rating)
    }

    // MARK: - Nothing to show

    /// Why there is no shot card, when that is worth saying.
    var shotEmptyState: ShotEmptyState? {
        guard isLiveTracking, let state = tableState else { return nil }
        switch ShotAvailability.classify(state: state, active: activeShot) {
        case .noCleanShot: return .noCleanShot
        case .breakRack: return .breakRack
        case .shot, .notApplicable: return nil
        }
    }

    // MARK: - Where the table is on screen

    /// Name the pockets and place the HUD from where the table lands on
    /// screen right now.
    ///
    /// The table's axes are projected rather than reasoning from the camera
    /// pose, because the screen is the ground truth for "left" and "near":
    /// it already accounts for the device's orientation, its tilt and
    /// ARKit's own refinements. `project` is the AR view's world-to-screen
    /// mapping (nil for a point behind the camera), in the AR view's point
    /// space, which is the full screen.
    func noteTableOnScreen(project: (Vec3) -> CGPoint?) {
        guard presentation.shouldRefreshScreen(at: clock()),
              let calibration = tableCalibration, let table = tableState?.table else { return }
        func screen(_ p: Vec2) -> Vec2? {
            project(calibration.tableToWorld(p)).map { Vec2(Double($0.x), Double($0.y)) }
        }
        // Half a metre along each axis: far enough that perspective does
        // not collapse the vectors, near enough to stay on screen.
        guard let origin = screen(Vec2(0, 0)),
              let xTip = screen(Vec2(0.5, 0)),
              let yTip = screen(Vec2(0, 0.5)),
              let frame = PocketViewFrame(screenOrigin: origin, xTip: xTip, yTip: yTip) else { return }
        // The table with its rails and pocket jaws (about 10 cm past the
        // nose-to-nose field): that is the cloth the card must stay off.
        let half = table.halfExtents
        let rail = 0.10
        let corners = [Vec2(-half.x - rail, -half.y - rail), Vec2(half.x + rail, -half.y - rail),
                       Vec2(half.x + rail, half.y + rail), Vec2(-half.x - rail, half.y + rail)]
        let quad = corners.compactMap { screen($0) }
        let pockets = table.pockets.compactMap { screen($0.position) }
        // A corner behind the camera leaves no quad: the cluster then only
        // dodges the pockets, as before.
        let footprint = TableFootprint(quad: quad.count == 4 ? quad : [], pockets: pockets)
        presentation.setView(names: PocketViewNaming.names(for: table, frame: frame),
                             footprint: footprint)
    }
}
