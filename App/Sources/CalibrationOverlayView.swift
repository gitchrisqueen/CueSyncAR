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

    /// Active handle drag: which corner, plus the finger→handle offset at
    /// grab time. Preserving the offset keeps the corner from snapping
    /// under the fingertip (where the finger would hide it).
    @State private var activeDrag: (index: Int, grabOffset: CGSize)?

    /// Height (world y) of the plane the corners live on — lets raycasts
    /// fall back to pure geometry when ARKit's plane queries miss.
    private var cornerPlaneHeight: Double? {
        let corners = displayCorners
        guard !corners.isEmpty else { return nil }
        return corners.reduce(0) { $0 + $1.y } / Double(corners.count)
    }

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
                guard let world = coordinator.raycastHorizontalPlane(
                    screenPoint: location,
                    fallbackPlaneHeight: cornerPlaneHeight) else { return }
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
                        .fill(.white.opacity(activeDrag?.index == index ? 1 : 0.85))
                        .overlay(Circle().stroke(feltGreen, lineWidth: 2))
                        .frame(width: 30, height: 30)
                        // ≥44pt hit target around the visible 30pt handle.
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .position(point)
                        .gesture(handleDrag(index: index, handleCenter: point))
                        .accessibilityLabel("Corner \(index + 1) handle")
                }
            }
        }
    }

    private func handleDrag(index: Int, handleCenter: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeDrag?.index != index {
                    activeDrag = (index, CGSize(
                        width: handleCenter.x - value.startLocation.x,
                        height: handleCenter.y - value.startLocation.y))
                }
                guard let drag = activeDrag, drag.index == index else { return }
                let target = CGPoint(x: value.location.x + drag.grabOffset.width,
                                     y: value.location.y + drag.grabOffset.height)
                if let world = coordinator.raycastHorizontalPlane(
                    screenPoint: target,
                    fallbackPlaneHeight: cornerPlaneHeight) {
                    model.moveCorner(index: index, to: world)
                }
            }
            .onEnded { _ in
                activeDrag = nil
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
