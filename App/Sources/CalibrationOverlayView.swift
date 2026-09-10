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

    /// Height of RootView's bottom HUD cluster, measured there and passed
    /// down so these controls can sit clear of it at any size.
    @Environment(\.hudBottomInset) private var hudBottomInset

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

    /// Stable full-screen space shared by projections, taps, and drags.
    /// Gestures MUST resolve in this space, not a handle's local space —
    /// a handle moves while being dragged, and measuring the drag relative
    /// to the moving handle compounds error every update (the white handle
    /// visibly drifted off its green corner).
    private static let space = "calibration-overlay"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            ZStack {
                tapCatcher
                cornerGraphics
            }
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .bottom) {
            controls
                // Clear RootView's bottom HUD, which draws in a LATER
                // sibling of the ZStack and therefore on top of these
                // controls. The height is measured there and published
                // through the environment: the previous hard-coded 84 was a
                // guess that the control bar had already outgrown, so Lock
                // sat underneath the toolbar and could not be tapped.
                .padding(.bottom, hudBottomInset + 16)
        }
        .sensoryFeedback(.success, trigger: model.calibration.isLocked)
    }

    // MARK: - Input

    private var tapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                // Both guards below used to drop the touch in silence, which
                // is the one thing the project forbids — and the second one
                // fires for a REASON the user can act on. While ARKit
                // reports limited tracking it returns nothing from a
                // hit-test at all, so during those seconds a corner tap
                // cannot succeed no matter where it lands. Saying so is the
                // difference between "this app ignores me" and "hold still
                // for a second".
                guard case .planeFound = model.calibration.state else {
                    if model.calibration.isLocked {
                        model.showTapFeedback("Table already set — tap Set up table to redo it")
                    } else {
                        model.showTapFeedback("Looking for the table — point at the cloth and hold still")
                    }
                    return
                }
                guard let world = coordinator.raycastHorizontalPlane(
                    screenPoint: location,
                    fallbackPlaneHeight: cornerPlaneHeight) else {
                    model.showTapFeedback(model.trackingCondition.missedTapAdvice)
                    return
                }
                // First corner drops the shared cluster anchor: all corners
                // rebase against its ARKit-refreshed position so the
                // rectangle stays glued while the device moves.
                if model.pendingCorners.isEmpty {
                    coordinator.placeCalibrationAnchor(at: world)
                    model.setCornerAnchorBase(world)
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

    /// One projection pass per frame, shared by the dots and the handles.
    /// Index-preserving on purpose — see `CalibrationCornerLayout`.
    private var cornerLayout: CalibrationCornerLayout {
        CalibrationCornerLayout(
            points: displayCorners.map { coordinator.projectToScreen($0) })
    }

    @ViewBuilder
    private var cornerGraphics: some View {
        let layout = cornerLayout
        Canvas { context, _ in
            if case .adjusting = model.calibration.state,
               let outlinePoints = layout.closedOutline {
                var outline = Path()
                outline.move(to: outlinePoints[0])
                for point in outlinePoints.dropFirst() {
                    outline.addLine(to: point)
                }
                outline.closeSubpath()
                context.stroke(outline, with: .color(feltGreen.opacity(0.9)), lineWidth: 2)
            }
            for (_, point) in layout.drawable {
                let dot = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(feltGreen))
            }
        }
        .allowsHitTesting(false)

        if case .adjusting(let corners) = model.calibration.state {
            ForEach(corners.indices, id: \.self) { index in
                // Same array, same index as the dot above — so the white
                // handle is drawn from the identical projection the green
                // dot used, not a second independent one.
                if let point = layout.point(at: index) {
                    Circle()
                        .fill(.white.opacity(activeDrag?.index == index ? 1 : 0.85))
                        .overlay(Circle().stroke(feltGreen, lineWidth: 2))
                        .frame(width: 30, height: 30)
                        // ≥44pt hit target around the visible 30pt handle.
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                        .position(point)
                        // The enclosing TimelineView(.animation) drives an
                        // animated transaction every tick. The Canvas above
                        // repaints instantly; a positioned view would
                        // INTERPOLATE toward its new point instead, so the
                        // handles lagged the dots by roughly a frame
                        // whenever the device moved — visible as the white
                        // circle sliding off its green corner. Positions
                        // here are re-derived every frame from world space,
                        // so there is nothing to animate between.
                        .transaction { $0.animation = nil }
                        .gesture(handleDrag(index: index, handleCenter: point))
                        .accessibilityLabel("Corner \(index + 1) handle")
                }
            }
        }
    }

    private func handleDrag(index: Int, handleCenter: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
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
            // Same toast the top of the HUD uses, in the calibration
            // error's own priority tone — but shown HERE, beside the Lock
            // button that produced it, which is where the user is looking.
            if let error = model.calibration.lastError {
                HUDToast(message: HUDMessage(kind: .calibrationError,
                                             text: Self.message(for: error)))
            }
            // Live measured size while adjusting — the user sees what lock
            // WILL record before committing (T1.2 measurement truth).
            if let preview = model.calibrationSizePreview {
                Text(preview)
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityLabel("Measured table size")
            }
            HUDBar {
                Button("Cancel", systemImage: "xmark") {
                    coordinator.removeCalibrationAnchor()
                    model.cancelCalibration()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Cancel calibration")

                if !model.pendingCorners.isEmpty || isAdjusting {
                    Button("Restart corners", systemImage: "arrow.counterclockwise") {
                        coordinator.removeCalibrationAnchor()
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
        coordinator.removeCalibrationAnchor()
        // Anchor the table origin so ARKit stabilizes tracking around it,
        // persist relative to that anchor, and snapshot the world map for
        // instant relocalization on the next visit (best effort — the map
        // may not be ready yet; the calibration itself is already saved).
        let anchorTransform = coordinator.placeTableAnchor(origin: locked.origin)
        model.persistCalibration(locked, anchorTransform: anchorTransform)
        Task {
            // Let ARKit settle after the anchor drop before serializing the
            // world map — getCurrentWorldMap right at lock hitches the
            // session (observed as a frozen camera on device).
            try? await Task.sleep(for: .seconds(3))
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
