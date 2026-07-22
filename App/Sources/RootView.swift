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
    /// Rotation derived from the device's PHYSICAL orientation (fluid —
    /// tracks the free-floating phone via orientation notifications, and
    /// works even when the UI orientation is locked).
    @State private var autoRotation: NormalizedRotation = .clockwise90

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
                StatusCapsule(status: hudStatus)
                if model.cameraDenied {
                    Text("Camera access denied — enable it in Settings → CueSync AR")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.red)
                }
                if let event = model.sessionEvent {
                    Text(event)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.orange)
                }
                if let error = model.previewStats.lastError {
                    Text(error)
                        .font(.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.red)
                }
                if let feedback = model.tapFeedback {
                    Text(feedback)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
                if let mirrorURL = model.debugMirrorURL {
                    Text("Mirror: \(mirrorURL)")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                if model.isLiveTracking, let guide = model.shotGuide {
                    HStack {
                        CueBallGuideView(tipOffset: guide.tipOffset,
                                         headline: guide.headline,
                                         cutAngleDegrees: guide.cutAngleDegrees)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .transition(.opacity)
                }
                bottomBar
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
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

    private var hudStatus: HUDStatus {
        // Live tracking: the pipeline's stabilized ball count — and an
        // explicit prompt when no cue ball is on the table (nothing can be
        // aimed or predicted without it).
        if model.isLiveTracking {
            if model.tableState?.cueBall == nil {
                return .awaitingCueBall
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
        if model.selectedModel != nil {
            return .tracking(ballCount: model.previewStats.detectionCount)
        }
        switch model.phase {
        case .launching: return .launching
        case .findingTable: return .findingTable
        case .ready: return .tracking(ballCount: 0)
        }
    }

    private var bottomBar: some View {
        HUDBar {
            cameraFlipButton
            if !model.usingFrontCamera {
                calibrateButton
            }
            mirrorButton
            modelPicker
            if model.selectedModel != nil {
                Text("\(model.previewStats.latencyMilliseconds) ms")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                Button {
                    rotationTrimRaw = (NormalizedRotation(rawValue: rotationTrimRaw) ?? .none)
                        .next.rawValue
                } label: {
                    Label("Nudge box rotation", systemImage: "rotate.right")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Nudge detection box rotation")
            }
        }
    }

    /// Debug mirror toggle: serves the live screen + tracking state to any
    /// browser on the same Wi-Fi (the iPad usually sits at the table, out
    /// of reach of the Mac and its USB cable).
    private var mirrorButton: some View {
        Button {
            model.toggleDebugMirror()
        } label: {
            Label("Debug mirror",
                  systemImage: model.debugMirrorURL == nil
                      ? "dot.radiowaves.left.and.right"
                      : "dot.radiowaves.left.and.right")
                .labelStyle(.iconOnly)
                .foregroundStyle(model.debugMirrorURL == nil
                                 ? Color.primary : Color.green)
        }
        .accessibilityLabel(model.debugMirrorURL == nil
                            ? "Start debug mirror"
                            : "Stop debug mirror")
        .accessibilityIdentifier("debug-mirror-button")
    }

    /// Toggle between the AR back camera and the plain front-camera
    /// detection preview (AR/calibration are back-camera-only by ARKit
    /// design; the button explains via accessibility label).
    private var cameraFlipButton: some View {
        Button {
            model.usingFrontCamera.toggle()
        } label: {
            Label("Flip camera", systemImage: "arrow.triangle.2.circlepath.camera")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(model.usingFrontCamera
                            ? "Switch to back camera (AR)"
                            : "Switch to front camera (preview only)")
        .accessibilityIdentifier("camera-flip-button")
    }

    /// Enters (or re-enters) the calibration flow; shows the locked table
    /// size once calibrated (tappable to recalibrate — 05-UX-DESIGN).
    private var calibrateButton: some View {
        Button {
            if model.calibrationVisible {
                model.cancelCalibration()
            } else {
                model.beginCalibration()
            }
        } label: {
            if let size = model.tableCalibration?.size {
                Text(Self.sizeBadge(for: size))
                    .font(.footnote.weight(.semibold))
            } else {
                Label("Calibrate", systemImage: "rectangle.dashed")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel(model.tableCalibration == nil
                            ? "Calibrate table"
                            : "Table calibrated — tap to recalibrate")
        .accessibilityIdentifier("calibrate-button")
    }

    static func sizeBadge(for size: TableSize) -> String {
        switch size {
        case .sevenFoot: "7-ft"
        case .eightFoot: "8-ft"
        case .nineFoot: "9-ft"
        case .custom(let width, let height):
            String(format: "%.1f×%.1f m", width, height)
        }
    }

    private var modelPicker: some View {
        Menu {
            Button("Preview off") { model.selectModel(nil) }
            Divider()
            ForEach(DetectionModelCatalog.candidates) { candidate in
                Button {
                    model.selectModel(candidate)
                } label: {
                    if model.selectedModel == candidate {
                        Label(candidate.label, systemImage: "checkmark")
                    } else {
                        Text(candidate.label)
                    }
                }
            }
        } label: {
            Label(model.selectedModel?.label ?? "Model", systemImage: "brain")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityIdentifier("model-picker")
        .disabled(!model.hasRoboflowKey && model.selectedModel == nil)
    }

    @ViewBuilder
    private var arSurface: some View {
        #if targetEnvironment(simulator)
        SimulatorPlaceholderView()
        #else
        if model.usingFrontCamera {
            FrontCameraPreviewView()
        } else {
            ARCameraView()
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
        GeometryReader { proxy in
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
                if model.isLiveTracking, !model.calibrationVisible {
                    PocketCallCatcher(coordinator: coordinator)
                        .ignoresSafeArea()
                }
                if model.calibrationVisible {
                    CalibrationOverlayView(coordinator: coordinator)
                        .ignoresSafeArea()
                }
            } else {
                Color.black
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = ARSessionCoordinator()
            }
        }
    }

    private func runSessionLoop(_ coordinator: ARSessionCoordinator) async {
        guard await ensureCameraAccess() else {
            model.cameraDenied = true
            return
        }
        model.cameraDenied = false
        // RealityKit auto-configures and runs the session itself; plane
        // detection is layered on only when calibration needs it (or a
        // saved venue can be relocalized), so the plain A/B-preview path
        // never reconfigures the session.
        var planeDetectionStarted = false
        var relocalizationDeadline: Date?
        var lastMirrorPublishAt = Date.distantPast
        if CalibrationStore.load() != nil {
            coordinator.enablePlaneDetection(
                restoringWorldMapAt: CalibrationStore.hasWorldMap
                    ? CalibrationStore.worldMapURL : nil)
            planeDetectionStarted = true
            relocalizationDeadline = Date().addingTimeInterval(15)
        }
        while !Task.isCancelled {
            // A stale world map can keep ARKit relocalizing forever
            // (tracking limited, overlays degraded). Give it 15 s, then
            // fall back to fresh tracking — the user can recalibrate.
            if let deadline = relocalizationDeadline, Date() > deadline {
                relocalizationDeadline = nil
                if coordinator.restoredTableAnchorTransform == nil,
                   !model.calibration.isLocked {
                    coordinator.enablePlaneDetection()
                }
            }
            model.sessionEvent = coordinator.sessionEvent
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
                // A saved venue relocalized → jump straight to locked.
                if let anchorTransform = coordinator.restoredTableAnchorTransform,
                   let saved = CalibrationStore.load() {
                    model.restoreCalibration(
                        saved.worldCalibration(anchorTransform: anchorTransform))
                }
            }
            if model.calibration.isLocked {
                // M3-05 live loop: frames → pipeline → TableState; device
                // pose → aim → solver; layout → RealityKit overlays.
                model.startLiveTrackingIfReady()
                if model.isLiveTracking {
                    if let frame = await coordinator.nextFrame() {
                        model.ingestTrackingFrame(frame)
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
                    if let state = model.tableState,
                       let calibration = model.tableCalibration {
                        if let prediction = model.shotPrediction {
                            overlayRenderer?.render(OverlayLayout.compose(
                                state: state, prediction: prediction,
                                calibration: calibration,
                                calledPocket: model.calledPocket))
                        } else {
                            // No shot line yet (usually: no cue ball) —
                            // still render the tracked-ball rings so the
                            // user sees what the app sees and where to
                            // tap to designate the cue ball.
                            overlayRenderer?.render(OverlayLayout.ballsOnly(
                                state: state, calibration: calibration))
                        }
                    } else {
                        overlayRenderer?.clear()
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
            if model.debugMirror != nil,
               Date().timeIntervalSince(lastMirrorPublishAt) >= 1.0 {
                lastMirrorPublishAt = Date()
                let jpeg = await coordinator.snapshotJPEG()
                model.publishMirrorFrame(jpeg)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
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
                guard let calibration = model.tableCalibration else {
                    SessionModel.log.info("tap: ignored — no calibration")
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
                    model.togglePocketCall(best.id)
                    return
                }
                // Not a pocket tap: try cue-ball designation — covers cue
                // balls the detector can't recognize (measle/practice
                // balls with red dots classify as color-ball).
                if let world = coordinator.raycastHorizontalPlane(
                    screenPoint: location,
                    fallbackPlaneHeight: calibration.origin.y) {
                    model.designateCueBall(near: calibration.worldToTable(world))
                } else {
                    SessionModel.log.info("tap: raycast missed the table plane at (\(location.x), \(location.y))")
                    model.showTapFeedback("Couldn't find the table under that tap")
                }
            }
            .accessibilityLabel("Tap a pocket to call it, or a ball to mark it as the cue ball")
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
