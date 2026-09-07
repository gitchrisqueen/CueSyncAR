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

import ARExperience
import BilliardsPhysics
import CoachKit
import CueSyncCore
import DetectionRoboflow
import Foundation
import Observation
import os
import PerceptionKit
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
    /// Latest AR session health message (errors/interruptions/tracking
    /// limits), mirrored from the coordinator for the HUD.
    var sessionEvent: String?

    // MARK: Calibration (M3-02)

    /// The calibration state machine (find plane → tap corners → adjust →
    /// lock). The AR layer feeds it events; views render its state.
    private(set) var calibration = CalibrationController()
    /// Corners tapped so far while waiting for all four (world space).
    private(set) var pendingCorners: [Vec3] = []
    /// Whether the calibration overlay is on screen. Calibration is
    /// re-enterable from the HUD at any time (05-UX-DESIGN).
    private(set) var calibrationVisible = false

    /// The locked world-space calibration, when one exists.
    var tableCalibration: TableCalibration? { calibration.calibration }

    func beginCalibration() {
        stopLiveTracking() // recalibration invalidates the pipeline's plane
        // Abandon the saved venue too: re-entering calibration means the
        // stored one is wrong (or the table moved). Prevents a stale bad
        // lock from relocalizing back over the fresh flow on next launch.
        CalibrationStore.clear()
        // Manual recalibration abandons any pending relocalization — stop
        // the stopwatch so a later restore can't misreport.
        relocalizationStartedAt = nil
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
        // Re-pins of a known table snap to its saved spec, not just the
        // generic standards (a shallow-angle tap set once locked an 8 ft
        // table as 7 ft — the spec makes repeat calibrations agree).
        // An explicit Settings override wins over the remembered spec.
        calibration.preferredSize = settings.tableSize.override ?? CalibrationStore.loadTableSpec()
        calibrationVisible = true
    }

    /// Live measured size while the user adjusts corners — shown in the
    /// calibration HUD BEFORE lock so a bad tap is visible immediately.
    var calibrationSizePreview: String? {
        guard case .adjusting(let corners) = calibration.state,
              let preview = try? TableCalibration.fromCorners(
                corners, preferredSize: calibration.preferredSize) else {
            return nil
        }
        let comparison = preview.standardSizeComparison
        return String(format: "%.2f × %.2f m — %@",
                      preview.measuredWidth ?? 0,
                      preview.measuredHeight ?? 0,
                      comparison.summary)
    }

    func cancelCalibration() {
        calibrationVisible = false
    }

    func calibrationPlaneDetected() {
        calibration.handle(.planeDetected)
    }

    /// Add one tapped corner; proposes the (perimeter-ordered) rectangle to
    /// the controller once all four are down.
    func placeCorner(_ world: Vec3, planeNormal: Vec3) {
        guard case .planeFound = calibration.state, pendingCorners.count < 4 else { return }
        pendingCorners.append(world)
        if pendingCorners.count == 4 {
            let ordered = CornerOrdering.orderedAroundCentroid(pendingCorners,
                                                               planeNormal: planeNormal)
            calibration.handle(.cornersProposed(ordered))
        }
    }

    /// Throw away tapped/proposed corners and start corner placement over
    /// (stays in the flow; the AR layer re-reports the plane on next tick).
    func restartCorners() {
        pendingCorners = []
        cornerAnchorBase = nil
        calibration.handle(.resetRequested)
    }

    // MARK: Corner anchor rebasing (mid-calibration drift)

    /// Position of the shared calibration cluster anchor when it was last
    /// synced. ARKit refines anchors as its map improves; corners rebase by
    /// the anchor's delta so the rectangle stays glued to the real cloth
    /// while the device moves mid-calibration.
    @ObservationIgnored private var cornerAnchorBase: Vec3?

    func setCornerAnchorBase(_ position: Vec3) {
        cornerAnchorBase = position
    }

    func rebaseCorners(clusterAnchorAt current: Vec3) {
        guard let base = cornerAnchorBase else { return }
        let delta = current - base
        guard delta.length > 1e-6 else { return }
        cornerAnchorBase = current
        if !pendingCorners.isEmpty {
            pendingCorners = pendingCorners.map { $0 + delta }
        }
        if case let .adjusting(corners) = calibration.state {
            for (index, corner) in corners.enumerated() {
                calibration.handle(.cornerMoved(index: index, to: corner + delta))
            }
        }
    }

    func moveCorner(index: Int, to world: Vec3) {
        calibration.handle(.cornerMoved(index: index, to: world))
    }

    /// Ask the controller to lock. On success the overlay dismisses; the
    /// caller (AR layer) then anchors + persists via `persistCalibration`.
    func requestCalibrationLock() -> Bool {
        calibration.handle(.lockRequested)
        guard calibration.isLocked else { return false }
        calibrationVisible = false
        // T1.2 measurement truth: surface how far the measured field sits
        // from the nearest standard size the moment it locks — a big delta
        // means mis-tapped corners (outer rail instead of cushion nose).
        if let locked = tableCalibration {
            let comparison = locked.standardSizeComparison
            let field = locked.size.playField
            showTapFeedback(String(format: "Locked %.2f × %.2f m — %@",
                                   field.width, field.height, comparison.summary))
            Self.log.notice("calibration locked: \(comparison.summary, privacy: .public) (max delta \(Int(comparison.maxDelta * 1000)) mm)")
            // Remember this table's size as the user's spec so future
            // re-pins snap to it (survives venue clears).
            CalibrationStore.saveTableSpec(locked.size)
        }
        return true
    }

    /// Persist a locked calibration relative to its world anchor so a
    /// returning visit relocalizes straight to Ready.
    func persistCalibration(_ locked: TableCalibration, anchorTransform: Transform3D) {
        CalibrationStore.save(AnchoredCalibration(calibration: locked,
                                                  anchorTransform: anchorTransform))
    }

    /// A saved venue relocalized — jump to locked (unless the user already
    /// locked a fresh calibration this session; the controller ignores it).
    func restoreCalibration(_ restored: TableCalibration) {
        let wasLocked = calibration.isLocked
        calibration.handle(.restored(restored))
        // T1.2 relocalization timing: verified bar is locked within 15 s of
        // seeing the table; the mirror surfaces the measured number.
        if !wasLocked, calibration.isLocked, let started = relocalizationStartedAt {
            let seconds = Date().timeIntervalSince(started)
            relocalizationSeconds = seconds
            relocalizationStartedAt = nil
            showTapFeedback(String(format: "Table restored in %.1f s", seconds))
            Self.log.notice("relocalized in \(String(format: "%.2f", seconds), privacy: .public) s")
        }
    }

    // MARK: T1.2/T1.4 instrumentation

    /// When the session began attempting world-map relocalization.
    private var relocalizationStartedAt: Date?
    /// How long the last successful relocalization took (nil = none yet).
    private(set) var relocalizationSeconds: Double?

    /// The AR layer calls this the moment it starts a session with a saved
    /// world map, starting the relocalization stopwatch.
    func markRelocalizationStart() {
        relocalizationStartedAt = Date()
        relocalizationSeconds = nil
    }

    /// The 15 s relocalization deadline passed. Log it but KEEP the
    /// stopwatch running: ARKit retains the loaded world map across the
    /// fallback reconfigure and often relocalizes late (~2 min observed on
    /// the black-cloth table) — that late number is exactly the
    /// measurement T1.2 exists to capture.
    func markRelocalizationTimeout() {
        guard let started = relocalizationStartedAt else { return }
        Self.log.notice("relocalization deadline (15 s) passed after \(Int(Date().timeIntervalSince(started))) s — plane detection reenabled, stopwatch still running")
    }

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
    /// The user's called pocket (M6-02); nil = no call.
    private(set) var calledPocket: PocketID?
    /// True when the current prediction sends an object ball into the
    /// called pocket.
    private(set) var calledShotOnLine = false

    func togglePocketCall(_ pocket: PocketID) {
        calledPocket = calledPocket == pocket ? nil : pocket
        if calledPocket == nil { calledShotOnLine = false }
    }

    /// Manual cue-ball designation: the detector can miss non-plain cue
    /// balls (practice/measle balls with red dots read as color-ball).
    /// Tapping a tracked ball marks it as the cue ball by its stable track
    /// id; tapping the designated ball again clears the override.
    private(set) var designatedCueBallID: BallID?

    /// Transient feedback line for the HUD after a tap — designation
    /// success/misses must never be silent (device debugging showed taps
    /// swallowed by guards with no visible reaction).
    private(set) var tapFeedback: String?
    @ObservationIgnored private var tapFeedbackTask: Task<Void, Never>?

    func showTapFeedback(_ message: String) {
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
    @ObservationIgnored private(set) var debugMirror: DebugMirrorServer?
    private(set) var debugMirrorURL: String?
    /// Raw detector labels from the latest pipeline frame (debug mirror).
    @ObservationIgnored private(set) var latestDetectionLabels: [String] = []

    @ObservationIgnored private var pipeline: PerceptionPipeline?
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

    var isLiveTracking: Bool { pipeline != nil }

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
            detector: detector,
            calibration: calibration,
            raycaster: PlaneGeometryRaycaster(calibration: calibration),
            trackerConfig: trackerConfigFromSettings())
        pipeline = newPipeline
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
                    self.tableState = self.applyingCueDesignation(output.state)
                    self.stickQuad = output.stickQuad
                    self.latestDetectionLabels = output.detectionLabels
                    if count == 1 || count % 40 == 0 {
                        let state = self.tableState
                        let summary = "balls=\(state?.balls.count ?? 0)"
                            + " cueBall=\(state?.cueBall != nil)"
                            + " stick=\(output.stickQuad != nil)"
                            + " designated=\(self.designatedCueBallID != nil)"
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
        tableState = nil
        shotPrediction = nil
        shotGuide = nil
        stickQuad = nil
        aimSource = .devicePose
        calledPocket = nil
        calledShotOnLine = false
        designatedCueBallID = nil
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
    func ingestTrackingFrame(_ frame: CapturedFrame) {
        guard let pipeline else { return }
        if !usingOnDeviceDetection {
            guard trackingIngestThrottle.admit(at: frame.timestamp) else { return }
        }
        Task { await pipeline.ingest(frame) }
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
        aimSource = shotPlanner.aimSource
        guard let plan else {
            shotPrediction = nil
            shotGuide = nil
            if state.cueBall == nil {
                logNoGuides("no cue ball among \(state.balls.count) tracked balls (tap one to mark it)")
            }
            return
        }
        guard changed else { return }
        shotPrediction = plan.prediction
        shotGuide = ShotGuide.recommend(state: state, prediction: plan.prediction)
        calledShotOnLine = calledPocket.map { called in
            plan.prediction.events.contains { event in
                if case let .pocket(ball, pocket) = event {
                    return pocket == called && ball != state.cueBall?.id
                }
                return false
            }
        } ?? false
    }

    /// Throttled: explain WHY no guides render (the #1 question when the
    /// screen shows nothing). Logging cadence only — never affects state.
    private func logNoGuides(_ reason: String) {
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

    #if canImport(CoreML)
    /// Load the bundled BallDetector OFF the main actor (MLModel init can
    /// take seconds) and hand back the Sendable provider.
    private nonisolated static func loadBundledDetector() async -> (any DetectionProviding)? {
        await Task.detached(priority: .userInitiated) {
            guard let url = Bundle.main.url(forResource: "BallDetector",
                                            withExtension: "mlmodelc") else { return nil }
            let configuration = MLModelConfiguration()
            // Still CPU-only. T1.3 negative result (2026-07-23, crash logs
            // on file): even the iOS16-target/CoreML6 re-export with fp32
            // pipeline outputs aborts in MPSGraph's MLIR optimization
            // passes on iOS 26 the moment GPU/ANE compiles it — the
            // boundary-cast theory is dead; the bug is in MPSGraph's
            // ingestion of coremltools-9 mlprograms generally. Next
            // candidates: iOS17-target export, then fp32 GPU-only.
            configuration.computeUnits = .cpuOnly
            guard let model = try? MLModel(contentsOf: url,
                                           configuration: configuration),
                  let provider = try? CoreMLDetectionProvider(model: model) else {
                return nil
            }
            return provider as (any DetectionProviding)
        }.value
    }
    #endif

    private func makeEncoder() -> any FrameJPEGEncoding {
        #if canImport(CoreImage)
        PixelBufferJPEGEncoder()
        #else
        UnsupportedEncoder()
        #endif
    }
}

// MARK: - Debug mirror and tracking commands
//
// Split out of the class body so the composition root stays under
// SwiftLint's type_body_length limit; same file, so `private` members
// above remain visible here.

extension SessionModel {
    /// HUD antenna button. Flips the persisted preference; the mirror is
    /// brought up or down by `applyDebugMirrorSetting`, so the button and
    /// the Settings sheet toggle drive exactly one switch.
    func toggleDebugMirror() {
        updateSettings { $0.debugMirrorEnabled.toggle() }
    }

    /// Match the running mirror to `settings.debugMirrorEnabled`.
    func applyDebugMirrorSetting() {
        guard !settings.debugMirrorEnabled else {
            startDebugMirrorIfEnabled()
            return
        }
        guard let server = debugMirror else { return }
        server.stop()
        debugMirror = nil
        debugMirrorURL = nil
        showTapFeedback("Debug mirror off")
    }

    /// Bring the mirror up if the preference allows (default ON): the
    /// device usually sits at the table out of reach, so the mirror must
    /// survive app relaunches without a hand touching the screen.
    func startDebugMirrorIfEnabled() {
        guard debugMirror == nil, settings.debugMirrorEnabled else { return }
        startDebugMirror()
    }

    private func startDebugMirror() {
        do {
            let server = try DebugMirrorServer()
            server.setCommandHandler { [weak self] params in
                Task { @MainActor in
                    self?.handleMirrorCommand(params)
                }
            }
            debugMirror = server
            let host = DebugMirrorServer.deviceIPAddress() ?? "<device-ip>"
            debugMirrorURL = "http://\(host):\(DebugMirrorServer.port)"
            Self.log.info("debug mirror at \(self.debugMirrorURL ?? "?", privacy: .public)")
        } catch {
            Self.log.error("debug mirror failed: \(String(describing: error), privacy: .public)")
            showTapFeedback("Mirror failed to start (port in use?)")
        }
    }

    /// Remote control from the mirror page (LAN debug tool): everything a
    /// finger on the screen could do, minus calibration-corner taps. Lets
    /// the remote debugging agent iterate with the device untouched at
    /// the table.
    private func handleMirrorCommand(_ params: [String: String]) {
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
            designatedCueBallID = nil
            showTapFeedback("Cue-ball mark cleared (remote)")
        case "callPocket":
            guard let id = params["id"],
                  let pocket = tableState?.table.pockets
                    .first(where: { String(describing: $0.id) == id }) else { return }
            togglePocketCall(pocket.id)
            showTapFeedback("Pocket \(id) toggled (remote)")
        case "clearPocket":
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
        default:
            Self.log.info("mirror command ignored: \(String(describing: params), privacy: .public)")
        }
    }

    /// Publish the newest rendered frame + a state snapshot (~1 Hz).
    func publishMirrorFrame(_ jpeg: Data?) {
        guard let server = debugMirror else { return }
        server.update(jpeg: jpeg, stateJSON: mirrorStateJSON())
    }

    private func mirrorStateJSON() -> Data? {
        var state: [String: Any] = [
            "build": AppBuild.json,
            "liveTracking": isLiveTracking,
            "onDeviceDetection": usingOnDeviceDetection,
            "calibrationLocked": calibration.isLocked,
            "designatedCueBall": designatedCueBallID != nil,
            "aimSource": String(describing: aimSource),
            "calledShotOnLine": calledShotOnLine
        ]
        if let calibration = tableCalibration {
            let size = calibration.size
            state["tableSize"] = String(format: "%.2f x %.2f m",
                                        size.playField.width, size.playField.height)
            state["sizeVsStandard"] = calibration.standardSizeComparison.summary
        }
        if let relocalizationSeconds {
            state["relocalizationSeconds"] = (relocalizationSeconds * 10).rounded() / 10
        }
        if let diag = frameDiagnostics {
            state["frameDiag"] = [
                "seen": diag.framesSeen,
                "delivered": diag.framesDelivered,
                "copyFailures": diag.copyFailures,
                "snapshots": diag.snapshotsCompleted,
                "snapshotAvgMs": Int(diag.averageSnapshotMilliseconds),
                "snapshotsInFlight": diag.snapshotsInFlight
            ]
        }
        if let balls = tableState?.balls {
            state["ballCount"] = balls.count
            state["balls"] = balls.map { ball -> [String: Any] in
                ["kind": String(describing: ball.kind),
                 "x": (ball.position.x * 100).rounded() / 100,
                 "y": (ball.position.y * 100).rounded() / 100,
                 "confidence": (ball.confidence * 100).rounded() / 100]
            }
        }
        if let quad = stickQuad {
            // Raw stick footprint (table space) — lets a remote observer
            // debug why StickAim accepts/rejects without the Xcode console.
            state["stickQuad"] = quad.map { [($0.x * 100).rounded() / 100,
                                            ($0.y * 100).rounded() / 100] }
        }
        if let guide = shotGuide {
            state["shotGuide"] = guide.headline
        }
        if !latestDetectionLabels.isEmpty {
            state["rawDetections"] = latestDetectionLabels
        }
        if let pockets = tableState?.table.pockets {
            state["pockets"] = pockets.map { String(describing: $0.id) }
        }
        state["guideSpeed"] = guideSpeed
        state["mode"] = practiceMode.rawValue
        state["settings"] = settingsMirrorState()
        state["hasPrediction"] = shotPrediction != nil
        if let prediction = shotPrediction, !prediction.segments.isEmpty {
            // Predicted path + events in table space — makes bank-line
            // ground truth (T1.1) numerically loggable from the mirror,
            // no eyeballing the rendered frame. Rounded to cm.
            func pt(_ v: Vec2) -> [Double] {
                [(v.x * 100).rounded() / 100, (v.y * 100).rounded() / 100]
            }
            var path = [pt(prediction.segments[0].start)]
            path.append(contentsOf: prediction.segments.map { pt($0.end) })
            var predictionDict: [String: Any] = ["path": path]
            let cushions = prediction.events.compactMap { event -> [Double]? in
                if case .cushion(_, let point) = event { return pt(point) }
                return nil
            }
            if !cushions.isEmpty { predictionDict["cushions"] = cushions }
            if let rest = prediction.events.compactMap({ event -> [Double]? in
                if case .rest(_, let point) = event { return pt(point) }
                return nil
            }).first { predictionDict["rest"] = rest }
            if let pocket = prediction.events.compactMap({ event -> String? in
                if case .pocket(_, let pocket) = event { return String(describing: pocket) }
                return nil
            }).first { predictionDict["pocketed"] = pocket }
            state["prediction"] = predictionDict
        }
        if let calledPocket { state["calledPocket"] = String(describing: calledPocket) }
        if let sessionEvent { state["sessionEvent"] = sessionEvent }
        if let error = previewStats.lastError { state["lastError"] = error }
        if let tapFeedback { state["tapFeedback"] = tapFeedback }
        return try? JSONSerialization.data(withJSONObject: state,
                                           options: [.sortedKeys])
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
        if designatedCueBallID == nearest.id {
            designatedCueBallID = nil
            showTapFeedback("Cue-ball mark cleared")
        } else {
            designatedCueBallID = nearest.id
            showTapFeedback("Marked as cue ball")
        }
        // Re-apply immediately so the HUD/overlays react on this frame
        // instead of waiting for the next pipeline output.
        if let state = tableState {
            tableState = applyingCueDesignation(state)
        }
    }

    /// Apply the cue-ball designation to a pipeline state: the designated
    /// ball becomes .cue; any other .cue claims demote to .unknown so
    /// exactly one cue ball exists.
    private func applyingCueDesignation(_ state: TableState) -> TableState {
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
}
