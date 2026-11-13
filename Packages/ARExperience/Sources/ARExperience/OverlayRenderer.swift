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
///
/// The scene is a POOL, not a rebuild. `layout.primitives` is diffed against
/// what is already drawn (`OverlayDiff`): a primitive that is the same thing
/// in nearly the same place is left alone, one that moved gets its transform
/// set, and only a new one or one that looks different is built. Meshes are
/// unit shapes shared by every entity and sized by scale, so no render
/// generates a mesh except the first of each ring radius. A render of a layout
/// that differs from the last only by sub-millimetre jitter touches nothing.
///
/// Content lives in three groups under that root so the suggested shot can
/// cross-fade without disturbing anything else:
///   - `staticGroup`: rings, the live aim, the called pocket.
///   - `heroGroup`: the suggested shot (hero line, pocket ring, target ghost,
///     the ring on the target ball). Updated in place while the suggestion
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
    private static let log = Logger(subsystem: "com.cuesync.ar", category: "overlay")
    /// Design palette for people; the metric palette (opaque, colour-
    /// keyable — see MetricPalette) while a session is being recorded.
    /// Takes effect on the next `render`.
    public var paletteMode: OverlayPaletteMode = .design
    /// The markers of the layout most recently rendered, in placement
    /// order — what a projection snapshot asks `arView.project` about.
    public private(set) var renderedMarkers: [RenderedMarker] = []
    /// What the renders have done to the scene, for the mirror.
    public private(set) var stats = OverlayRenderStats()
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
    /// The entities that pulse when the suggestion changes: the pocket ring
    /// and its casing, scaled together.
    private var pocketRings: [ModelEntity] = []
    private var animationTask: Task<Void, Never>?

    /// One drawn primitive: its entity, and the primitive it was last set to.
    /// A kept primitive keeps its OLD value, so the tolerance is measured
    /// against what is on screen and a slow drift adds up.
    private struct Drawn {
        var entity: ModelEntity
        var primitive: OverlayPrimitive
    }

    private var drawn: [String: Drawn] = [:]
    /// Whether what is drawn was built for the metric palette.
    private var drawnMetric = false
    /// Unit meshes by shape, built once and shared.
    private var meshes: [OverlayPrimitive.Shape: MeshResource] = [:]
    private var failedShapes: Set<OverlayPrimitive.Shape> = []

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
        // position is the one set on it, whichever group holds it.
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

    private func applyLayerOpacity() {
        let value = paletteMode == .metric ? 1 : OverlayStyle.layerOpacity(confidence: overlayOpacity)
        root.components.set(OpacityComponent(opacity: Float(value)))
    }

    // MARK: Meshes and entities

    /// The unit mesh for a shape, built once. A ring that cannot be built is
    /// a marker the player asked for and does not get: that is logged, once
    /// per size, and the ring is left out.
    private func mesh(for shape: OverlayPrimitive.Shape) -> MeshResource? {
        if let cached = meshes[shape] { return cached }
        let built: MeshResource
        switch shape {
        case .box:
            built = MeshResource.generateBox(size: 1)
        case .sphere:
            built = MeshResource.generateSphere(radius: 1)
        case .disc:
            built = MeshResource.generateCylinder(height: 1, radius: 1)
        case let .ring(inner, outer):
            guard !failedShapes.contains(shape) else { return nil }
            let ring = RingMesh(innerRadius: Double(inner) / 1e6, outerRadius: Double(outer) / 1e6)
            var descriptor = MeshDescriptor(name: "ring")
            descriptor.positions = MeshBuffers.Positions(ring.points.map { SIMD3<Float>($0.x, $0.y, $0.z) })
            descriptor.primitives = .triangles(ring.indices)
            do {
                built = try MeshResource.generate(from: [descriptor])
            } catch {
                failedShapes.insert(shape)
                let reason = error.localizedDescription
                let size = "\(inner)-\(outer) um"
                Self.log.error("ring \(size, privacy: .public) failed: \(reason, privacy: .public)")
                return nil
            }
        }
        meshes[shape] = built
        return built
    }

    private func makeEntity(_ primitive: OverlayPrimitive, metric: Bool) -> ModelEntity? {
        guard let mesh = mesh(for: primitive.look.shape) else { return nil }
        var material = UnlitMaterial(color: uiColor(
            from: metric ? MetricPalette.color(for: primitive.look.metricMarker) : primitive.look.colour))
        material.blending = metric ? .opaque
            : .transparent(opacity: .init(floatLiteral: Float(primitive.look.opacity)))
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Put an entity where its primitive says, changing only what differs
    /// from `previous` (everything, for a new entity).
    ///
    /// Positions are in true WORLD space (`setPosition(relativeTo: corrected)`,
    /// nil in the anchored mode), so RealityKit resolves the anchor-local
    /// transform itself — correct for ANY anchor rotation. The old
    /// `world − rootOrigin` shortcut assumed an identity-yaw anchor, which
    /// does not hold after relocalization (the "floating off the cloth after
    /// relaunch" bug). The entity is parented BEFORE this is called, so the
    /// world → local conversion sees the current anchor transform.
    ///
    /// A strip's heading is a yaw about the cloth normal rather than
    /// `simd_quatf(from:to:)`, which is ambiguous for an exactly reversed
    /// direction. It is set in WORLD space too (earlier it was a table-space
    /// heading applied in the anchor's local frame, which pointed every strip
    /// wrong by the table's yaw).
    private func applyTransform(_ entity: ModelEntity, _ primitive: OverlayPrimitive,
                                previous: OverlayPrimitive?, normal: Vec3, normalUp: Bool) {
        entity.setPosition(SIMD3<Float>(Float(primitive.position.x), Float(primitive.position.y),
                                        Float(primitive.position.z)), relativeTo: corrected)
        if previous?.scale != primitive.scale {
            entity.scale = SIMD3<Float>(Float(primitive.scale.x), Float(primitive.scale.y), Float(primitive.scale.z))
        }
        guard let direction = primitive.heading, previous?.heading != direction else { return }
        let d = SIMD3<Float>(Float(direction.x), Float(direction.y), Float(direction.z))
        let n = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        let axis = normalUp ? n : -n
        let reference = SIMD3<Float>(1, 0, 0)
        let yaw = atan2(simd_dot(simd_cross(reference, d), axis), simd_dot(reference, d))
        entity.setOrientation(simd_quatf(angle: yaw, axis: axis), relativeTo: corrected)
    }

    private func group(for primitive: OverlayPrimitive) -> Entity {
        primitive.group == .hero ? heroGroup : staticGroup
    }

    // MARK: Render

    public func render(_ layout: OverlayLayout, planeNormalUp: Bool = true) {
        renderedMarkers = layout.renderedMarkers
        let metric = paletteMode == .metric
        applyLayerOpacity()

        // The palette changed: nothing built for the other one survives.
        if metric != drawnMetric {
            for (_, item) in drawn { item.entity.removeFromParent() }
            drawn.removeAll()
            drawnMetric = metric
        }

        // The suggestion changed: park the old hero for its fade-out and
        // start the new one's. Reduce Motion, and the opaque metric palette
        // of a recording, swap instantly.
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = metric || UIAccessibility.isReduceMotionEnabled
        let suggestionChanged = transition.note(shot: layout.shotID, at: now, reduceMotion: reduceMotion)
        if suggestionChanged {
            outgoingGroup.children.removeAll()
            for child in Array(heroGroup.children) {
                outgoingGroup.addChild(child, preservingWorldTransform: true)
            }
            // Those entities now belong to the fade-out, not to the pool.
            drawn = drawn.filter { $0.value.primitive.group != .hero }
        }

        // The recorder's opaque palette draws no casings.
        let wanted = layout.primitives.filter { !(metric && $0.isCasing) }
        let plan = OverlayDiff.plan(drawn: drawn.mapValues(\.primitive), wanted: wanted)

        for key in plan.remove {
            drawn.removeValue(forKey: key)?.entity.removeFromParent()
        }
        for primitive in plan.build {
            // A primitive that looks different is a new entity at the same key.
            drawn.removeValue(forKey: primitive.key)?.entity.removeFromParent()
            guard let entity = makeEntity(primitive, metric: metric) else { continue }
            group(for: primitive).addChild(entity)
            applyTransform(entity, primitive, previous: nil, normal: layout.planeNormal, normalUp: planeNormalUp)
            drawn[primitive.key] = Drawn(entity: entity, primitive: primitive)
        }
        for primitive in plan.move {
            guard let item = drawn[primitive.key] else { continue }
            applyTransform(item.entity, primitive, previous: item.primitive,
                           normal: layout.planeNormal, normalUp: planeNormalUp)
            drawn[primitive.key] = Drawn(entity: item.entity, primitive: primitive)
        }
        pocketRings = ["hero.pocket", "hero.pocket.casing"].compactMap { drawn[$0]?.entity }
        stats.note(built: plan.build.count, moved: plan.move.count, kept: plan.keep, removed: plan.remove.count)

        if suggestionChanged || !transition.isSettled(at: now) {
            if !applyTransition(), animationTask == nil { startAnimation() }
        }
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
        let pulse = SIMD3<Float>(repeating: Float(transition.ringScale(at: now)))
        for ring in pocketRings { ring.scale = pulse }
        return transition.isSettled(at: now)
    }

    /// Drive the fade at display rate. The session loop ticks every 100 ms,
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
        drawn.removeAll()
        pocketRings = []
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
