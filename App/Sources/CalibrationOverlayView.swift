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
    /// The height the corner taps should land on.
    ///
    /// The BALLS decide this, not the corners. It used to be the average Y
    /// of the corners already placed — which is nil for the first tap, so
    /// that one had no reference at all, and every later tap inherited
    /// whatever height the first one happened to land on. One bad first tap
    /// put the whole quad in the air, which is exactly the symptom reported:
    /// the rectangle floating above the cloth, at a fixed world height, from
    /// every camera angle.
    ///
    /// `estimateClothPlane` is derived from balls resting on the actual
    /// cloth and survives `stopLiveTracking`, so it is available throughout
    /// the calibration flow. The corner average stays as a last resort for
    /// a table with no balls on it yet.
    private var cornerPlaneHeight: Double? {
        // The height this flow started with, so every corner lands on ONE
        // plane. Refinement moves them together afterwards.
        if let frozen = model.workingClothHeight { return frozen }
        if let cloth = model.estimateClothPlane()?.height { return cloth }
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
                derivedPockets
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
                // Sighting pockets is a different question being asked of
                // the same taps: "which hole is that", not "where is the
                // corner". The raycast still has to succeed, so the guards
                // below apply either way — but the tap means something else.
                if model.pocketSightingActive {
                    guard coordinator.raycastHorizontalPlane(
                        screenPoint: location,
                        fallbackPlaneHeight: cornerPlaneHeight) != nil else {
                        model.showTapFeedback(model.trackingCondition.missedTapAdvice)
                        return
                    }
                    model.notePocketTap(at: location)
                    return
                }
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
                //
                // It also FREEZES the plane height for the rest of the flow.
                // The ball estimate updates continuously, so taking it fresh
                // on every tap put the four corners on four slightly
                // different planes — a quad that is not flat looks worse
                // from every angle than one uniformly a little wrong, and it
                // cannot be corrected as a whole afterwards.
                if model.pendingCorners.isEmpty {
                    coordinator.placeCalibrationAnchor(at: world)
                    model.setCornerAnchorBase(world)
                    let current = model.currentClothHeight()
                    model.beginCornerPlacement(height: current.height ?? world.y,
                                               source: current.source)
                }
                // Keep the RAY, not just the point: a corner at the wrong
                // depth can only be fixed by re-intersecting its own ray at
                // a better height.
                if let ray = coordinator.worldRay(through: location) {
                    model.recordCornerRay(ray)
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

    /// The table the current corners imply, or nil while they do not make
    /// one. Used to draw the DERIVED pockets back onto the cloth.
    private var candidateCalibration: TableCalibration? {
        let corners = displayCorners
        guard corners.count == 4 else { return nil }
        return try? TableCalibration.fromCorners(
            corners, preferredSize: model.calibration.preferredSize)
    }

    /// Where the solved table says its six pockets are.
    ///
    /// THIS IS THE CHECK THAT MATTERS. Everything downstream — pocket
    /// positions, cushion bounce points, every shot line — is built on this
    /// calibration, and a rigid fit always returns a table whether or not it
    /// is the right one. Drawing the pockets it DERIVES back onto the cloth
    /// lets a person confirm it against holes they can see, using features
    /// they did not tap. If these rings do not sit in the real pockets, the
    /// calibration is wrong, whatever the residual says.
    @ViewBuilder
    private var derivedPockets: some View {
        if let calibration = candidateCalibration {
            let table = Table(size: calibration.size)
            ForEach(table.pockets, id: \.id) { pocket in
                if let screen = coordinator.projectToScreen(
                    calibration.tableToWorld(pocket.position)) {
                    Circle()
                        .strokeBorder(feltGreen, lineWidth: 3)
                        .background(Circle().fill(feltGreen.opacity(0.18)))
                        .frame(width: 34, height: 34)
                        .position(screen)
                        .allowsHitTesting(false)
                }
            }
        }
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
            // What the height is resting on, and what would improve it.
            // An empty table cannot be calibrated well and should say so
            // rather than silently produce a confident wrong answer.
            // Say what the rings are for, or they are just decoration.
            if candidateCalibration != nil {
                Text("Green rings are where it thinks the pockets are — "
                     + "they should sit in the real ones")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
            }
            if let advice = model.heightSource.advice {
                Text(advice)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("calibration-height-advice")
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
            if model.pocketSightingActive { pocketSightingControls }

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

                if !isAdjusting && !model.pocketSightingActive {
                    // The way out of a flow that asks for a line the user
                    // cannot see. On cloth-wrapped cushions the nose is
                    // invisible; a pocket is not.
                    Button("Use pockets", systemImage: "circle.circle") {
                        model.beginPocketSighting()
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("calibration-use-pockets")
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

    /// Name the pocket, then tap it. The user says which hole it is rather
    /// than the app inferring it from position — inferring is what a
    /// confidently wrong table looks like, and a person at the table knows
    /// which hole is which without being told.
    @ViewBuilder
    private var pocketSightingControls: some View {
        let sighted = Set(model.pocketFlow.sightings.map(\.pocket))
        VStack(spacing: 8) {
            Text(model.pocketFlow.prompt)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PocketID.allCases, id: \.self) { pocket in
                        Button(Self.pocketLabel(pocket)) { model.armPocket(pocket) }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(sighted.contains(pocket) ? feltGreen
                                        : (model.armedPocket == pocket ? .white.opacity(0.35)
                                           : .black.opacity(0.35)),
                                        in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 12)
            }

            HUDBar {
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    model.undoPocketSighting()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Undo last pocket")

                Button("Back to corners", systemImage: "xmark") {
                    model.cancelPocketSighting()
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Back to corner taps")

                Button {
                    // Same precedence the corner flow uses: an explicit
                    // Settings override, else the last table this device
                    // locked, else the commonest size.
                    model.commitPocketSighting(
                        size: model.settings.tableSize.override
                            ?? CalibrationStore.loadTableSpec() ?? .eightFoot)
                } label: {
                    Label("Find my table", systemImage: "sparkle.magnifyingglass")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(feltGreen)
                .disabled(!model.pocketFlow.canSolve)
                .accessibilityIdentifier("calibration-find-table")
            }
        }
    }

    /// Pocket names a person would use standing at the table.
    static func pocketLabel(_ pocket: PocketID) -> String {
        switch pocket {
        case .cornerTopLeft: "Top-left"
        case .cornerTopRight: "Top-right"
        case .cornerBottomLeft: "Bottom-left"
        case .cornerBottomRight: "Bottom-right"
        case .sideTop: "Side top"
        case .sideBottom: "Side bottom"
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
