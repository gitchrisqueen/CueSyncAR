//
//  RootView.swift
//  CueSync AR
//
//  Live camera + AR scene with the M0 HUD plus the Detection Preview mode:
//  pick a hosted Roboflow model from the HUD and see its raw detections
//  drawn over the camera with latency stats — the M2-01 model-selection
//  workflow. The full calibration flow and AR overlays land with M3-02/05.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import DetectionRoboflow
import SwiftUI
import TableSpace
#if canImport(UIKit)
import UIKit
#endif

struct RootView: View {
    @Environment(SessionModel.self) private var model
    /// Manual trim ON TOP of the orientation-derived rotation, for devices
    /// whose sensor mounting differs. Cycled by the rotate button.
    @AppStorage("previewBoxRotationTrim") private var rotationTrimRaw = NormalizedRotation.none.rawValue
    /// Which sheet is up, if any (05-UX-DESIGN: settings is a sheet, never
    /// a nav stack over the live view). One piece of state rather than two
    /// booleans, because two sheets can never be presented at once and
    /// modelling it as if they could is how a sheet ends up swallowed.
    @State private var sheet: HUDSheet?
    /// Measured height of the bottom HUD cluster, handed to overlays that
    /// draw underneath it (the calibration controls) so they clear it.
    @State private var hudBottomInset: CGFloat = 84
    /// Rotation derived from the device's PHYSICAL orientation (fluid —
    /// tracks the free-floating phone via orientation notifications, and
    /// works even when the UI orientation is locked).
    @State private var autoRotation: NormalizedRotation = .clockwise90

    /// The sheets the HUD can raise.
    enum HUDSheet: String, Identifiable {
        case more
        case settings

        var id: String { rawValue }
    }

    private var boxRotation: NormalizedRotation {
        autoRotation.combined(with: NormalizedRotation(rawValue: rotationTrimRaw) ?? .none)
    }

    /// Camera sensor is landscape-native (buffer upright with the home
    /// indicator on the right). Nil for faceUp/faceDown/unknown — keep the
    /// last known rotation rather than guessing. Confirm per device
    /// checklist (needs-device-run).
    static func rotation(for orientation: UIDeviceOrientation) -> NormalizedRotation? {
        switch orientation {
        case .portrait: .clockwise90
        case .portraitUpsideDown: .counterClockwise90
        // Fully qualified: a bare `.none` in this Optional return context
        // resolves to Optional.none (nil), silently breaking landscape.
        case .landscapeLeft: NormalizedRotation.none
        case .landscapeRight: .half
        default: nil
        }
    }

    var body: some View {
        ZStack {
            arSurface
                .ignoresSafeArea()

            // 2D box overlay only while NOT live tracking — once the table
            // is locked and the pipeline runs, balls render as spatial
            // overlays on the cloth instead.
            if model.selectedModel != nil, !model.isLiveTracking {
                DetectionPreviewOverlay(detections: model.latestDetections,
                                        rotation: boxRotation)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack {
                // Exactly three slots, in this order, forever: the status
                // capsule never moves, an active recording is always
                // unmistakable, and everything else competes for ONE toast
                // (HUDMessage decides which). What used to stack here and
                // where it went: `sessionEvent` -> HUDStatus.degraded and
                // the mirror's /state.json; `previewStats.lastError` and
                // the mirror URL -> the More sheet's developer section
                // (the URL is also selectable in Settings -> Developer).
                StatusCapsule(status: hudStatus)
                if let recording = model.recordingStatus {
                    RecordingBadge(status: recording)
                }
                if let message = hudMessage {
                    HUDToast(message: message)
                }
                Spacer()
                ShotAdviceCluster()
                VStack {
                    HUDControlBar { sheet = .more }
                    // Bottom-most, under the control bar: always answers
                    // "which build is this?" without a cable, and sits below
                    // the table in frame so it never occludes the cloth
                    // during play.
                    if DeveloperMode.shared.isUnlocked {
                        BuildBadge(identity: AppBuild.identity)
                    }
                }
                .measuringHUDBottomInset()
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        // Non-consuming on purpose (simultaneousGesture): it observes
        // every tap that reaches the root WITHOUT stealing it from the HUD
        // buttons or the AR catchers below.
        .simultaneousGesture(TapGesture().onEnded { model.noteRootTap() })
        // RootView owns the status decision tree; the model owns what the
        // mirror publishes. Pushed on change (never written during a body
        // evaluation) so a browser can read the HUD.
        .onChange(of: hudStatus, initial: true) { _, status in
            model.noteHUDStatus(status)
        }
        .onPreferenceChange(HUDBottomInsetKey.self) { height in
            // + the VStack's own bottom padding: the calibration controls
            // must clear the whole cluster, not just its content box.
            hudBottomInset = height + 12
        }
        .environment(\.hudBottomInset, hudBottomInset)
        .sheet(item: $sheet) { which in
            switch which {
            case .more:
                // Raising Settings from inside More would be a sheet over a
                // sheet; More closes itself and hands the choice back here.
                MoreSheet(onOpenSettings: { sheet = .settings })
            case .settings:
                SettingsView()
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            autoRotation = Self.rotation(for: UIDevice.current.orientation) ?? autoRotation
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
            if let rotation = Self.rotation(for: UIDevice.current.orientation) {
                autoRotation = rotation
            }
        }
    }

    /// The one transient line under the capsule. RootView contributes the
    /// fields; `HUDMessage` (pure, tested on Linux) decides which of them
    /// gets the slot. The calibration error is deliberately NOT fed from
    /// here: the calibration overlay shows it beside the Lock button that
    /// produced it, which is where the user is already looking.
    private var hudMessage: HUDMessage? {
        HUDMessage.resolve(
            cameraDenied: model.cameraDenied,
            tapFeedback: model.tapFeedback,
            modeHint: model.isLiveTracking
                ? model.practiceMode.pendingHint(hasCalledPocket: model.calledPocket != nil)
                : nil)
    }

    private var hudStatus: HUDStatus {
        // Live tracking: the pipeline's stabilized ball count — and an
        // explicit prompt when no cue ball is on the table (nothing can be
        // aimed or predicted without it).
        if model.isLiveTracking {
            // Degraded tracking outranks everything below: a guide drawn on
            // a table ARKit has lost is worse than saying so. Which reason
            // maps to which sentence is decided (and tested) in
            // CueSyncUI.TrackingCondition, not here.
            if let reason = model.trackingCondition.degradedReason {
                return .degraded(reason: reason)
            }
            if model.tableState?.cueBall == nil {
                return .awaitingCueBall
            }
            // Below the cue-ball prompt and ARKit's own troubles, above
            // the reassuring ball count: "Tracking 3 balls" is true and
            // useless when the app saw seven a minute ago, because the
            // player cannot tell it from a table with three balls left.
            if case .thin(let seen, let peak, let dark) = model.detectionVerdict {
                return .losingBalls(seen: seen, peak: peak, dark: dark)
            }
            if model.calledShotOnLine {
                return .onLine
            }
            return .tracking(ballCount: model.tableState?.balls.count ?? 0)
        }
        // The calibration flow owns the capsule while it's on screen.
        if model.calibrationVisible, !model.calibration.isLocked {
            switch model.calibration.state {
            case .searchingPlane: return .findingTable
            case .planeFound: return .placingCorners(placed: model.pendingCorners.count)
            case .adjusting: return .confirmingRails
            case .locked: return .tracking(ballCount: 0)
            }
        }
        // A detector is loaded and firing, but with no calibrated table
        // the pipeline is not running and PlayingSurfaceGate has no
        // surface to gate against — so these boxes land on floor tiles,
        // window frames and furniture. Reporting that count as
        // "Tracking N balls" told the player the app was working when it
        // was not, and counted things that are neither balls nor on the
        // table.
        if model.selectedModel != nil {
            return .needsCalibration(seeing: model.previewStats.detectionCount)
        }
        switch model.phase {
        case .launching: return .launching
        case .findingTable: return .findingTable
        }
    }

    /// Kept here beside `hudStatus` because both answer "what does the
    /// player see about the table right now"; the bar itself moved to
    /// HUDControlBar.swift.
    static func sizeBadge(for size: TableSize) -> String {
        switch size {
        case .sevenFoot: "7-ft"
        case .eightFoot: "8-ft"
        case .nineFoot: "9-ft"
        case .custom(let width, let height):
            String(format: "%.1f×%.1f m", width, height)
        }
    }

    @ViewBuilder
    private var arSurface: some View {
        #if targetEnvironment(simulator)
        SimulatorPlaceholderView()
        #else
        // ARCameraView stays mounted in BOTH modes. Swapping it out for the
        // front preview destroyed its ARView — and with it the world origin
        // every calibration corner is expressed in — so flipping to the
        // front camera and back moved all four corners (reported from the
        // table, 2026-09-08). It now hands the camera over instead: the
        // session pauses, the front preview draws on top, and resuming
        // re-runs the same configuration so ARKit relocalizes into the
        // original origin.
        ZStack {
            ARCameraView()
            if model.usingFrontCamera {
                FrontCameraPreviewView()
            }
        }
        #endif
    }
}

/// Draws detector bounding boxes over the camera. Coordinates arrive in raw
/// camera-image space; NormalizedRotation + aspect-fill mapping place them.
struct DetectionPreviewOverlay: View {
    let detections: [Detection2D]
    let rotation: NormalizedRotation

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                for detection in detections {
                    let rotated = rotation.apply(detection.boundingBox)
                    // Camera buffers are 4:3; dimensions swap with rotation.
                    let (iw, ih) = rotation.swapsDimensions ? (3.0, 4.0) : (4.0, 3.0)
                    let r = AspectFillMapping.mapRect(rotated,
                                                      imageWidth: iw, imageHeight: ih,
                                                      viewWidth: size.width,
                                                      viewHeight: size.height)
                    let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
                    let style = Theme.ballStyle(for: detection.ballKind)
                    let color = Color(red: style.fill.red, green: style.fill.green,
                                      blue: style.fill.blue)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 4),
                                   with: .color(color), lineWidth: 2)
                    let caption = Text("\(detection.classLabel) \(Int(detection.confidence * 100))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                    context.draw(caption, at: CGPoint(x: rect.midX, y: rect.minY - 8))
                }
            }
        }
    }
}

/// Shown on the Simulator, where ARKit cannot run.
struct SimulatorPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(red: Theme.feltGreen.red,
                  green: Theme.feltGreen.green,
                  blue: Theme.feltGreen.blue)
                .opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "arkit")
                    .font(.system(size: 44))
                Text("AR requires a physical device")
                    .font(.headline)
                Text("Run on an iPhone to see the table.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARExperience
import ARKit
import AVFoundation
import RealityKit

/// Hosts the shared ARSessionCoordinator's ARView and drives the pull-based
/// preview loop: a camera frame is only requested (and its buffer only
/// touched) when the model actually wants one — retaining ARKit frames
/// starves the capture pipeline.
struct ARCameraView: View {
    @Environment(SessionModel.self) private var model
    /// Created once in `onAppear`, NOT via `@State`'s inline initializer:
    /// that autoclosure re-runs on every enclosing body evaluation (~2 Hz
    /// while the Detection Preview streams stats), and each run built and
    /// discarded a whole ARView + ARSession — dozens of CAMetalLayers and
    /// camera clients. The churn exhausted Metal drawable allocation and
    /// kept the real session interrupted (black feed, Fig errors).
    @State private var coordinator: ARSessionCoordinator?
    /// RealityKit renderer for M3-05 spatial overlays (paths, ghost ball,
    /// pocket glow). Created lazily once live tracking begins.
    @State private var overlayRenderer: OverlayRenderer?

    var body: some View {
        ZStack {
            if let coordinator {
                ARViewRepresentable(coordinator: coordinator)
                    .task { await runSessionLoop(coordinator) }
                // Hidden, not unmounted, while the front preview owns the
                // camera: unmounting is what used to lose the world origin.
                    .opacity(model.usingFrontCamera ? 0 : 1)
                    // Nothing here needs RealityKit's own gestures — every
                    // interaction goes through the SwiftUI overlays above,
                    // which raycast via the coordinator themselves. Stated
                    // as intent, NOT as a fix: taps were never being eaten
                    // here. They were dead because `isLiveTracking` was
                    // invisible to Observation, so the catcher was never
                    // mounted at all (see SessionModel.isLiveTracking).
                    .allowsHitTesting(false)
                if !model.usingFrontCamera {
                    if model.isLiveTracking, !model.calibrationVisible {
                        PocketCallCatcher(coordinator: coordinator)
                            .ignoresSafeArea()
                    }
                    // Nothing tracked and no calibration in progress: the
                    // camera area is otherwise inert, so let it be the way
                    // in rather than requiring an unlabelled icon.
                    if !model.isLiveTracking, !model.calibrationVisible {
                        CalibrationInviteCatcher()
                            .ignoresSafeArea()
                    }
                    if model.calibrationVisible {
                        CalibrationOverlayView(coordinator: coordinator)
                            .ignoresSafeArea()
                    }
                }
            } else {
                Color.black
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = ARSessionCoordinator()
                // So mirror commands can raycast a screen point the way a
                // finger does (SessionModel+Calibration).
                model.arCoordinator = coordinator
            }
        }
        .onChange(of: model.usingFrontCamera) { _, isFront in
            guard let coordinator else { return }
            if isFront {
                coordinator.suspendForCameraHandoff()
            } else {
                coordinator.resumeFromCameraHandoff()
            }
        }
    }

    private func runSessionLoop(_ coordinator: ARSessionCoordinator) async {
        guard await ensureCameraAccess() else {
            model.cameraDenied = true
            return
        }
        model.cameraDenied = false
        // Session recording borrows two things from this layer: the
        // per-frame side channel (anchor pose, display transform) and the
        // viewport; both read lock boxes, so the recorder can call them
        // from its own actor.
        model.recordingHooks = RecordingHooks(
            sideChannel: { [coordinator] timestamp in coordinator.deliveredFrameMeta(at: timestamp) },
            viewport: { [coordinator] in coordinator.currentViewport })
        // RealityKit auto-configures and runs the session itself; plane
        // detection is layered on only when calibration needs it (or a
        // saved venue can be relocalized), so the plain A/B-preview path
        // never reconfigures the session.
        var planeDetectionStarted = false
        var relocalizationDeadline: Date?
        var lastMirrorPublishAt = Date.distantPast
        // Re-rendering an identical layout every tick churns RealityKit
        // entities for nothing (and can flicker) — render only on change.
        var lastRenderedLayout: OverlayLayout?
        if CalibrationStore.load() != nil {
            coordinator.enablePlaneDetection(
                restoringWorldMapAt: CalibrationStore.hasWorldMap
                    ? CalibrationStore.worldMapURL : nil)
            planeDetectionStarted = true
            relocalizationDeadline = Date().addingTimeInterval(15)
            model.markRelocalizationStart()
        }
        var lastDiagnosticsAt = Date.distantPast
        var lastSnapshotAt = Date.distantPast
        while !Task.isCancelled {
            // A suspended session never delivers a frame, so `nextFrame()`
            // would await forever and the loop would stop servicing
            // everything below it. Idle here until the camera comes back.
            if coordinator.isSuspendedForCameraHandoff {
                try? await Task.sleep(for: .milliseconds(SessionModel.loopTickMilliseconds))
                continue
            }
            coordinator.refreshViewportInfo()
            // A stale world map can keep ARKit relocalizing forever
            // (tracking limited, overlays degraded). Give it 15 s, then
            // fall back to fresh tracking — the user can recalibrate.
            if let deadline = relocalizationDeadline, Date() > deadline {
                relocalizationDeadline = nil
                if coordinator.restoredTableAnchorTransform == nil,
                   !model.calibration.isLocked {
                    model.markRelocalizationTimeout()
                    coordinator.enablePlaneDetection()
                }
            }
            // T1.4: publish frame-flow counters at 0.2 Hz (mirror + log).
            if Date().timeIntervalSince(lastDiagnosticsAt) >= 5 {
                lastDiagnosticsAt = Date()
                model.updateFrameDiagnostics(coordinator.frameDiagnostics())
            }
            model.sessionEvent = coordinator.sessionEvent
            model.trackingCondition = coordinator.trackingCondition
            if model.calibrationVisible, !planeDetectionStarted {
                coordinator.enablePlaneDetection()
                planeDetectionStarted = true
            }
            if !model.calibration.isLocked {
                // Feed plane availability into the flow's state machine.
                if model.calibrationVisible, coordinator.planeAvailable,
                   case .searchingPlane = model.calibration.state {
                    model.calibrationPlaneDetected()
                }
                // Rebase tapped corners by the cluster anchor's refined
                // position so they track ARKit's map corrections.
                if model.calibrationVisible,
                   let anchorPosition = coordinator.calibrationAnchorPosition {
                    model.rebaseCorners(clusterAnchorAt: anchorPosition)
                }
                // Tighten to the balls as more of them are seen. Rebasing
                // above only tracks the ANCHOR's drift; this corrects the
                // PLANE, which is what puts each corner at the right depth
                // and stops the quad sliding when the device moves.
                model.refineCalibrationHeightIfBetter()
                // A saved venue relocalized → jump straight to locked.
                if let anchorTransform = coordinator.restoredTableAnchorTransform,
                   let saved = CalibrationStore.load() {
                    model.restoreCalibration(
                        saved.worldCalibration(anchorTransform: anchorTransform),
                        anchorTransform: anchorTransform)
                }
            }
            if model.calibration.isLocked {
                // M3-05 live loop: frames → pipeline → TableState; device
                // pose → aim → solver; layout → RealityKit overlays.
                model.startLiveTrackingIfReady()
                if model.isLiveTracking {
                    if let frame = await coordinator.nextFrame() {
                        // The anchor transform is sampled WITH the frame so
                        // the pipeline projects it in the world frame ARKit
                        // is using right now (B3 anchor following). Taken
                        // from the frame's own side channel — the value the
                        // session recorder writes — so live and replay see
                        // the same transform for the same frame; the
                        // current-frame lookup is the fallback only.
                        let anchorTransform: Transform3D?
                        if let delivered = coordinator.deliveredFrameMeta(at: frame.timestamp) {
                            anchorTransform = delivered.tableAnchorTransform
                        } else {
                            anchorTransform = coordinator.currentTableAnchorTransform
                        }
                        model.ingestTrackingFrame(frame, tableAnchorTransform: anchorTransform)
                    }
                    if let cameraTransform = coordinator.currentCameraTransform {
                        model.updateAim(cameraTransform: cameraTransform)
                    }
                    if overlayRenderer == nil {
                        // Root the overlays under the table's ARAnchor so
                        // ARKit's refinements carry them (drift fix).
                        overlayRenderer = OverlayRenderer(
                            arView: coordinator.arView,
                            tableAnchor: coordinator.tableAnchor)
                    }
                    if syncPalette(model.overlayPaletteMode) {
                        lastRenderedLayout = nil // re-render in the new palette now
                    }
                    renderOverlays(lastRendered: &lastRenderedLayout)
                    if model.isRecording {
                        lastSnapshotAt = await recordingTick(coordinator, lastSnapshotAt: lastSnapshotAt)
                    }
                }
            } else {
                // Unlocked (e.g. recalibrating): tear the renderer down —
                // its root anchor is gone; a fresh one attaches at next lock.
                if overlayRenderer != nil {
                    overlayRenderer?.clear()
                    overlayRenderer = nil
                }
                if model.wantsPreviewFrame,
                   let frame = await coordinator.nextFrame() {
                    model.ingestPreviewFrame(frame)
                }
            }
            // Debug mirror: ship the rendered screen (camera + overlays)
            // to any browser on the LAN at ~1 Hz while enabled.
            if model.debugMirror != nil {
                if Date().timeIntervalSince(lastMirrorPublishAt) >= 1.0 {
                    lastMirrorPublishAt = Date()
                    let jpeg = await coordinator.snapshotJPEG()
                    model.publishMirrorFrame(jpeg)
                } else {
                    // State refreshes at pipeline cadence (frames stay 1 Hz):
                    // mid-shot ball positions land in /state.json at ~4-6 Hz,
                    // enough to reconstruct a rolled path for T1.1.
                    model.publishMirrorFrame(nil)
                }
            }
            try? await Task.sleep(for: .milliseconds(SessionModel.loopTickMilliseconds))
        }
    }

    /// Compose this tick's overlay layout from the model and render it
    /// only when it differs from the last one (re-rendering an identical
    /// layout churns RealityKit entities and can flicker).
    private func renderOverlays(lastRendered: inout OverlayLayout?) {
        guard let state = model.tableState, let calibration = model.tableCalibration else {
            if lastRendered != nil {
                lastRendered = nil
                overlayRenderer?.clear()
            }
            return
        }
        let layout: OverlayLayout
        if !model.showsShotGuides {
            // A game with friends: rings so the app is visibly awake and
            // keeping score, but no aim line. This is the branch that gives
            // `ModeConfiguration.showsShotGuides` its first consumer — every
            // PracticeMode sets it true, so it has never read false before.
            layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: nil)
        } else if let prediction = model.shotPrediction {
            layout = OverlayLayout.compose(state: state, prediction: prediction,
                                           calibration: calibration,
                                           calledPocket: model.calledPocket,
                                           target: model.targetOverlay)
        } else {
            // No shot line yet (usually: no cue ball, or the cue is not
            // being aimed) — still render the tracked-ball rings so the
            // user sees what the app sees, AND the recommended shot, which
            // is most useful precisely when they are not yet down on it.
            layout = OverlayLayout.ballsOnly(state: state, calibration: calibration,
                                             target: model.targetOverlay)
        }
        if layout != lastRendered {
            lastRendered = layout
            overlayRenderer?.render(layout)
        }
    }

    /// Recording flips overlays to the metric palette (and back). Returns
    /// true when the renderer's palette changed.
    private func syncPalette(_ mode: OverlayPaletteMode) -> Bool {
        guard let renderer = overlayRenderer, renderer.paletteMode != mode else { return false }
        renderer.paletteMode = mode
        return true
    }

    /// One loop tick while recording: HUD numbers + cap/error enforcement,
    /// then the ~1 Hz bracketed projection snapshot of whatever the
    /// renderer last placed. Returns when the last snapshot was taken.
    private func recordingTick(_ coordinator: ARSessionCoordinator,
                               lastSnapshotAt: Date) async -> Date {
        await model.refreshRecordingStatus()
        guard model.isRecording,
              Date().timeIntervalSince(lastSnapshotAt) >= SessionRecorder.snapshotInterval,
              let renderer = overlayRenderer,
              let projection = coordinator.projectionSnapshot(
                  markers: renderer.renderedMarkers, paletteMode: renderer.paletteMode) else {
            return lastSnapshotAt
        }
        await model.recordProjectionSnapshot(projection)
        return Date()
    }

    private func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

/// Invisible tap layer during live tracking: tap near a pocket to call it,
/// tap it again to clear (M6-02). The called pocket rings amber; the ring
/// turns felt green when the prediction is on line into it.
private struct PocketCallCatcher: View {
    @Environment(SessionModel.self) private var model
    let coordinator: ARSessionCoordinator

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                // FIRST, before any guard: proves the tap reached this
                // handler at all. Without it a swallowed tap and a tap
                // that never arrived look identical from the mirror.
                model.noteRawTap(kind: "tap", x: location.x, y: location.y)
                guard let calibration = model.tableCalibration else {
                    SessionModel.log.info("tap: ignored — no calibration")
                    model.showTapFeedback("Tap ignored — table not calibrated")
                    return
                }
                guard let table = model.tableState?.table else {
                    SessionModel.log.info("tap: ignored — no pipeline state yet (detector not producing frames?)")
                    model.showTapFeedback("Still waiting for ball tracking to start…")
                    return
                }
                var best: (id: PocketID, distance: CGFloat)?
                for pocket in table.pockets {
                    let world = calibration.tableToWorld(pocket.position)
                    guard let point = coordinator.projectToScreen(world) else { continue }
                    let distance = hypot(point.x - location.x, point.y - location.y)
                    if distance <= 50, distance < (best?.distance ?? .infinity) {
                        best = (pocket.id, distance)
                    }
                }
                if let best {
                    let wasCalled = model.calledPocket == best.id
                    model.togglePocketCall(best.id)
                    let action = wasCalled ? "cleared" : "called"
                    let summary = "pocket \(best.id) \(action)"
                    SessionModel.log.info("tap: \(summary, privacy: .public)")
                    model.showTapFeedback(wasCalled ? "Pocket call cleared"
                                          : "Pocket called — sink a ball there")
                    return
                }
                // Not a pocket tap. A tap on the cloth means one of two
                // things, and which one is decided by what is already
                // known rather than by a mode the player has to remember:
                //
                //   no cue ball yet          -> the tap designates it,
                //                               because targeting is
                //                               meaningless without one
                //   tapped the cue ball      -> toggle its designation
                //                               (the measle-ball escape
                //                               hatch, unchanged)
                //   tapped any other ball    -> shoot at that one
                if let world = coordinator.raycastHorizontalPlane(
                    screenPoint: location,
                    fallbackPlaneHeight: calibration.origin.y) {
                    let tablePoint = calibration.worldToTable(world)
                    if model.tableState?.cueBall == nil
                        || model.tapIsOnTheCueBall(near: tablePoint)
                        || !model.selectTarget(near: tablePoint) {
                        model.designateCueBall(near: tablePoint)
                    }
                } else {
                    SessionModel.log.info("tap: raycast missed the table plane at (\(location.x), \(location.y))")
                    model.showTapFeedback("Couldn't find the table under that tap")
                }
            }
            .onLongPressGesture(minimumDuration: 0.8) {
                model.noteRawTap(kind: "longpress", x: 0, y: 0)
                model.resetBallTracking()
            }
            .accessibilityLabel("""
                Tap a pocket to call it, or a ball to shoot at it; tap the \
                cue ball to mark or unmark it; long-press to reset ball \
                tracking
                """)
            // Proves the catcher is genuinely in the view tree, not merely
            // that the condition which should mount it is true.
            .onAppear { model.setTapCatcherMounted(true) }
            .onDisappear { model.setTapCatcherMounted(false) }
    }
}

private struct ARViewRepresentable: UIViewRepresentable {
    let coordinator: ARSessionCoordinator

    func makeUIView(context: Context) -> ARView {
        // No ARCoachingOverlayView: it auto-reactivates on every tracking
        // dip ("Move iPhone to start" nagging over the live feed). Our
        // status capsule already gives one-line instructions, per the
        // 05-UX-DESIGN "every wait state has a live preview and one line".
        coordinator.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif

#Preview {
    RootView()
        .environment(SessionModel())
}
