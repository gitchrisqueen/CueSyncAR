//
//  ARSessionCoordinator.swift
//  ARExperience
//
//  Tasks M3-01/M3-04 (device layer): owns the ARView, hands out camera
//  frames on demand, implements PlaneRaycasting via ARKit raycast queries,
//  and renders OverlayLayout as RealityKit entities. Compiles only where
//  ARKit exists; all decision logic lives in the pure types (AimEngine,
//  CalibrationController, OverlayLayout) so this file stays a thin,
//  mechanical shell.
//
//  Two hard-won rules encoded here (device-debugged):
//  1. NEVER set ARSession.delegate — RealityKit needs the delegate frame
//     callbacks to render the camera background; stealing them shows a
//     black feed while capture keeps working. Frames are read on demand
//     from session.currentFrame instead (which also means zero pixel-buffer
//     retention — holding ARKit buffers starves the small capture pool).
//  2. Let automaticallyConfigureSession run the session; manual
//     configuration raced it. Plane detection is layered on explicitly
//     when the calibration flow needs it.
//
//  Device verification per playbook rule 6: tracking quality, raycast
//  accuracy, and overlay latency are device-checklist items (M3-06) —
//  compiling here is NOT a claim that they work.
//

import CueSyncCore
import Foundation
import PerceptionKit
import TableSpace

#if canImport(ARKit) && canImport(RealityKit) && os(iOS)
import ARKit
import RealityKit

@MainActor
public final class ARSessionCoordinator {
    public let arView: ARView

    public init() {
        arView = ARView(frame: .zero)
        arView.environment.background = .cameraFeed()
    }

    /// Enable horizontal plane detection on top of RealityKit's automatic
    /// configuration — required by the calibration flow's raycasts (M3-02).
    public func enablePlaneDetection() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
    }

    public func pause() {
        arView.session.pause()
    }

    /// Snapshot the current camera frame, or nil when the session hasn't
    /// produced one yet. The returned CapturedFrame references the frame's
    /// pixel buffer — consume it promptly and drop it.
    public func currentFrame() -> CapturedFrame? {
        guard let frame = arView.session.currentFrame else { return nil }
        let c = frame.camera.transform.columns
        let columns = [c.0, c.1, c.2, c.3].map { v in
            SIMD4<Double>(Double(v.x), Double(v.y), Double(v.z), Double(v.w))
        }
        return CapturedFrame(
            timestamp: frame.timestamp,
            cameraTransform: Transform3D(columns: columns),
            image: PixelBufferImage(pixelBuffer: frame.capturedImage))
    }

    /// Human-readable session health for the HUD; nil when nominal.
    public func sessionHealth() -> String? {
        guard let frame = arView.session.currentFrame else {
            return "Waiting for camera…"
        }
        switch frame.camera.trackingState {
        case .normal:
            return nil
        case .notAvailable:
            return "Tracking unavailable"
        case .limited(let reason):
            return "Tracking limited: \(String(describing: reason))"
        }
    }
}

/// ARKit-backed raycaster: normalized image point → world point on the
/// detected horizontal plane.
@MainActor
public struct ARKitPlaneRaycaster {
    private let arView: ARView

    public init(arView: ARView) {
        self.arView = arView
    }

    public func raycast(imagePoint: Vec2) -> Vec3? {
        let screenPoint = CGPoint(x: imagePoint.x * arView.bounds.width,
                                  y: imagePoint.y * arView.bounds.height)
        guard let result = arView.raycast(from: screenPoint,
                                          allowing: .existingPlaneGeometry,
                                          alignment: .horizontal).first else {
            return nil
        }
        let t = result.worldTransform.columns.3
        return Vec3(Double(t.x), Double(t.y), Double(t.z))
    }
}

/// Renders OverlayLayout as RealityKit entities under a single root anchor.
/// Entities are rebuilt per prediction update; strip/marker counts are small
/// (≤ maxEvents), so churn is negligible.
@MainActor
public final class OverlayRenderer {
    private let root: AnchorEntity
    /// Strip thickness (m) and lift above the cloth to avoid z-fighting.
    private static let stripWidth = 0.008
    private static let stripLift = 0.002

    public init(arView: ARView) {
        root = AnchorEntity(world: matrix_identity_float4x4)
        arView.scene.addAnchor(root)
    }

    public func render(_ layout: OverlayLayout, planeNormalUp: Bool = true) {
        root.children.removeAll()

        for strip in layout.strips {
            let mesh = MeshResource.generateBox(
                width: Float(strip.length),
                height: Float(Self.stripWidth / 2),
                depth: Float(Self.stripWidth))
            var material = UnlitMaterial(color: uiColor(from: strip.color))
            material.blending = .transparent(opacity: .init(floatLiteral: strip.dashed ? 0.7 : 0.95))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = SIMD3<Float>(Float(strip.midpoint.x),
                                           Float(strip.midpoint.y) + Float(Self.stripLift),
                                           Float(strip.midpoint.z))
            entity.orientation = simd_quatf(angle: Float(strip.angle),
                                            axis: SIMD3<Float>(0, planeNormalUp ? 1 : -1, 0))
            root.addChild(entity)
        }

        if let ghost = layout.ghostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: 0.35)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = SIMD3<Float>(Float(ghost.position.x),
                                           Float(ghost.position.y) + Float(ghost.radius),
                                           Float(ghost.position.z))
            root.addChild(entity)
        }

        for pocket in layout.highlightedPockets {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(pocket.radius * 1.2))
            var material = UnlitMaterial(color: uiColor(from: 0x2FA36B))
            material.blending = .transparent(opacity: 0.5)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = SIMD3<Float>(Float(pocket.position.x),
                                           Float(pocket.position.y) + Float(Self.stripLift),
                                           Float(pocket.position.z))
            root.addChild(entity)
        }
    }

    public func clear() {
        root.children.removeAll()
    }

    private func uiColor(from rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
    }
}
#endif
