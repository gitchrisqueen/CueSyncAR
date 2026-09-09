//
//  SessionModel.swift
//  CueSync AR
//
//  The app's single source of truth and composition root: registers the
//  default provider implementations (see docs/roadmap/02-ARCHITECTURE.md),
//  exposes session state to SwiftUI, and — while model selection (M2-01)
//  is in progress — drives the Detection Preview loop that runs a chosen
//  Roboflow hosted model against live camera frames.
//
//  Every stored property lives in this file (`@Observable` tracks only the
//  class body). Behaviour that only reads, or has a single owning file,
//  lives in the SessionModel+*.swift extensions: Calibration, Settings,
//  Providers, AnchorFollowing, DebugMirror, MirrorState, Recording. Keep
//  this file for the composition root, live tracking, and the tracking
//  commands that mutate its private state.
//

import ARExperience
import BilliardsPhysics
import CoachKit
import CueSyncCore
import DetectionRoboflow
import Foundation
import Observation
import os
import PerceptionKit
import SessionReplay
import TableSpace
#if canImport(CoreML)
import CoreML
#endif

@MainActor
@Observable
final class SessionModel {
    enum Phase {
        case launching
        case findingTable
        case ready
    }

    struct PreviewStats {
        var latencyMilliseconds: Int = 0
        var detectionCount: Int = 0
        var lastError: String?
    }

    /// Diagnostics channel — filter the Xcode console with "cuesync".
    static let log = Logger(subsystem: "com.cuesync.ar", category: "session")

    let registry = ProviderRegistry()
    private(set) var phase: Phase = .launching
    /// Set when the user has denied camera access (drives an explicit
    /// error state instead of a silent black screen).
    var cameraDenied = false
    /// Why tracking is degraded, if it is — the structured half of
    /// `sessionEvent`, so the status capsule can say "Need more light"
    /// instead of showing a raw ARKit enum name.
    var trackingTrouble: ARSessionCoordinator.TrackingTrouble?

    /// Latest AR session health message (errors/interruptions/tracking
    /// limits), mirrored from the coordinator for the HUD.
    var sessionEvent: String?

    // MARK: Calibration (M3-02) — flow in SessionModel+Calibration.swift

    /// The calibration state machine (find plane → tap corners → adjust →
    /// lock). The AR layer feeds it events; views render its state.
    /// Mutate only from the calibration flow (SessionModel+Calibration);
    /// everyone else reads.
    var calibration = CalibrationController()
    /// Corners tapped so far while waiting for all four (world space).
    /// Written only by the calibration flow (SessionModel+Calibration).
    var pendingCorners: [Vec3] = []
    /// Whether the calibration overlay is on screen. Calibration is
    /// re-enterable from the HUD at any time (05-UX-DESIGN). Written only
    /// by the calibration flow (SessionModel+Calibration).
    var calibrationVisible = false

    /// The locked world-space calibration, when one exists — re-expressed
    /// in the table anchor's current world frame while live tracking
    /// follows the anchor (B3), else the lock-time value.
    var tableCalibration: TableCalibration? { anchorFollowedCalibration ?? calibration.calibration }

    /// Position of the shared calibration cluster anchor when it was last
    /// synced. ARKit refines anchors as its map improves; corners rebase by
    /// the anchor's delta so the rectangle stays glued to the real cloth
    /// while the device moves mid-calibration. Owned by the corner
    /// rebasing in SessionModel+Calibration; nothing else touches it.
    @ObservationIgnored var cornerAnchorBase: Vec3?

    // MARK: T1.2/T1.4 instrumentation

    /// When the session began attempting world-map relocalization. The
    /// stopwatch (start / timeout / restore) lives in
    /// SessionModel+Calibration; nothing else touches it.
    var relocalizationStartedAt: Date?
    /// How long the last successful relocalization took (nil = none yet).
    /// Written only by the relocalization stopwatch (SessionModel+Calibration).
    var relocalizationSeconds: Double?

    /// Latest ARFrame-flow counters from the coordinator (T1.4), published
    /// to the mirror so retention hunts don't need the Xcode console.
    private(set) var frameDiagnostics: FrameDiagnostics?

    func updateFrameDiagnostics(_ diagnostics: FrameDiagnostics) {
        let previous = frameDiagnostics
        frameDiagnostics = diagnostics
        // Log on change only (the loop polls every few seconds regardless).
        guard diagnostics != previous else { return }
        Self.log.info("""
            frames seen \(diagnostics.framesSeen) delivered \(diagnostics.framesDelivered) \
            copyFail \(diagnostics.copyFailures) snapshots \(diagnostics.snapshotsCompleted) \
            (avg \(Int(diagnostics.averageSnapshotMilliseconds)) ms, \
            inflight \(diagnostics.snapshotsInFlight))
            """)
    }

    // MARK: Live tracking (M3-05: pipeline → solver → overlay)

    /// Latest coherent table state from the perception pipeline.
    private(set) var tableState: TableState?
    /// Latest shot prediction for the current aim; nil when no stable aim.
    private(set) var shotPrediction: ShotPrediction?
    /// CoachKit's cue-tip recommendation for the current shot.
    private(set) var shotGuide: ShotGuide?
    /// Latest cue-stick footprint (table space) from the pipeline.
    private(set) var stickQuad: [Vec2]?
    /// Where the current aim comes from: the detected cue stick when one
    /// is addressing the ball, else the device-pose sighting model.
    typealias AimSource = AimResolver.Source
    private(set) var aimSource: AimSource = .devicePose
    /// B3 anchor following (SessionModel+AnchorFollowing.swift): the anchor
    /// transform the lock-time calibration was expressed against, that
    /// calibration re-derived from the anchor's latest transform (non-nil
    /// only while a pipeline runs), the anchor's drift since lock in mm
    /// (mirror `anchorDriftMm`), and the A/B switch (default ON).
    @ObservationIgnored var lockAnchorTransform: Transform3D?
    var anchorFollowedCalibration: TableCalibration?
    var anchorDriftMillimeters: Double?
    var followsTableAnchor = true
    /// The user's called pocket (M6-02); nil = no call.
    private(set) var calledPocket: PocketID?
    /// True when the current prediction sends an object ball into the
    /// called pocket.
    private(set) var calledShotOnLine = false

    func togglePocketCall(_ pocket: PocketID) {
        calledPocket = calledPocket == pocket ? nil : pocket
        // Recompute here, not only in `updateAim`. That path returns early
        // whenever the plan is unchanged, so calling a pocket while the aim
        // sat inside the deadband left the HUD and the pocket ring stale
        // until something else moved.
        recomputeCalledShotOnLine()
        noteRecordingEvent(.callPocket, pocket: pocket)
    }

    /// Does the CURRENT prediction sink a non-cue ball into the called
    /// pocket? Single definition, used by both triggers.
    func recomputeCalledShotOnLine() {
        guard let called = calledPocket, let prediction = shotPrediction else {
            calledShotOnLine = false
            return
        }
        let cueID = tableState?.cueBall?.id
        calledShotOnLine = prediction.events.contains { event in
            if case let .pocket(ball, pocket) = event {
                return pocket == called && ball != cueID
            }
            return false
        }
    }

    /// Manual cue-ball designation: the detector can miss non-plain cue
    /// balls (practice/measle balls with red dots read as color-ball).
    /// Tapping a tracked ball marks it as the cue ball by its stable track
    /// id; tapping the designated ball again clears the override.
    /// Durable cue-ball identity (ARExperience.CueBallIdentity): the tap,
    /// plus adoption of whatever the detector last called a cue ball, held
    /// across the label flickering. Same value type the replay harness
    /// runs, so what is judged offline is what ships.
    // MARK: Shot ranking (logic in SessionModel+Ranking.swift)

    /// The ranked shots, the app's suggestion and the player's override,
    /// as one value. Not `private(set)`: the rules that bind these
    /// together live inside `CoachKit.ShotSelection`, where they are pure
    /// and tested, and this property only holds it. Read it through the
    /// accessors in SessionModel+Ranking.
    var shotSelection = ShotSelection()

    /// The recommended shot, solved and ready for the overlay: how to make
    /// the ball the player picked. Nil when there is nothing to show.
    var targetOverlay: OverlayLayout.Target?

    /// Solver for the recommended shot. Separate from the one inside
    /// `shotPlanner` because the two answer different questions from the
    /// same physics — where the aim goes, and where it should go — and
    /// neither should invalidate the other's cache.
    @ObservationIgnored let targetSolver = AnalyticSolver()

    private(set) var cueIdentity = CueBallIdentity()
    /// The track currently treated as the cue ball, for the mirror.
    var designatedCueBallID: BallID? { cueIdentity.currentID }

    /// What each tracked ball is, accumulated over many looks at it.
    ///
    /// Fed from `PerceptionOutput.appearances`; read back by the ranking,
    /// which filters on the player's chosen half of the rack. Naming is
    /// deliberately allowed to stay `.unknown` — `BallGroup.includes`
    /// admits unnamed balls into both halves, so an unsure classifier
    /// costs the player nothing but a less specific label.
    private(set) var ballIdentity = BallIdentity()

    /// Pin what a ball is, overriding the classifier for the life of the
    /// track, and re-label the table immediately so the player sees the
    /// correction land rather than waiting for the next frame.
    ///
    /// Lives here rather than in +Ranking because `ballIdentity`,
    /// `cueIdentity` and `tableState` are all `private(set)`, which in
    /// Swift means private to this FILE — a setter in an extension in
    /// another file cannot reach them.
    func applyBallCorrection(_ kind: Ball.Kind?, to id: BallID) {
        ballIdentity.setOverride(kind, for: id)
        guard let state = tableState else { return }
        tableState = cueIdentity.apply(to: ballIdentity.apply(to: state))
        recomputeRanking()
    }

    /// Transient feedback line for the HUD after a tap — designation
    /// success/misses must never be silent (device debugging showed taps
    /// swallowed by guards with no visible reaction).
    private(set) var tapFeedback: String?
    @ObservationIgnored private var tapFeedbackTask: Task<Void, Never>?

    /// Every screen tap that actually REACHED the tap handler, and the
    /// last thing that happened as a result. Both are sticky — they are
    /// never cleared on a timer — because `tapFeedback` lives for 2.5 s
    /// and the mirror publishes at ~1 Hz, so a remote observer almost
    /// always misses it and cannot tell "the tap never arrived" from "the
    /// tap arrived, was handled, and the message already expired". Those
    /// two need opposite fixes.
    private(set) var rawTapCount = 0
    private(set) var lastTapNote: String?

    /// Whether the tap catcher is actually IN the view tree. The mirror's
    /// `liveTracking`/`calibrationVisible` only prove the CONDITION that
    /// should mount it; this proves the mount itself.
    private(set) var tapCatcherMounted = false

    /// Taps seen by a non-consuming recognizer on the ROOT view. Splits
    /// "touches never reach SwiftUI at all" from "touches reach SwiftUI
    /// but not the AR subtree" — which need completely different fixes.
    private(set) var rootTapCount = 0

    func setTapCatcherMounted(_ mounted: Bool) {
        tapCatcherMounted = mounted
        Self.log.info("tap catcher mounted=\(mounted, privacy: .public)")
    }

    func noteRootTap() {
        rootTapCount += 1
        Self.log.info("root tap #\(self.rootTapCount, privacy: .public)")
    }

    /// Called FIRST in the tap handler, before any guard, so the count
    /// rises even when every downstream check rejects the tap.
    func noteRawTap(kind: String, x: Double, y: Double) {
        rawTapCount += 1
        lastTapNote = String(format: "#%d %@ at (%.0f, %.0f)", rawTapCount, kind, x, y)
        Self.log.info("raw tap \(self.lastTapNote ?? "?", privacy: .public)")
    }

    func showTapFeedback(_ message: String) {
        lastTapNote = "#\(rawTapCount) → \(message)"
        tapFeedback = message
        tapFeedbackTask?.cancel()
        tapFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.tapFeedback = nil
        }
    }

    // MARK: Practice modes (M6-01)

    /// Every knob the Settings sheet exposes (M4-04), and the single
    /// source of truth for each — practice mode and guide speed below just
    /// read from here. Always mutate through `updateSettings` so the change
    /// persists and is applied (see SessionModel+Settings.swift).
    var settings = SettingsModel()

    /// Selected practice mode (persisted). The mode is a pure bundle of
    /// behavior flags from CoachKit — the app honors them, never the
    /// reverse (08-PRACTICE-MODES).
    var practiceMode: PracticeMode { settings.practiceMode }

    func selectPracticeMode(_ mode: PracticeMode) {
        updateSettings { $0.practiceMode = mode }
        Self.log.info("practice mode: \(mode.rawValue, privacy: .public)")
        showTapFeedback("Mode: \(mode.title)")
    }

    // MARK: Debug mirror (remote table-side debugging)

    /// LAN HTTP server exposing the rendered screen + tracking state, so a
    /// browser on the Mac can watch the iPad propped at the table (no cable).
    /// Started/stopped only by SessionModel+DebugMirror; the recorder and
    /// the mirror publisher just read it.
    @ObservationIgnored var debugMirror: DebugMirrorServer?

    /// The live AR session, so mirror commands can raycast a screen point
    /// the way a finger does. Weak: RootView owns it.
    @ObservationIgnored weak var arCoordinator: ARSessionCoordinator?
    /// Written only alongside `debugMirror` (SessionModel+DebugMirror).
    var debugMirrorURL: String?
    /// Raw detector labels from the latest pipeline frame (debug mirror).
    @ObservationIgnored private(set) var latestDetectionLabels: [String] = []

    /// Recent detections with the pose that produced them, for estimating
    /// the cloth height from the balls (SessionModel+Calibration). Bounded
    /// because it is a debugging/calibration aid, not a history.
    @ObservationIgnored var clothPlaneSamples: [(detections: [Detection2D], frame: CapturedFrame)] = []
    /// How many frames of balls the cloth estimate may draw on.
    static let clothPlaneSampleLimit = 12

    func recordClothPlaneSample(detections: [Detection2D], frame: CapturedFrame) {
        guard frame.intrinsics != nil, frame.cameraTransform != .identity else { return }
        clothPlaneSamples.append((detections, frame))
        if clothPlaneSamples.count > Self.clothPlaneSampleLimit {
            clothPlaneSamples.removeFirst(clothPlaneSamples.count - Self.clothPlaneSampleLimit)
        }
    }

    // MARK: Session recording (docs/recording-a-session.md)

    /// The detector-seam switch every live pipeline is built through: a
    /// SessionRecorder installed here sees exactly the frames the pipeline
    /// processes, so the bundle is 1:1 with live (SessionModel+Recording).
    @ObservationIgnored let recordingTap = RecordingTap()
    @ObservationIgnored var recorder: SessionRecorder? {
        didSet {
            let running = recorder != nil
            if isRecordingFlag != running { isRecordingFlag = running }
        }
    }
    /// What the AR layer lends the recorder (installed by ARCameraView).
    @ObservationIgnored var recordingHooks: RecordingHooks?
    /// Live numbers for the HUD badge while recording; nil otherwise.
    var recordingStatus: RecordingStatus?
    /// The last finished recording (HUD feedback, mirror `/state.json`).
    var lastRecordingSummary: RecordingSummary?
    /// Overlay colours: metric (colour-keyable) while a recording runs.
    var overlayPaletteMode: OverlayPaletteMode = .design

    /// `didSet` rather than discipline: the observed shadow below cannot
    /// drift out of sync with this store, because there is no assignment
    /// site that does not run it. Keeping them paired by hand is exactly
    /// how the original bug survived. (`didSet` does not run in `init` —
    /// both default to the same "not tracking" state, so that is fine.)
    @ObservationIgnored private var pipeline: PerceptionPipeline? {
        didSet {
            let live = pipeline != nil
            if isLiveTracking != live { isLiveTracking = live }
        }
    }
    @ObservationIgnored private var statesTask: Task<Void, Never>?
    /// Bundled on-device detector (M2-01/02); nil when the compiled model
    /// resource is missing (e.g. simulator-only CI builds).
    @ObservationIgnored private var onDeviceProvider: (any DetectionProviding)?
    /// True when live tracking runs on the bundled Core ML model rather
    /// than the hosted evaluation API.
    private(set) var usingOnDeviceDetection = false
    /// Hosted-API tracking cadence limiter, timed by frame capture time
    /// (0.5 s = previewInterval) — never wall time, so a recorded session
    /// throttles identically under replay.
    @ObservationIgnored private var trackingIngestThrottle = IngestThrottle(minimumInterval: 0.5)

    /// Stored and OBSERVED, deliberately — not `pipeline != nil`.
    ///
    /// `pipeline` is `@ObservationIgnored`, so a computed property derived
    /// from it is invisible to Observation: SwiftUI registers no dependency
    /// and never re-evaluates a body that branches on it. Every view gated
    /// on live tracking therefore kept rendering its pre-tracking state
    /// forever — the HUD still read "Point at the table" over a table it
    /// was actively tracking, and `PocketCallCatcher`, the ONLY tap handler
    /// for pocket calls and cue-ball designation, was never mounted at all,
    /// so every tap landed on nothing. Maintained by `pipeline`'s `didSet`.
    private(set) var isLiveTracking = false

    /// Observed backing for `isRecording` (SessionModel+Recording) — the
    /// class body is the only place `@Observable` tracks storage.
    /// Maintained by `recorder`'s `didSet`.
    private(set) var isRecordingFlag = false

    /// Build the perception pipeline once a calibration is locked and a
    /// detection provider is selected. Balls detected from then on are
    /// projected onto the locked table plane (intrinsics unprojection —
    /// no per-point ARKit raycasts) and tracked into TableState.
    func startLiveTrackingIfReady() {
        guard pipeline == nil, let calibration = tableCalibration else { return }
        // Settings choose the detector (bundled on-device by default —
        // offline, ~15 Hz); either still stands in for the other when the
        // preferred one is unavailable: no bundled model in a simulator
        // build, no key/selected model for the hosted evaluation adapter.
        let hosted = provider.map { $0 as any DetectionProviding }
        let preferHosted = settings.detectionProvider == .hosted && hosted != nil
        guard let detector = (preferHosted ? hosted : onDeviceProvider) ?? hosted ?? onDeviceProvider else {
            Self.log.error("""
                startLiveTracking: no detector (bundled model missing AND \
                no hosted model selected) — live tracking cannot start
                """)
            return
        }
        usingOnDeviceDetection = !preferHosted && onDeviceProvider != nil
        let detectorName = usingOnDeviceDetection ? "on-device BallDetector" : "hosted API"
        let tableSummary = String(format: "%.2fx%.2fm",
                                  calibration.size.playField.width,
                                  calibration.size.playField.height)
        Self.log.info("startLiveTracking: detector=\(detectorName, privacy: .public) table=\(tableSummary, privacy: .public)")
        let newPipeline = PerceptionPipeline(
            detector: recordingTap.wrapping(detector),
            calibration: calibration,
            raycaster: PlaneGeometryRaycaster(calibration: calibration),
            config: PerceptionConfig(followsTableAnchor: followsTableAnchor),
            trackerConfig: trackerConfigFromSettings(),
            tableAnchorTransform: lockAnchorTransform)
        pipeline = newPipeline
        isLiveTracking = true
        // Spatial overlays take over — stale 2D preview boxes would linger
        // frozen over the camera otherwise.
        latestDetections = []
        previewStats = PreviewStats()
        statesTask = Task { [weak self] in
            var outputCount = 0
            for await output in await newPipeline.outputs {
                outputCount += 1
                let count = outputCount
                await MainActor.run {
                    guard let self else { return }
                    // Colour first, cue designation last: the player's
                    // tap and the detector's own white-ball class both
                    // outrank a colour vote.
                    self.ballIdentity.observe(output.appearances)
                    self.ballIdentity.retain(Set(output.state.balls.map(\.id)))
                    self.tableState = self.cueIdentity.apply(
                        to: self.ballIdentity.apply(to: output.state))
                    self.recomputeRanking()
                    self.stickQuad = output.stickQuad
                    self.latestDetectionLabels = output.detectionLabels
                    if count == 1 || count % 40 == 0 {
                        let state = self.tableState
                        let summary = "balls=\(state?.balls.count ?? 0)"
                            + " cueBall=\(state?.cueBall != nil)"
                            + " stick=\(output.stickQuad != nil)"
                            + " designated=\(self.cueIdentity.designatedID != nil)"
                        Self.log.info("pipeline output #\(count): \(summary, privacy: .public)")
                    }
                }
            }
        }
    }

    func stopLiveTracking() {
        statesTask?.cancel()
        statesTask = nil
        pipeline = nil
        isLiveTracking = false
        anchorFollowedCalibration = nil
        anchorDriftMillimeters = nil
        tableState = nil
        shotPrediction = nil
        shotGuide = nil
        stickQuad = nil
        aimSource = .devicePose
        calledPocket = nil
        calledShotOnLine = false
        // The ranking is keyed on track ids, which die with the pipeline.
        // Unlike the cue-ball designation this is not worth preserving
        // across a restart: a target changes every shot, so re-tapping
        // costs the player nothing, while re-attaching a stale target to
        // the wrong ball would cost them a shot.
        clearRanking()
        // trackingReset, NOT reset: the ids die with the pipeline but the
        // balls are still on the felt, so the last known cue-ball position
        // has to outlive the restart or every recalibration and every
        // reset costs the user another tap.
        cueIdentity.trackingReset(at: clock())
        // Colours, unlike the cue-ball position, are keyed to track ids
        // and nothing else. A restarted tracker reuses ids, so keeping
        // them would paint the last session's balls onto this one's.
        ballIdentity.clear()
        usingOnDeviceDetection = false
        shotPlanner.reset()
        trackingIngestThrottle.reset()
        latestDetectionLabels = []
    }

    /// Feed a frame to the pipeline. On-device detection takes every frame
    /// the loop pulls (~6-7 Hz; the pipeline's latest-wins scheduling and
    /// the tracker handle the rest); the hosted API stays throttled to the
    /// quota-friendly preview cadence. No motion gate in either case:
    /// during live tracking the BALLS move while the phone may be still.
    func ingestTrackingFrame(_ frame: CapturedFrame, tableAnchorTransform: Transform3D? = nil) {
        guard let pipeline else { return }
        followTableAnchor(tableAnchorTransform)
        if !usingOnDeviceDetection {
            guard trackingIngestThrottle.admit(at: frame.timestamp) else { return }
        }
        Task { await pipeline.ingest(frame, tableAnchorTransform: tableAnchorTransform) }
    }

    /// Recompute the aim ray + shot prediction + coaching guide (called at
    /// UI cadence — solver is sub-ms). The detected cue stick wins when
    /// it's addressing the ball; the device-pose sighting model is the
    /// fallback so aiming always works without a stick in frame.
    /// Guide predictions use a firm-shot speed so trajectories reach the
    /// rails and show their ricochets (a 2 m/s lag-speed default dies
    /// mid-table — the user sees a line that just stops). 3.5 m/s with
    /// the effective cloth deceleration crosses the table several times;
    /// the 8-event budget still bounds the polyline. Remotely tunable via
    /// the mirror (`/cmd?action=guideSpeed&v=...`).
    var guideSpeed: Double { settings.guideSpeed }

    @ObservationIgnored private var lastAimNilLogAt: Date = .distantPast
    /// The aim → stabilize → solve midsection (ARExperience.ShotPlanner):
    /// stick-vs-device-pose selection with the seconds-based stick hold
    /// (2.5 s, measured at the table — see AimResolver), AimStabilizer
    /// smoothing + deadband, and re-solving only when the aim or the ball
    /// layout actually changed. The same value type runs under
    /// SessionReplay, so what the replay judges is what ships. Guide speed
    /// is pushed in by `applySettings` (SessionModel+Settings).
    @ObservationIgnored var shotPlanner = ShotPlanner(solver: AnalyticSolver(),
                                                      guideSpeed: SettingsModel.defaultGuideSpeed)
    /// Monotonic seconds for the stick-aim hold — the same time base as
    /// ARFrame.timestamp (system uptime). Injectable so a test or replay
    /// harness can drive the hold from recorded time instead of the wall.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func updateAim(cameraTransform: Transform3D) {
        guard let calibration = tableCalibration, let state = tableState else {
            shotPrediction = nil
            shotGuide = nil
            logNoGuides(tableCalibration == nil ? "no calibration" : "no pipeline output yet")
            return
        }
        let (plan, changed) = shotPlanner.update(state: state,
                                                 stickQuad: stickQuad,
                                                 cameraTransform: cameraTransform,
                                                 calibration: calibration,
                                                 at: clock())
        noteAimSource(shotPlanner.aimSource)
        guard let plan else {
            shotPrediction = nil
            shotGuide = nil
            if state.cueBall == nil {
                logNoGuides("no cue ball among \(state.balls.count) tracked balls (tap one to mark it)")
            } else if shotPlanner.stickIsResting {
                logNoGuides("cue is resting on the table — pick it up to aim")
            } else if settings.deviceParked {
                logNoGuides("no cue in view — the device is parked, so aim with the cue")
            } else {
                logNoGuides("no aim yet — point the cue at the cue ball")
            }
            return
        }
        if noGuideReason != nil { noGuideReason = nil }
        guard changed else { return }
        shotPrediction = plan.prediction
        shotGuide = ShotGuide.recommend(state: state, prediction: plan.prediction)
        recomputeCalledShotOnLine()
    }

    /// Why no guides render — the #1 question when the screen shows
    /// nothing. Published to the HUD and the mirror, not only the log: a
    /// device propped at the table has no console, and "nothing is drawn"
    /// and "nothing is drawn BECAUSE there is no cue ball" look identical
    /// from across the room. Nil whenever guides are rendering.
    private(set) var noGuideReason: String?

    /// The HUD capsule's current text, pushed in by RootView (which owns
    /// the decision tree) so the mirror can publish it. `/frame.jpg` is an
    /// ARView snapshot and contains no SwiftUI, so without this there is no
    /// way to check the HUD from a browser.
    var hudStatusLabel = ""

    /// When `aimSource` last changed, for the mirror's `aimSourceRunSeconds`
    /// — a source that flips every second is the "weird formations" symptom
    /// stated as a number.
    @ObservationIgnored private var aimSourceChangedAt: TimeInterval?

    /// Seconds the current aim source has been in force, nil before the
    /// first aim.
    var aimSourceRunSeconds: TimeInterval? {
        aimSourceChangedAt.map { clock() - $0 }
    }

    /// Record a source transition. Called from `updateAim`.
    func noteAimSource(_ source: AimResolver.Source) {
        if aimSource != source || aimSourceChangedAt == nil {
            aimSourceChangedAt = clock()
        }
        aimSource = source
    }

    /// State every call (the HUD needs it live); log at most every 5 s.
    private func logNoGuides(_ reason: String) {
        if noGuideReason != reason { noGuideReason = reason }
        guard Date().timeIntervalSince(lastAimNilLogAt) > 5 else { return }
        lastAimNilLogAt = Date()
        Self.log.info("updateAim: no guides — \(reason, privacy: .public)")
    }

    // MARK: Camera selection

    /// Detection-preview-only front camera mode (M2-01 evaluation). AR,
    /// calibration, and live tracking are back-camera features — ARKit
    /// world tracking cannot run on the front camera.
    var usingFrontCamera = false

    // MARK: Detection preview state

    /// Currently selected hosted model; nil = preview off.
    private(set) var selectedModel: RoboflowModelRef?
    private(set) var latestDetections: [Detection2D] = []
    private(set) var previewStats = PreviewStats()
    var hasRoboflowKey: Bool { !(secrets.secret(for: .roboflowAPIKey) ?? "").isEmpty }

    private let secrets: any SecretsProviding = AppSecrets()
    private var detectTask: Task<Void, Never>?
    @ObservationIgnored private var provider: RoboflowRemoteProvider?
    /// Encodes preview frames to JPEG *before* the upload task starts so the
    /// ARKit pixel buffer inside the frame is released immediately (see
    /// `ingestPreviewFrame`).
    @ObservationIgnored private var frameEncoder: (any FrameJPEGEncoding)?
    /// Skips detection passes while the camera is still: full cadence while
    /// moving, ~2 s heartbeat once settled (battery / API quota / thermals).
    @ObservationIgnored private var motionGate = MotionGate()
    /// Seconds between hosted-API calls (keep the free tier happy).
    private let previewInterval: TimeInterval = 0.5

    private static let selectedModelKey = "selectedDetectionModelID"

    func bootstrap() async {
        AppBuild.logStartup()
        await registry.register(AnalyticSolver() as any TrajectorySolving)
        await registry.register(AppSecrets() as any SecretsProviding)
        // Settings first: the mirror's start-on-launch preference, the
        // practice mode and the guide speed all come out of this load.
        settings = SettingsModel(loading: appSettingsStore)
        startDebugMirrorIfEnabled()
        // M2-01 winner, bundled: YOLOv11n on the pool-ball-agzev fork,
        // mAP50 0.896 / mAP50-95 0.765 (Linux fine-tune, epoch 19).
        // The MVP works offline on this model; the hosted picker remains
        // as evaluation tooling. Loaded OFF the main actor: MLModel init +
        // Neural Engine specialization can take seconds.
        #if canImport(CoreML)
        onDeviceProvider = await Self.loadBundledDetector()
        #endif
        phase = .findingTable
        // Restore the last-used preview model.
        if let saved = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let match = DetectionModelCatalog.candidates.first(where: { $0.id == saved }) {
            selectModel(match)
        }
    }

    func selectModel(_ model: RoboflowModelRef?) {
        selectedModel = model
        latestDetections = []
        previewStats = PreviewStats()
        UserDefaults.standard.set(model?.id, forKey: Self.selectedModelKey)
        guard let model else {
            provider = nil
            frameEncoder = nil
            return
        }
        // Fresh gate per model so a newly picked candidate detects
        // immediately even if the phone is resting on the rail.
        motionGate = MotionGate()
        let encoder = makeEncoder()
        frameEncoder = encoder
        provider = RoboflowRemoteProvider(
            model: model,
            apiKey: secrets.secret(for: .roboflowAPIKey) ?? "",
            transport: URLSessionTransport(),
            encoder: encoder)
    }

    /// Whether the preview loop should bother pulling a camera frame now.
    var wantsPreviewFrame: Bool {
        provider != nil && detectTask == nil
            && Date().timeIntervalSince(lastDetectionAt) >= previewInterval
    }

    /// Feed one camera frame into the preview loop. Skipped while a request
    /// is in flight or inside the throttle window — latest state wins.
    ///
    /// The frame wraps one of ARKit's few camera pixel buffers; retaining it
    /// across the hosted-API round trip (200–800 ms every 0.5 s) starves the
    /// capture pool — black camera feed, `(Fig) err=-12710`, and CAMetalLayer
    /// drawable failures. So: encode to JPEG synchronously (~640 px, a few ms
    /// at 2 Hz) and let `frame` die *before* any async work starts. Nothing
    /// below this method may capture `frame`.
    private var lastDetectionAt: Date = .distantPast
    func ingestPreviewFrame(_ frame: CapturedFrame) {
        guard let provider, let frameEncoder, detectTask == nil,
              Date().timeIntervalSince(lastDetectionAt) >= previewInterval else { return }
        // Motion gate: full cadence while the camera moves; slow heartbeat
        // when it's still. Uses the frame's own monotonic capture timestamp.
        // Poseless sources (front camera / plain AVCapture send .identity)
        // bypass the gate — there's no motion signal to gate on.
        if frame.cameraTransform != .identity {
            guard motionGate.shouldRunDetection(pose: frame.cameraTransform,
                                                timestamp: frame.timestamp) else { return }
        }
        lastDetectionAt = Date()
        // Pose and intrinsics only — a value type. The rule above forbids
        // capturing `frame` itself past this point because it wraps one of
        // ARKit's few pixel buffers; this copy holds no buffer.
        let poseOnly = CapturedFrame(timestamp: frame.timestamp,
                                     cameraTransform: frame.cameraTransform,
                                     intrinsics: frame.intrinsics)
        let jpeg: Data
        do {
            jpeg = try frameEncoder.encodeJPEG(from: frame).data
        } catch {
            previewStats.lastError = shortDescription(of: error)
            return
        }
        detectTask = Task { [weak self] in
            let started = Date()
            do {
                let detections = try await provider.detect(jpegData: jpeg)
                await MainActor.run {
                    guard let self else { return }
                    self.latestDetections = detections
                    self.recordClothPlaneSample(detections: detections, frame: poseOnly)
                    // The HUD count is BALLS, not raw boxes: cue-stick
                    // detections and low-confidence noise (server floor is
                    // 0.2 for evaluation) don't belong in "Tracking N".
                    let ballCount = detections.filter {
                        !$0.isCueStick && $0.confidence >= 0.35
                    }.count
                    self.previewStats = PreviewStats(
                        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        detectionCount: ballCount,
                        lastError: nil)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.previewStats.lastError = self.shortDescription(of: error)
                }
            }
            await MainActor.run { self?.detectTask = nil }
        }
    }

    private func shortDescription(of error: Error) -> String {
        if case RoboflowError.missingAPIKey = error {
            return "No Roboflow key — add it to Secrets.xcconfig"
        }
        if case let RoboflowError.badResponse(detail) = error {
            return "API: \(detail.prefix(80))"
        }
        return String(describing: error).prefix(80).description
    }
}

// MARK: - Tracking commands (HUD taps and mirror remote control)
//
// Split out of the class body so the composition root stays under
// SwiftLint's type_body_length limit; same file, so `private` members
// above remain visible here. The mirror server's own lifecycle is in
// SessionModel+DebugMirror.swift; it calls back into `handleMirrorCommand`.

extension SessionModel {
    /// Remote control from the mirror page (LAN debug tool): everything a
    /// finger on the screen could do, minus calibration-corner taps. Lets
    /// the remote debugging agent iterate with the device untouched at
    /// the table. Internal only so SessionModel+DebugMirror can install it
    /// as the server's command handler — nothing else should call it.
    /// Remote control from the mirror page. Split across three handlers
    /// rather than one switch: the calibration and shot-selection command
    /// sets each grew past the point where a single `switch` stayed under
    /// SwiftLint's complexity limit, and they are separate concerns
    /// anyway. Each returns whether it consumed the action.
    func handleMirrorCommand(_ params: [String: String]) {
        if handleCalibrationMirrorCommand(params) { return }
        if handleShotSelectionMirrorCommand(params) { return }
        switch params["action"] {
        case "resetTracking":
            resetBallTracking()
        case "designate":
            guard let x = params["x"].flatMap(Double.init),
                  let y = params["y"].flatMap(Double.init) else { return }
            // Generous radius: the caller clicked a listed ball's exact
            // coordinates, not a screen guess.
            designateCueBall(near: Vec2(x, y), maxDistance: 0.4)
        case "clearCue":
            // For the record: a designation tap on the marked ball clears it.
            if let id = cueIdentity.designatedID,
               let ball = tableState?.balls.first(where: { $0.id == id }) {
                noteRecordingEvent(.designateCueBall, x: ball.position.x, y: ball.position.y)
            }
            cueIdentity.clearDesignation()
            showTapFeedback("Cue-ball mark cleared (remote)")
        case "callPocket":
            guard let id = params["id"],
                  let pocket = tableState?.table.pockets
                    .first(where: { String(describing: $0.id) == id }) else { return }
            togglePocketCall(pocket.id)
            showTapFeedback("Pocket \(id) toggled (remote)")
        case "clearPocket":
            if let calledPocket { noteRecordingEvent(.callPocket, pocket: calledPocket) }
            calledPocket = nil
            calledShotOnLine = false
            showTapFeedback("Pocket call cleared (remote)")
        case "guideSpeed":
            guard let v = params["v"].flatMap(Double.init) else { return }
            updateSettings { $0.guideSpeed = v } // clamped by SettingsModel
            showTapFeedback(String(format: "Guide speed %.1f m/s (remote)", guideSpeed))
        case "missGrace":
            guard let v = params["v"].flatMap(Double.init) else { return }
            updateSettings { $0.visibleMissGrace = v }
            showTapFeedback(String(format: "Miss grace %.2f s (remote)", settings.visibleMissGrace))
        case "setMode":
            guard let raw = params["mode"], let mode = PracticeMode(rawValue: raw)
            else { return }
            selectPracticeMode(mode)
        case "parked":
            guard let v = params["v"].flatMap(Int.init) else { return }
            updateSettings { $0.deviceParked = v != 0 }
            showTapFeedback(settings.deviceParked
                            ? "Parked: aiming from the cue only (remote)"
                            : "Hand-held: device-pose aiming on (remote)")
        case "followAnchor":
            guard let v = params["v"].flatMap(Int.init) else { return }
            setFollowsTableAnchor(v != 0)
        case "startRecording":
            Task { await startRecording() }
        case "stopRecording":
            Task { await stopRecording(reason: .user) }
        default:
            handleProviderMirrorCommand(params)
        }
    }

    /// Drop every tracked ball and start tracking fresh (long-press during
    /// live tracking). Calibration stays locked — this is the escape hatch
    /// for stale tracks after balls were racked/moved en masse.
    func resetBallTracking() {
        guard isLiveTracking else { return }
        stopLiveTracking()
        startLiveTrackingIfReady()
        Self.log.info("ball tracking reset by user")
        showTapFeedback("Ball tracking reset — re-detecting…")
        noteRecordingEvent(.resetTracking)
    }

    func designateCueBall(near tablePoint: Vec2, maxDistance: Double = 0.25) {
        guard let balls = tableState?.balls, !balls.isEmpty else {
            let reason = tableState == nil ? "nil" : "empty"
            Self.log.info("designateCueBall: no tracked balls (tableState \(reason, privacy: .public))")
            showTapFeedback("No tracked balls yet — keep the table in view")
            return
        }
        guard let nearest = balls.min(by: {
            $0.position.distance(to: tablePoint) < $1.position.distance(to: tablePoint)
        }) else { return }
        let distance = nearest.position.distance(to: tablePoint)
        let tapSummary = String(
            format: "tap table=(%.2f, %.2f) nearest=(%.2f, %.2f) d=%.2fm of %d balls",
            tablePoint.x, tablePoint.y,
            nearest.position.x, nearest.position.y, distance, balls.count)
        Self.log.info("designateCueBall: \(tapSummary, privacy: .public)")
        guard distance <= maxDistance else {
            showTapFeedback(String(format: "Nearest tracked ball is %.2f m from your tap", distance))
            return
        }
        let wasDesignated = cueIdentity.designatedID == nearest.id
        if let state = tableState {
            cueIdentity.toggle(near: tablePoint, in: state, maxDistance: maxDistance)
        }
        showTapFeedback(wasDesignated ? "Cue-ball mark cleared" : "Marked as cue ball")
        noteRecordingEvent(.designateCueBall, x: tablePoint.x, y: tablePoint.y)
        // Re-apply immediately so the HUD/overlays react on this frame
        // instead of waiting for the next pipeline output.
        if let state = tableState {
            tableState = cueIdentity.apply(to: state)
        }
    }

}

