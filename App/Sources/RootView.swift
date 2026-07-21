//
//  RootView.swift
//  CueSync AR
//
//  Live camera + AR scene with the M0 HUD plus the Detection Preview mode:
//  pick a hosted Roboflow model from the HUD and see its raw detections
//  drawn over the camera with latency stats — the M2-01 model-selection
//  workflow. The full calibration flow and AR overlays land with M3-02/05.
//

import CueSyncCore
import CueSyncUI
import DetectionRoboflow
import SwiftUI
import TableSpace

struct RootView: View {
    @Environment(SessionModel.self) private var model
    @AppStorage("previewBoxRotation") private var boxRotationRaw = NormalizedRotation.clockwise90.rawValue

    private var boxRotation: NormalizedRotation {
        NormalizedRotation(rawValue: boxRotationRaw) ?? .clockwise90
    }

    var body: some View {
        ZStack {
            arSurface
                .ignoresSafeArea()

            if model.selectedModel != nil {
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
                Spacer()
                bottomBar
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var hudStatus: HUDStatus {
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
            calibrateButton
            modelPicker
            if model.selectedModel != nil {
                Text("\(model.previewStats.latencyMilliseconds) ms")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                Button {
                    boxRotationRaw = boxRotation.next.rawValue
                } label: {
                    Label("Rotate boxes", systemImage: "rotate.right")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("Rotate detection boxes")
            }
        }
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
        ARCameraView()
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

    var body: some View {
        ZStack {
            if let coordinator {
                ARViewRepresentable(coordinator: coordinator)
                    .task { await runSessionLoop(coordinator) }
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
        if CalibrationStore.load() != nil {
            coordinator.enablePlaneDetection(
                restoringWorldMapAt: CalibrationStore.hasWorldMap
                    ? CalibrationStore.worldMapURL : nil)
            planeDetectionStarted = true
        }
        while !Task.isCancelled {
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
                // A saved venue relocalized → jump straight to locked.
                if let anchorTransform = coordinator.restoredTableAnchorTransform,
                   let saved = CalibrationStore.load() {
                    model.restoreCalibration(
                        saved.worldCalibration(anchorTransform: anchorTransform))
                }
            }
            if model.wantsPreviewFrame, let frame = await coordinator.nextFrame() {
                model.ingestPreviewFrame(frame)
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

private struct ARViewRepresentable: UIViewRepresentable {
    let coordinator: ARSessionCoordinator

    func makeUIView(context: Context) -> ARView {
        let arView = coordinator.arView
        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = arView.bounds
        arView.addSubview(coaching)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif

#Preview {
    RootView()
        .environment(SessionModel())
}
