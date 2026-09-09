//
//  ReplayRunner.swift
//  SessionReplay
//
//  Drives a bundle through the SAME midsection the app runs live:
//
//      frames.jsonl ─▶ PerceptionPipeline.processFrame (RecordedDetectionProvider,
//                       PlaneGeometryRaycaster, BallTracker)
//                   ─▶ user events at that frame (designate / call pocket / reset)
//                   ─▶ ShotPlanner (AimResolver → AimStabilizer → AnalyticSolver)
//                   ─▶ OutputRecord
//
//  Strictly sequential: every frame is awaited inline, no tasks are
//  spawned, no clock is read — time is the recorded frame timestamp. Given
//  a bundle and a config, the outputs are a pure function of the code, so
//  two runs (same process, fresh process, another platform) must produce
//  byte-identical outputs.jsonl. That equality is the golden test.
//

import ARExperience
import BilliardsPhysics
import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

/// Everything tunable about a replay. Defaults mirror the app's live
/// settings (SessionModel) so a replay judges the shipped behavior.
public struct ReplayConfig: Sendable {
    public var perception: PerceptionConfig
    public var tracker: TrackerConfig
    public var physics: PhysicsConfig
    public var planner: ShotPlanner.Config
    /// Cue-ball launch speed predictions are solved at (SessionModel.guideSpeed).
    public var guideSpeed: Double
    /// Designation taps arrive as table-space points from the mirror
    /// (SessionModel: 0.4 m for remote designation).
    public var designateMaxDistance: Double

    public init(perception: PerceptionConfig = .default,
                tracker: TrackerConfig = .default,
                physics: PhysicsConfig = .standard,
                planner: ShotPlanner.Config = .default,
                guideSpeed: Double = 3.5,
                designateMaxDistance: Double = 0.4) {
        self.perception = perception
        self.tracker = tracker
        self.physics = physics
        self.planner = planner
        self.guideSpeed = guideSpeed
        self.designateMaxDistance = designateMaxDistance
    }

    public static let `default` = ReplayConfig()
}

public struct ReplayResult: Sendable, Equatable {
    public var outputs: [OutputRecord]
    /// Frames the pipeline dropped (no detections recorded / detector threw).
    public var droppedFrames: [Int]
    /// Canonical outputs.jsonl text.
    public var outputsText: String

    public var outputsData: Data { Data(outputsText.utf8) }
}

public struct ReplayRunner: Sendable {
    public let config: ReplayConfig

    public init(config: ReplayConfig = .default) {
        self.config = config
    }

    /// Replay `bundle` end to end. Throws only for a structurally invalid
    /// bundle; detector gaps are reported in `droppedFrames`.
    public func run(_ bundle: SessionBundle) async throws -> ReplayResult {
        try bundle.validate()
        let calibration = try bundle.calibration.tableCalibration()
        let detector = RecordedDetectionProvider(bundle: bundle)
        // B3 anchor following under replay: a device bundle records the
        // lock-time anchor transform (calibration.json) and the anchor's
        // transform in every frame (frames.jsonl), and its manifest says
        // whether the live pipeline followed it — replay the same way. A
        // scripted bundle has none of that, so its calibration stays
        // pinned and the byte-exact golden is unaffected.
        var replayConfig = config
        if let recorded = bundle.manifest.recording?.followsTableAnchor {
            replayConfig.perception.followsTableAnchor = recorded
        }
        var session = ReplaySession(config: replayConfig, calibration: calibration,
                                    detector: detector,
                                    lockAnchorTransform: try bundle.calibration.anchorTransform3D())
        var eventsByFrame: [Int: [RecordedEvent]] = [:]
        for event in bundle.events {
            eventsByFrame[event.frame, default: []].append(event)
        }

        var outputs: [OutputRecord] = []
        var dropped: [Int] = []
        // Aim-source run length, carried across frames.
        var lastAimSource: String?
        var sourceRun = 0
        for meta in bundle.frames {
            let frame = try meta.capturedFrame()
            guard let output = await session.pipeline.processFrame(
                frame, tableAnchorTransform: try meta.tableAnchorTransform3D()) else {
                dropped.append(meta.index)
                continue
            }
            var state = output.state
            for event in eventsByFrame[meta.index] ?? [] {
                session.apply(event, state: state)
                if event.kind == .resetTracking {
                    // Mirrors SessionModel.resetBallTracking: a fresh
                    // pipeline, and this frame's state is gone with it.
                    state = TableState(table: state.table, balls: [],
                                       timestamp: state.timestamp)
                }
            }
            state = session.applyingCueDesignation(state)
            let (plan, changed) = session.planner.update(
                state: state, stickQuad: output.stickQuad,
                cameraTransform: frame.cameraTransform,
                calibration: calibration, at: frame.timestamp)
            let onLine = session.calledShotOnLine(plan: plan, cueID: state.cueBall?.id)
            let aim = plan.map(OutputAim.init)
            if let source = aim?.source {
                sourceRun = (source == lastAimSource) ? sourceRun + 1 : 1
                lastAimSource = source
            } else {
                sourceRun = 0
                lastAimSource = nil
            }
            // Compose what the renderer would draw. Pure, and the only way
            // for replay to judge the overlay rather than stopping at the
            // plan behind it.
            let strips = plan.map { plan in
                OverlayLayout.compose(state: state, prediction: plan.prediction,
                                      calibration: calibration,
                                      calledPocket: session.calledPocket)
                    .strips.map { strip in
                        OutputStrip(ball: strip.ballID.rawValue,
                                    start: [strip.start.x, strip.start.y, strip.start.z],
                                    end: [strip.end.x, strip.end.y, strip.end.z],
                                    dashed: strip.dashed,
                                    color: Int(strip.color))
                    }
            }
            outputs.append(OutputRecord(
                frame: meta.index,
                timestamp: meta.timestamp,
                balls: state.balls.map(OutputBall.init),
                stick: output.stickQuad.map { $0.map { [$0.x, $0.y] } },
                labels: output.detectionLabels,
                aim: aim,
                prediction: plan.map { OutputPrediction($0.prediction) },
                planChanged: changed,
                calledPocket: session.calledPocket?.rawValue,
                calledShotOnLine: onLine,
                aimSourceRun: sourceRun,
                strips: strips))
        }
        return ReplayResult(outputs: outputs, droppedFrames: dropped,
                            outputsText: SessionBundleWriter.outputsText(outputs))
    }
}

/// Mutable replay state — the replay-side twin of SessionModel's live
/// tracking state, kept in one place so the two can be compared line by
/// line.
struct ReplaySession {
    let config: ReplayConfig
    let calibration: TableCalibration
    let detector: RecordedDetectionProvider
    /// Lock-time table anchor transform (device bundles); nil pins the calibration.
    let lockAnchorTransform: Transform3D?
    var pipeline: PerceptionPipeline
    var planner: ShotPlanner
    var designatedCueBallID: BallID?
    var calledPocket: PocketID?

    init(config: ReplayConfig, calibration: TableCalibration,
         detector: RecordedDetectionProvider, lockAnchorTransform: Transform3D? = nil) {
        self.config = config
        self.calibration = calibration
        self.detector = detector
        self.lockAnchorTransform = lockAnchorTransform
        pipeline = Self.makePipeline(config: config, calibration: calibration, detector: detector,
                                     lockAnchorTransform: lockAnchorTransform)
        planner = ShotPlanner(solver: AnalyticSolver(config: config.physics),
                              guideSpeed: config.guideSpeed, config: config.planner)
    }

    private static func makePipeline(config: ReplayConfig, calibration: TableCalibration,
                                     detector: RecordedDetectionProvider,
                                     lockAnchorTransform: Transform3D?) -> PerceptionPipeline {
        PerceptionPipeline(detector: detector,
                           calibration: calibration,
                           raycaster: PlaneGeometryRaycaster(calibration: calibration),
                           config: config.perception,
                           trackerConfig: config.tracker,
                           tableAnchorTransform: lockAnchorTransform)
    }

    mutating func apply(_ event: RecordedEvent, state: TableState) {
        switch event.kind {
        case .designateCueBall:
            guard let x = event.x, let y = event.y else { return }
            designateCueBall(near: Vec2(x, y), in: state)
        case .callPocket:
            guard let raw = event.pocket, let pocket = PocketID(rawValue: raw) else { return }
            calledPocket = calledPocket == pocket ? nil : pocket
        case .resetTracking:
            pipeline = Self.makePipeline(config: config, calibration: calibration,
                                         detector: detector, lockAnchorTransform: lockAnchorTransform)
            planner.reset()
            designatedCueBallID = nil
            calledPocket = nil
        case .note:
            break
        }
    }

    /// SessionModel.designateCueBall: nearest tracked ball within range
    /// becomes the cue ball; tapping the designated ball again clears it.
    mutating func designateCueBall(near point: Vec2, in state: TableState) {
        guard let nearest = state.balls.min(by: {
            let da = $0.position.distance(to: point)
            let db = $1.position.distance(to: point)
            return da != db ? da < db : $0.id.rawValue < $1.id.rawValue
        }) else { return }
        guard nearest.position.distance(to: point) <= config.designateMaxDistance else { return }
        designatedCueBallID = designatedCueBallID == nearest.id ? nil : nearest.id
    }

    /// SessionModel.applyingCueDesignation: the designated ball becomes
    /// .cue; any other .cue demotes to .unknown so exactly one cue exists.
    func applyingCueDesignation(_ state: TableState) -> TableState {
        guard let designatedCueBallID,
              state.balls.contains(where: { $0.id == designatedCueBallID }) else {
            return state
        }
        var adjusted = state
        adjusted.balls = state.balls.map { ball in
            var ball = ball
            if ball.id == designatedCueBallID {
                ball.kind = .cue
            } else if ball.kind == .cue {
                ball.kind = .unknown
            }
            return ball
        }
        return adjusted
    }

    /// M6-02: an OBJECT ball predicted into the called pocket.
    func calledShotOnLine(plan: ShotPlan?, cueID: BallID?) -> Bool {
        guard let calledPocket, let plan else { return false }
        return plan.prediction.events.contains { event in
            if case let .pocket(ball, pocket) = event {
                return pocket == calledPocket && ball != cueID
            }
            return false
        }
    }
}
