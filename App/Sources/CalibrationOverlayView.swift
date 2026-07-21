//
//  CalibrationOverlayView.swift
//  CueSync AR
//
//  M3-02: the on-camera calibration flow UI. Plane search shows the status
//  capsule only; once a plane exists the user taps the four rail corners,
//  adjusts them by dragging the handles, and locks. Corner positions live
//  in world space — the overlay re-projects them to screen every frame, so
//  the rectangle stays glued to the cloth as the phone moves.
//
//  All decisions live in CalibrationController/SessionModel (tested); this
//  view only raycasts taps into world space and renders state.
//

import CueSyncCore
import CueSyncUI
import SwiftUI
import TableSpace

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARExperience

struct CalibrationOverlayView: View {
    @Environment(SessionModel.self) private var model
    let coordinator: ARSessionCoordinator

    private var feltGreen: Color {
        Color(red: Theme.feltGreen.red, green: Theme.feltGreen.green,
              blue: Theme.feltGreen.blue)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            ZStack {
                tapCatcher
                cornerGraphics
            }
        }
        .overlay(alignment: .bottom) {
            controls
                .padding(.bottom, 84)
        }
        .sensoryFeedback(.success, trigger: model.calibration.isLocked)
    }

    // MARK: - Input

    private var tapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard case .planeFound = model.calibration.state else { return }
                guard let world = coordinator.raycastHorizontalPlane(screenPoint: location) else {
                    return
                }
                model.placeCorner(world, planeNormal: coordinator.horizontalPlaneNormal())
            }
    }

    // MARK: - Corner rendering

    /// World-space corners to draw for the current state.
    private var displayCorners: [Vec3] {
        switch model.calibration.state {
        case .adjusting(let corners): corners
        case .planeFound: model.pendingCorners
        default: []
        }
    }

    @ViewBuilder
    private var cornerGraphics: some View {
        let projected = displayCorners.compactMap { coordinator.projectToScreen($0) }
        Canvas { context, _ in
            if case .adjusting = model.calibration.state, projected.count == 4 {
                var outline = Path()
                outline.move(to: projected[0])
                for point in projected.dropFirst() {
                    outline.addLine(to: point)
                }
                outline.closeSubpath()
                context.stroke(outline, with: .color(feltGreen.opacity(0.9)), lineWidth: 2)
            }
            for point in projected {
                let dot = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(feltGreen))
            }
        }
        .allowsHitTesting(false)

        if case .adjusting(let corners) = model.calibration.state {
            ForEach(corners.indices, id: \.self) { index in
                if let point = coordinator.projectToScreen(corners[index]) {
                    Circle()
                        .fill(.white.opacity(0.85))
                        .overlay(Circle().stroke(feltGreen, lineWidth: 2))
                        .frame(width: 30, height: 30)
                        .position(point)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { value in
                                    if let world = coordinator.raycastHorizontalPlane(
                                        screenPoint: value.location) {
                                        model.moveCorner(index: index, to: world)
                                    }
                                }
                        )
                        .accessibilityLabel("Corner \(index + 1) handle")
                }
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let error = model.calibration.lastError {
                Text(Self.message(for: error))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.red)
            }
            HUDBar {
                Button("Cancel", systemImage: "xmark") {
                    model.cancelCalibration()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Cancel calibration")

                if !model.pendingCorners.isEmpty || isAdjusting {
                    Button("Restart corners", systemImage: "arrow.counterclockwise") {
                        model.restartCorners()
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Restart corner placement")
                }

                if isAdjusting {
                    Button {
                        lockTapped()
                    } label: {
                        Label("Lock", systemImage: "lock.fill")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(feltGreen)
                    .accessibilityIdentifier("calibration-lock")
                }
            }
        }
    }

    private var isAdjusting: Bool {
        if case .adjusting = model.calibration.state { return true }
        return false
    }

    private func lockTapped() {
        guard model.requestCalibrationLock(),
              let locked = model.tableCalibration else { return }
        // Anchor the table origin so ARKit stabilizes tracking around it,
        // persist relative to that anchor, and snapshot the world map for
        // instant relocalization on the next visit (best effort — the map
        // may not be ready yet; the calibration itself is already saved).
        let anchorTransform = coordinator.placeTableAnchor(origin: locked.origin)
        model.persistCalibration(locked, anchorTransform: anchorTransform)
        Task {
            try? await coordinator.saveWorldMap(to: CalibrationStore.worldMapURL)
        }
    }

    static func message(for error: CalibrationError) -> String {
        switch error {
        case .needFourCorners:
            "Place all four corners first"
        case .degenerateCorners:
            "Corners don't form a rectangle — drag them and retry"
        case .unrecognizedTableSize(let width, let height):
            String(format: "%.2f × %.2f m isn't a standard table — adjust the corners",
                   width, height)
        }
    }
}
#endif
