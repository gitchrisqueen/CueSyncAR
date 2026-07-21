//
//  ARSessionCoordinator.swift
//  ARExperience
//
//  Tasks M3-01/M3-04 (device layer): owns the ARSession, hands out camera
//  frames on demand, implements PlaneRaycasting via ARKit raycast queries,
//  and renders OverlayLayout as RealityKit entities. Compiles only where
//  ARKit exists; all decision logic lives in the pure types (AimEngine,
//  CalibrationController, OverlayLayout) so this file stays a thin,
//  mechanical shell.
//
//  Frame delivery is PULL-based (nextFrame()), not a push stream: ARKit's
//  camera buffer pool is small, and retaining pixel buffers — even one
//  sitting in a stream buffer — stalls capture (black screen, Fig capture
//  errors, Metal drawable allocation failures). With the pull model a
//  buffer is only referenced while a consumer is actively using it; every
//  other frame is dropped inside the delegate callback untouched. The one
//  frame that IS handed out carries a deep copy of the pixel buffer, so no
//  consumer can pin an ARKit pool buffer past this callback.
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
public final class ARSessionCoordinator: NSObject, ARSessionDelegate {
    public let arView: ARView
    private let pendingRequest = FrameRequestBox()
    /// Human-readable session health (errors, interruptions, tracking
    /// limits) for the HUD. Nil when everything is nominal.
    public private(set) var sessionEvent: String?

    public override init() {
        // RealityKit owns session configuration (automaticallyConfigureSession
        // defaults to true): its auto-config path is what reliably wires the
        // camera background. Taking it over manually rendered black.
        arView = ARView(frame: .zero)
        arView.environment.background = .cameraFeed()
        super.init()
        arView.session.delegate = self
    }

    /// Enable horizontal plane detection on top of RealityKit's automatic
    /// configuration — required by the calibration flow's raycasts. Safe to
    /// call once the view is on screen; it reconfigures without restarting
    /// the camera.
    public func enablePlaneDetection() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
    }

    public func pause() {
        pendingRequest.take()?.resume(returning: nil)
        arView.session.pause()
    }

    /// Await the next camera frame. Returns nil if the awaiting task is
    /// cancelled or the session pauses first. One outstanding request at a
    /// time — callers are expected to be a single polling loop.
    public func nextFrame() async -> CapturedFrame? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let stale = pendingRequest.swap(continuation) {
                    stale.resume(returning: nil)
                }
            }
        } onCancel: {
            self.pendingRequest.take()?.resume(returning: nil)
        }
    }

    // MARK: - ARSessionDelegate

    public nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // No pending request → drop the frame without touching its buffers.
        guard let continuation = pendingRequest.take() else { return }
        let transform = Transform3D(columns: (0..<4).map { column in
            let c = frame.camera.transform.columns
            let v = [c.0, c.1, c.2, c.3][column]
            return SIMD4<Double>(Double(v.x), Double(v.y), Double(v.z), Double(v.w))
        })
        // Hand consumers a DEEP COPY of the camera pixel buffer, never the
        // ARKit-owned one: anything downstream that outlives this callback
        // (JPEG encode, CIContext texture caches) would otherwise pin one of
        // ARKit's few pool buffers — "delegate is retaining N ARFrames"
        // warnings, then a stopped camera. Copy cost is trivial at the
        // preview's ≤2 Hz pull rate.
        guard let copiedBuffer = Self.copyPixelBuffer(frame.capturedImage) else {
            continuation.resume(returning: nil)
            return
        }
        let captured = CapturedFrame(
            timestamp: frame.timestamp,
            cameraTransform: transform,
            image: PixelBufferImage(pixelBuffer: copiedBuffer))
        continuation.resume(returning: captured)
    }

    /// Byte-for-byte copy of a pixel buffer into freshly allocated storage.
    /// Handles planar (ARKit's bi-planar YUV) and packed formats.
    private nonisolated static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault,
                            CVPixelBufferGetWidth(source),
                            CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source),
                            attributes,
                            &created)
        guard let copy = created else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else {
                    return nil
                }
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                let rowBytes = min(srcBytesPerRow, dstBytesPerRow)
                for row in 0..<height {
                    memcpy(dst + row * dstBytesPerRow, src + row * srcBytesPerRow, rowBytes)
                }
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(copy) else {
                return nil
            }
            let height = CVPixelBufferGetHeight(source)
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(copy)
            let rowBytes = min(srcBytesPerRow, dstBytesPerRow)
            for row in 0..<height {
                memcpy(dst + row * dstBytesPerRow, src + row * srcBytesPerRow, rowBytes)
            }
        }
        return copy
    }

    public nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        report("AR session failed: \(error.localizedDescription)")
    }

    public nonisolated func sessionWasInterrupted(_ session: ARSession) {
        report("AR session interrupted")
    }

    public nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        report(nil)
    }

    public nonisolated func session(_ session: ARSession,
                                    cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            report(nil)
        case .notAvailable:
            report("Tracking unavailable")
        case .limited(let reason):
            report("Tracking limited: \(String(describing: reason))")
        }
    }

    private nonisolated func report(_ message: String?) {
        Task { @MainActor in
            self.sessionEvent = message
        }
    }
}

/// Lock-protected hand-off slot for the single outstanding frame request.
/// Accessed from the main actor (request side) and ARKit's session queue
/// (fulfillment side).
private final class FrameRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CapturedFrame?, Never>?

    func swap(_ new: CheckedContinuation<CapturedFrame?, Never>)
    -> CheckedContinuation<CapturedFrame?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let old = continuation
        continuation = new
        return old
    }

    func take() -> CheckedContinuation<CapturedFrame?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
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
