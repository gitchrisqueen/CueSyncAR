//
//  ShotPlanner.swift
//  ARExperience
//
//  The per-update midsection between a tracked TableState and a rendered
//  ShotPrediction: aim source selection (AimResolver) → temporal smoothing
//  and deadband (AimStabilizer) → re-solve only when the aim or the ball
//  layout actually changed. Extracted from the app's SessionModel so the
//  exact same decision sequence runs live (device clock) and under replay
//  (recorded frame timestamps). Pure value type over an injected solver.
//

import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

/// One solved shot: the stabilized aim that produced it and its source.
public struct ShotPlan: Sendable, Equatable {
    public var aim: AimRay
    public var source: AimResolver.Source
    public var prediction: ShotPrediction

    public init(aim: AimRay, source: AimResolver.Source, prediction: ShotPrediction) {
        self.aim = aim
        self.source = source
        self.prediction = prediction
    }
}

public struct ShotPlanner: Sendable {
    public struct Config: Sendable, Equatable {
        public var resolver: AimResolver.Config
        public var stabilizer: AimStabilizer.Config
        /// A ball that moved more than this (m), or any ball added, removed
        /// or re-classified, forces a re-solve even inside the aim deadband.
        /// Kalman sub-millimeter jitter must NOT count, or the deadband
        /// never engages.
        public var layoutTolerance: Double
        /// Hard cap on simulated events per shot (SolverOptions.maxEvents).
        public var maxEvents: Int

        public init(resolver: AimResolver.Config = .default,
                    stabilizer: AimStabilizer.Config = .default,
                    layoutTolerance: Double = 0.005,
                    maxEvents: Int = 8) {
            self.resolver = resolver
            self.stabilizer = stabilizer
            self.layoutTolerance = layoutTolerance
            self.maxEvents = maxEvents
        }

        public static let `default` = Config()
    }

    public let config: Config
    /// Cue-ball launch speed (m/s) predictions are solved at. Changing it
    /// invalidates the current plan so the next update re-solves.
    public var guideSpeed: Double {
        didSet { if guideSpeed != oldValue { invalidate() } }
    }
    /// The most recent plan; nil when no aim exists (no cue ball, no
    /// stable direction).
    public private(set) var plan: ShotPlan?
    /// Source of the most recent aim resolution.
    public var aimSource: AimResolver.Source { resolver.source }

    private let solver: any TrajectorySolving
    private var resolver: AimResolver
    private var stabilizer: AimStabilizer
    private var lastSource: AimResolver.Source?
    /// State the current plan was solved against.
    private var lastPredictedState: TableState?

    public init(solver: any TrajectorySolving,
                guideSpeed: Double = 3.5,
                config: Config = .default,
                engine: AimEngine = AimEngine()) {
        self.solver = solver
        self.guideSpeed = guideSpeed
        self.config = config
        self.resolver = AimResolver(config: config.resolver, engine: engine)
        self.stabilizer = AimStabilizer(config: config.stabilizer)
    }

    /// Run one update. Returns the current plan (nil when none) and whether
    /// it CHANGED — callers skip re-deriving coaching/overlays otherwise.
    /// `time` is seconds on a monotonic clock (frame timestamp under
    /// replay; the injected session clock live).
    public mutating func update(state: TableState,
                                stickQuad: [Vec2]?,
                                cameraTransform: Transform3D,
                                calibration: TableCalibration,
                                at time: TimeInterval) -> (plan: ShotPlan?, changed: Bool) {
        guard let cue = state.cueBall else {
            return clearPlan()
        }
        let (rawAim, source) = resolver.resolve(stickQuad: stickQuad,
                                                cueBall: cue.position,
                                                cameraTransform: cameraTransform,
                                                calibration: calibration,
                                                at: time)
        guard let rawAim else {
            return clearPlan()
        }
        // Blending across aim models would smear the transition.
        if source != lastSource {
            stabilizer.reset()
            lastSource = source
        }
        let (aim, aimChanged) = stabilizer.stabilize(rawAim)
        if !aimChanged, let plan,
           !Self.layoutMoved(from: lastPredictedState, to: state,
                             tolerance: config.layoutTolerance) {
            return (plan, false)
        }
        lastPredictedState = state
        let prediction = solver.predict(
            state: state, aim: aim,
            options: SolverOptions(initialSpeed: guideSpeed, maxEvents: config.maxEvents))
        let newPlan = ShotPlan(aim: aim, source: source, prediction: prediction)
        plan = newPlan
        return (newPlan, true)
    }

    /// Force the next update to re-solve (e.g. the guide speed changed).
    public mutating func invalidate() {
        lastPredictedState = nil
    }

    /// Forget everything (tracking stopped or reset).
    public mutating func reset() {
        resolver.reset()
        stabilizer.reset()
        lastSource = nil
        lastPredictedState = nil
        plan = nil
    }

    private mutating func clearPlan() -> (plan: ShotPlan?, changed: Bool) {
        let hadPlan = plan != nil
        plan = nil
        lastPredictedState = nil
        return (nil, hadPlan)
    }

    /// Material layout change: ball added/removed/re-classified or moved
    /// beyond `tolerance`. Timestamps never count.
    static func layoutMoved(from old: TableState?, to new: TableState,
                            tolerance: Double) -> Bool {
        guard let old, old.balls.count == new.balls.count else { return true }
        for ball in new.balls {
            guard let match = old.balls.first(where: { $0.id == ball.id }),
                  match.kind == ball.kind,
                  match.position.distance(to: ball.position) <= tolerance else {
                return true
            }
        }
        return false
    }
}
