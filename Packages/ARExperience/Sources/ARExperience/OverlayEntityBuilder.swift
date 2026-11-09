//
//  OverlayEntityBuilder.swift
//  ARExperience
//
//  Turns an OverlayLayout into RealityKit entities under ANY root entity.
//  Needs only RealityKit (iOS and macOS), not ARKit, so the same entity
//  construction runs on device (OverlayRenderer, under an AnchorEntity) and
//  offscreen on macOS (Tools/OverlayRender, under a plain Entity in a
//  RealityRenderer). OverlayRenderer delegates here; the geometry, colours
//  and opacities below are what the device renders.
//

#if canImport(RealityKit)
import CueSyncCore
import Foundation
import RealityKit
import simd

@MainActor
public enum OverlayEntityBuilder {
    /// Strip thickness (m) and lift above the cloth to avoid z-fighting.
    static let stripWidth = 0.008
    static let stripLift = 0.002

    /// Replaces the root's children with entities for `layout`.
    public static func populate(root: Entity, layout: OverlayLayout,
                                planeNormalUp: Bool = true) {
        root.children.removeAll()

        // Tracked-ball rings first (visually lowest): flat rings on the
        // cloth at each tracked ball, the cue ball's filled + white so the
        // user always sees which ball the app treats as the cue — and can
        // see where to tap when designating one manually.
        for ball in layout.balls {
            let ringRadius = max(ball.radius * 1.35, 0.03)
            let mesh = MeshResource.generateCylinder(
                height: Float(stripWidth / 2),
                radius: Float(ringRadius))
            let color: SimpleMaterial.Color = ball.isCue ? .white : color(from: 0xF5A623)
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: ball.isCue ? 0.9 : 0.45)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(ball.position, lift: stripLift))
        }

        for strip in layout.strips {
            let mesh = MeshResource.generateBox(
                width: Float(strip.length),
                height: Float(stripWidth / 2),
                depth: Float(stripWidth))
            var material = UnlitMaterial(color: color(from: strip.color))
            material.blending = .transparent(opacity: .init(floatLiteral: strip.dashed ? 0.7 : 0.95))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(strip.midpoint, lift: stripLift))
            // Orientation stays LOCAL to the anchor (not relativeTo: nil):
            // strip.angle is a TABLE-space heading, and the table anchor
            // rotates with the table, so the anchor's yaw carries the strip
            // to the correct world heading after relocalization. Setting a
            // world-space yaw here would drop that yaw and under-rotate
            // strips post-reloc. (Local == world at fresh lock, where this
            // already rendered correctly.)
            entity.orientation = simd_quatf(angle: Float(strip.angle),
                                            axis: SIMD3<Float>(0, planeNormalUp ? 1 : -1, 0))
        }

        if let ghost = layout.ghostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: 0.35)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(ghost.position, lift: ghost.radius))
        }

        for pocket in layout.highlightedPockets {
            let mesh = MeshResource.generateCylinder(height: Float(stripWidth / 2),
                                                     radius: Float(pocket.radius * 1.2))
            var material = UnlitMaterial(color: color(from: 0x2FA36B))
            material.blending = .transparent(opacity: 0.5)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(pocket.position, lift: stripLift))
        }

        if let suggestion = layout.suggestion {
            addSuggestion(suggestion, to: root, planeNormalUp: planeNormalUp)
        }

        // Called pocket (M6-02): amber ring while aiming, felt green when
        // the prediction is on line into it.
        if let called = layout.calledPocket {
            let mesh = MeshResource.generateCylinder(height: Float(stripWidth / 2),
                                                     radius: Float(called.radius))
            let rgb: UInt32 = layout.calledPocketSatisfied ? 0x2FA36B : 0xF5A623
            var material = UnlitMaterial(color: color(from: rgb))
            material.blending = .transparent(
                opacity: layout.calledPocketSatisfied ? 0.85 : 0.6)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(called.position, lift: stripLift * 2))
        }
    }

    /// Arcade-style advised shot: each line is a wide faint "glow" strip
    /// under a thin bright core, so it reads as neon over the cloth; the
    /// ghost ball, target ring and pocket disc share the difficulty colour.
    private static func addSuggestion(_ suggestion: OverlayLayout.Suggestion,
                                      to root: Entity, planeNormalUp: Bool) {
        let tint = color(from: suggestion.color)

        func addStrip(_ strip: OverlayLayout.Strip, width: Double,
                      opacity: Double, lift: Double) {
            let mesh = MeshResource.generateBox(width: Float(strip.length),
                                                height: Float(stripWidth / 2),
                                                depth: Float(width))
            var material = UnlitMaterial(color: tint)
            material.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(strip.midpoint, lift: lift))
            // Same anchor-local heading rule as the prediction strips.
            entity.orientation = simd_quatf(angle: Float(strip.angle),
                                            axis: SIMD3<Float>(0, planeNormalUp ? 1 : -1, 0))
        }

        let lift = stripLift * 3
        addStrip(suggestion.aimStrip, width: stripWidth * 4,
                 opacity: 0.14, lift: lift)
        addStrip(suggestion.aimStrip, width: stripWidth * 2.2,
                 opacity: 0.25, lift: lift * 1.1)
        addStrip(suggestion.aimStrip, width: stripWidth,
                 opacity: 0.95, lift: lift * 1.2)
        addStrip(suggestion.objectStrip, width: stripWidth * 3,
                 opacity: 0.14, lift: lift)
        addStrip(suggestion.objectStrip, width: stripWidth * 0.9,
                 opacity: 0.75, lift: lift * 1.2)

        func addDisc(_ marker: OverlayLayout.Marker, opacity: Double, lift: Double) {
            let mesh = MeshResource.generateCylinder(height: Float(stripWidth / 2),
                                                     radius: Float(marker.radius))
            var material = UnlitMaterial(color: tint)
            material.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, in: root, at: worldPoint(marker.position, lift: lift))
        }
        addDisc(suggestion.target, opacity: 0.35, lift: lift)
        addDisc(suggestion.pocket, opacity: 0.55, lift: lift)

        let ghostMesh = MeshResource.generateSphere(radius: Float(suggestion.ghost.radius))
        var ghostMaterial = UnlitMaterial(color: tint)
        ghostMaterial.blending = .transparent(opacity: 0.4)
        let ghost = ModelEntity(mesh: ghostMesh, materials: [ghostMaterial])
        place(ghost, in: root, at: worldPoint(suggestion.ghost.position,
                                              lift: suggestion.ghost.radius))
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
    private static func worldPoint(_ world: Vec3, lift: Double) -> SIMD3<Float> {
        SIMD3<Float>(Float(world.x), Float(world.y + lift), Float(world.z))
    }

    /// Parent to the root, THEN set the world position — parenting first
    /// lets RealityKit resolve world→root-local against the current root
    /// transform.
    private static func place(_ entity: ModelEntity, in root: Entity,
                              at world: SIMD3<Float>) {
        root.addChild(entity)
        entity.setPosition(world, relativeTo: nil)
    }

    /// 0xRRGGBB token → platform colour (UIColor on iOS, NSColor on macOS).
    static func color(from rgb: UInt32) -> SimpleMaterial.Color {
        SimpleMaterial.Color(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                             green: CGFloat((rgb >> 8) & 0xFF) / 255,
                             blue: CGFloat(rgb & 0xFF) / 255,
                             alpha: 1)
    }
}
#endif
