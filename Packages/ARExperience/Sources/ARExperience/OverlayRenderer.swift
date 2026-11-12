//
//  OverlayRenderer.swift
//  ARExperience
//
//  Turns an OverlayLayout into RealityKit entities under the table anchor,
//  and applies HeroTransition's cross-fade and pulse. Compiles only where
//  ARKit and RealityKit exist (device); every decision it applies is made by
//  the pure types (OverlayLayout, OverlayStyle, HeroTransition, RingMesh),
//  which the Linux tests cover. What it looks like is a device check.
//

import CueSyncCore
import Foundation
import TableSpace

#if canImport(ARKit) && canImport(RealityKit) && os(iOS)
import ARKit
import RealityKit
import UIKit
import os

/// Renders OverlayLayout as RealityKit entities under a single root anchor.
/// Entities are rebuilt per prediction update; strip/marker counts are small
/// (≤ maxEvents), so churn is negligible.
///
/// Content lives in three groups under that root so the suggested shot can
/// cross-fade without disturbing anything else:
///   - `staticGroup`: rings, the live aim, the called pocket. Rebuilt on
///     every layout change.
///   - `heroGroup`: the suggested shot (hero line, pocket ring, target ghost,
///     the ring on the target ball). Rebuilt in place while the suggestion
///     is the same, retired to `outgoingGroup` when it changes.
///   - `outgoingGroup`: the previous suggestion, fading out.
/// The timing is `HeroTransition`'s; this class only applies it.
@MainActor
public final class OverlayRenderer {
    private let root: AnchorEntity
    /// Parked-hold mode: content hangs off this entity, whose WORLD
    /// transform is the hold's correction, so layout points (in the
    /// corrected world) render where ARKit's drifted camera sees the cloth.
    /// Nil in the normal anchored mode.
    private let corrected: Entity?
    /// Whether this renderer was built for the parked-hold corrected world.
    public var isWorldCorrected: Bool { corrected != nil }
    /// Strip thickness (m) and lift above the cloth to avoid z-fighting.
    private static let stripWidth = 0.008
    private static let stripLift = 0.002
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "overlay")
    /// Design palette for people; the metric palette (opaque, colour-
    /// keyable — see MetricPalette) while a session is being recorded.
    /// Takes effect on the next `render`.
    public var paletteMode: OverlayPaletteMode = .design
    /// The markers of the layout most recently rendered, in placement
    /// order — what a projection snapshot asks `arView.project` about.
    public private(set) var renderedMarkers: [RenderedMarker] = []
    /// How much of the overlay layer shows, 0...1 (`HUDStatus.overlayOpacity`:
    /// 05-UX-DESIGN "confidence honesty"). Applied to the whole layer, so a
    /// guide on a table ARKit has lost fades instead of staying at full
    /// strength. Ignored while recording, where the metric palette must stay
    /// opaque to be colour-keyable.
    public var overlayOpacity: Double = 1 {
        didSet { if overlayOpacity != oldValue { applyLayerOpacity() } }
    }

    private let staticGroup = Entity()
    private let heroGroup = Entity()
    private let outgoingGroup = Entity()
    /// When the suggested shot last changed, and what the cross-fade and the
    /// pocket pulse should look like right now.
    private var transition = HeroTransition()
    private var pocketRing: ModelEntity?
    private var animationTask: Task<Void, Never>?
    /// Ring meshes by (inner, outer) radius in micrometres: the same few
    /// sizes are needed on every render.
    private var ringMeshes: [RingKey: MeshResource] = [:]
    private var failedRings: Set<RingKey> = []

    private struct RingKey: Hashable {
        var inner: Int
        var outer: Int
    }

    /// Everything a ring needs: its radii (m), colour token, opacity, and the
    /// colour it takes in the metric palette.
    private struct RingStyle {
        var inner: Double
        var outer: Double
        var color: UInt32
        var opacity: Double
        var metricMarker: MetricPalette.Marker
    }

    /// Root under the table's ARAnchor when one exists — anchored content
    /// follows ARKit's refinements; identity-world content drifts (anchor
    /// best practice). Falls back to a world-fixed root without one.
    public init(arView: ARView, tableAnchor: ARAnchor? = nil, worldCorrected: Bool = false) {
        if let tableAnchor, !worldCorrected {
            root = AnchorEntity(anchor: tableAnchor)
        } else {
            root = AnchorEntity(world: matrix_identity_float4x4)
        }
        if worldCorrected {
            let frame = Entity()
            root.addChild(frame)
            corrected = frame
        } else {
            corrected = nil
        }
        // The groups carry no transform of their own, so a child's world
        // position is the one `place` set, whichever group holds it.
        for group in [staticGroup, heroGroup, outgoingGroup] {
            (corrected ?? root).addChild(group)
        }
        arView.scene.addAnchor(root)
    }

    /// Parked hold: set the corrected frame's world transform (the hold's
    /// correction, corrected world -> ARKit world). Call every tick; cheap.
    public func applyWorldCorrection(_ correction: Transform3D) {
        guard let corrected else { return }
        let c = correction.columns
        let matrix = simd_float4x4(columns: (
            SIMD4<Float>(Float(c[0].x), Float(c[0].y), Float(c[0].z), Float(c[0].w)),
            SIMD4<Float>(Float(c[1].x), Float(c[1].y), Float(c[1].z), Float(c[1].w)),
            SIMD4<Float>(Float(c[2].x), Float(c[2].y), Float(c[2].z), Float(c[2].w)),
            SIMD4<Float>(Float(c[3].x), Float(c[3].y), Float(c[3].z), Float(c[3].w))))
        corrected.setTransformMatrix(matrix, relativeTo: nil)
    }

    /// A layout world point lifted off the cloth. Entities are positioned in
    /// true WORLD space (`setPosition(relativeTo: nil)`), so RealityKit
    /// resolves the anchor-local transform itself — correct for ANY anchor
    /// rotation. The old `world − rootOrigin` translation shortcut assumed
    /// the anchor had identity yaw; that holds at a fresh corner-lock but
    /// NOT after relocalization, where the restored anchor carries the
    /// session's arbitrary yaw and RealityKit re-applied it to every child,
    /// rotating the whole overlay about the table center (the "floating off
    /// the cloth after relaunch" bug).
    private func worldPoint(_ world: Vec3, lift: Double) -> SIMD3<Float> {
        SIMD3<Float>(Float(world.x), Float(world.y + lift), Float(world.z))
    }

    /// Parent to a group under the anchored root, THEN set the world
    /// position — parenting first lets RealityKit resolve world→anchor-local
    /// against the current anchor transform.
    private func place(_ entity: Entity, at world: SIMD3<Float>, in group: Entity) {
        // Parked hold: positions are in the corrected world, i.e. relative
        // to the corrected frame entity.
        group.addChild(entity)
        entity.setPosition(world, relativeTo: corrected)
    }

    private func applyLayerOpacity() {
        let value = paletteMode == .metric ? 1 : OverlayStyle.layerOpacity(confidence: overlayOpacity)
        root.components.set(OpacityComponent(opacity: Float(value)))
    }

    /// A flat ring around `position`: the shape every marker on the cloth
    /// uses now, in place of the filled discs that covered the balls.
    private func ringEntity(_ style: RingStyle, metric: Bool) -> ModelEntity? {
        guard let mesh = ringMesh(inner: style.inner, outer: style.outer) else { return nil }
        var material = UnlitMaterial(color: uiColor(
            from: metric ? MetricPalette.color(for: style.metricMarker) : style.color))
        material.blending = metric ? .opaque
            : .transparent(opacity: .init(floatLiteral: Float(style.opacity)))
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private func ringMesh(inner: Double, outer: Double) -> MeshResource? {
        let key = RingKey(inner: Int((inner * 1e6).rounded()), outer: Int((outer * 1e6).rounded()))
        if let cached = ringMeshes[key] { return cached }
        let ring = RingMesh(innerRadius: inner, outerRadius: outer)
        var descriptor = MeshDescriptor(name: "ring")
        descriptor.positions = MeshBuffers.Positions(ring.points.map { SIMD3<Float>($0.x, $0.y, $0.z) })
        descriptor.primitives = .triangles(ring.indices)
        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            ringMeshes[key] = mesh
            return mesh
        } catch {
            // A ring that cannot be built is a marker the player asked for
            // and does not get: say so, once per size.
            if failedRings.insert(key).inserted {
                let reason = error.localizedDescription
                Self.log.error("ring \(inner, privacy: .public)-\(outer, privacy: .public) m failed: \(reason, privacy: .public)")
            }
            return nil
        }
    }

    public func render(_ layout: OverlayLayout, planeNormalUp: Bool = true) {
        staticGroup.children.removeAll()
        renderedMarkers = layout.renderedMarkers
        let metric = paletteMode == .metric
        applyLayerOpacity()

        // The suggestion changed: park the old hero for its fade-out and
        // start the new one's. Reduce Motion, and the opaque metric palette
        // of a recording, swap instantly.
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = metric || UIAccessibility.isReduceMotionEnabled
        if transition.note(shot: layout.shotID, at: now, reduceMotion: reduceMotion) {
            outgoingGroup.children.removeAll()
            for child in Array(heroGroup.children) {
                outgoingGroup.addChild(child, preservingWorldTransform: true)
            }
        }
        heroGroup.children.removeAll()
        pocketRing = nil

        // Rings, never plates: a thin ring that starts outside the ball's
        // footprint and covers nothing. While a shot is suggested the layout
        // carries only the cue ball and the target ball; with none, every
        // tracked ball, so tap-to-designate has something to aim at. White
        // is the cue ball's, green the target's (OverlayStyle).
        for ball in layout.balls {
            let radii = OverlayStyle.ballRing(ballRadius: ball.radius)
            let involved = ball.isCue || ball.isTarget
            let color = ball.isCue ? OverlayStyle.cueRingColor
                : ball.isTarget ? OverlayStyle.targetRingColor : OverlayStyle.ballRingColor
            let style = RingStyle(
                inner: radii.inner, outer: radii.outer, color: color,
                opacity: involved ? OverlayStyle.involvedRingOpacity : OverlayStyle.ballRingOpacity,
                metricMarker: ball.isCue ? .cueBall : ball.isTarget ? .pocket : .ball)
            guard let entity = ringEntity(style, metric: metric) else { continue }
            place(entity, at: worldPoint(ball.position, lift: Self.stripLift),
                  in: ball.isTarget ? heroGroup : staticGroup)
        }

        // Three weights (OverlayStyle): the recommended shot is the hero,
        // the thickest and fully opaque; the live aim and the cue ball
        // after contact are thinner and dimmer. The hero is drawn last so
        // it is never buried under the lines it crosses.
        func renderStrips(_ strips: [OverlayLayout.Strip], in group: Entity) {
            for strip in strips {
                let tier = OverlayStyle.tier(role: strip.role, dashed: strip.dashed)
                let width = OverlayStyle.width(tier)
                let mesh = MeshResource.generateBox(
                    width: Float(strip.length),
                    height: Float(width / 2),
                    depth: Float(width))
                let stripColor = metric
                    ? MetricPalette.color(for: MetricPalette.stripMarker(forDesignColor: strip.color))
                    : strip.color
                var material = UnlitMaterial(color: uiColor(from: stripColor))
                let opacity = Float(OverlayStyle.opacity(tier))
                material.blending = metric ? .opaque
                    : .transparent(opacity: .init(floatLiteral: opacity))
                let entity = ModelEntity(mesh: mesh, materials: [material])
                place(entity, at: worldPoint(strip.midpoint, lift: OverlayStyle.lift(tier)), in: group)
                // Orientation in WORLD space, the same frame as the position
                // set by `place` above.
                //
                // This previously took a TABLE-space heading and applied it
                // about the anchor's local Y, on the belief that the table
                // anchor "rotates with the table". It does not: placeTableAnchor
                // builds it from matrix_identity_float4x4 plus a translation,
                // so its rotation is identity and nothing mapped table axes to
                // world axes. Every strip therefore pointed the wrong way by
                // the table's yaw — a right angle on a table whose long axis
                // ran along world +z — while its midpoint stayed correct. It is
                // also what made mid-session anchor rotation spin the strips
                // about their own midpoints: position was world, orientation
                // was local. Both are world now.
                //
                // Yaw about the cloth normal rather than simd_quatf(from:to:),
                // which is ambiguous for an exactly-reversed direction.
                if let direction = strip.direction {
                    let d = SIMD3<Float>(Float(direction.x), Float(direction.y),
                                         Float(direction.z))
                    let n = SIMD3<Float>(Float(layout.planeNormal.x),
                                         Float(layout.planeNormal.y),
                                         Float(layout.planeNormal.z))
                    let axis = planeNormalUp ? n : -n
                    let reference = SIMD3<Float>(1, 0, 0)
                    let yaw = atan2(simd_dot(simd_cross(reference, d), axis),
                                    simd_dot(reference, d))
                    entity.setOrientation(simd_quatf(angle: yaw, axis: axis),
                                          relativeTo: corrected)
                }
            }
        }

        renderStrips(layout.strips, in: staticGroup)
        renderStrips(layout.targetStrips, in: heroGroup)

        if let ghost = layout.ghostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: metric
                ? uiColor(from: MetricPalette.color(for: .ghostBall)) : .white)
            material.blending = metric ? .opaque : .transparent(opacity: 0.35)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(ghost.position, lift: ghost.radius), in: staticGroup)
        }

        // Pockets the live aim ends in: a quiet ring at the capture radius,
        // not the filled disc that spilled over the rail.
        for pocket in layout.highlightedPockets {
            let radii = OverlayStyle.pocketRing(captureRadius: pocket.radius)
            let style = RingStyle(inner: radii.inner, outer: radii.outer,
                                  color: OverlayStyle.pocketRingColor, opacity: 0.5,
                                  metricMarker: .pocket)
            guard let entity = ringEntity(style, metric: metric) else { continue }
            place(entity, at: worldPoint(pocket.position, lift: Self.stripLift), in: staticGroup)
        }

        // Called pocket (M6-02): amber ring while aiming, felt green when
        // the prediction is on line into it.
        if let called = layout.calledPocket {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(called.radius))
            let satisfied = layout.calledPocketSatisfied
            let color: UInt32 = metric
                ? MetricPalette.color(for: satisfied ? .calledPocketOnLine : .calledPocket)
                : (satisfied ? 0x2FA36B : 0xF5A623)
            var material = UnlitMaterial(color: uiColor(from: color))
            material.blending = metric ? .opaque : .transparent(opacity: satisfied ? 0.85 : 0.6)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(called.position, lift: Self.stripLift * 2), in: staticGroup)
        }

        // The pocket the shot is going into, and where the cue ball has to
        // arrive to send the ball there. The ball being shot at has its ring
        // above (it is in `balls`). The pocket gets a ring at the capture
        // radius centred on the pocket, which is where the hero line ends.
        if let pocket = layout.targetPocket {
            let radii = OverlayStyle.pocketRing(captureRadius: pocket.radius)
            let style = RingStyle(inner: radii.inner, outer: radii.outer,
                                  color: OverlayStyle.pocketRingColor,
                                  opacity: OverlayStyle.pocketRingOpacity, metricMarker: .pocket)
            if let entity = ringEntity(style, metric: metric) {
                place(entity, at: worldPoint(pocket.position, lift: Self.stripLift * 1.6), in: heroGroup)
                pocketRing = entity
            }
        }
        if let ghost = layout.targetGhostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: metric
                ? uiColor(from: MetricPalette.color(for: .ghostBall))
                : uiColor(from: OverlayStyle.shotColor))
            material.blending = metric ? .opaque
                : .transparent(opacity: .init(floatLiteral: Float(OverlayStyle.targetGhostOpacity)))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(ghost.position, lift: ghost.radius), in: heroGroup)
        }

        if !applyTransition(), animationTask == nil { startAnimation() }
    }

    /// Apply the cross-fade and the pulse for this instant. Returns true
    /// once everything has settled.
    @discardableResult
    private func applyTransition() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        heroGroup.components.set(OpacityComponent(opacity: Float(transition.incomingOpacity(at: now))))
        let outgoing = transition.outgoingOpacity(at: now)
        outgoingGroup.components.set(OpacityComponent(opacity: Float(outgoing)))
        if outgoing <= 0, !outgoingGroup.children.isEmpty { outgoingGroup.children.removeAll() }
        pocketRing?.scale = SIMD3<Float>(repeating: Float(transition.ringScale(at: now)))
        return transition.isSettled(at: now)
    }

    /// Drive the fade at display rate. The session loop ticks every 150 ms,
    /// far too coarse for a 250 ms fade, so the animation has its own timer
    /// and stops the moment it has settled.
    private func startAnimation() {
        animationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if self.applyTransition() {
                    self.animationTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    public func clear() {
        animationTask?.cancel()
        animationTask = nil
        for group in [staticGroup, heroGroup, outgoingGroup] { group.children.removeAll() }
        pocketRing = nil
        transition = HeroTransition()
        renderedMarkers = []
    }

    private func uiColor(from rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
    }
}
#endif
