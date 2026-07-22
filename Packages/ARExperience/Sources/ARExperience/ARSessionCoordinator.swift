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
    /// Name of the world anchor the locked table calibration hangs off.
    public nonisolated static let tableAnchorName = "cuesync.tableOrigin"

    public let arView: ARView
    private let pendingRequest = FrameRequestBox()
    /// Human-readable session health (errors, interruptions, tracking
    /// limits) for the HUD. Nil when everything is nominal.
    public private(set) var sessionEvent: String?
    /// True once ARKit has detected at least one horizontal plane —
    /// drives CalibrationController's planeDetected event.
    public private(set) var planeAvailable = false
    /// Set when a previously saved table anchor relocalizes in this
    /// session (its transform in *this* session's world coordinates).
    /// The app layer combines it with a persisted AnchoredCalibration.
    public private(set) var restoredTableAnchorTransform: Transform3D?
    /// The live table ARAnchor (placed at lock or restored) — overlay
    /// content roots under it so ARKit's map refinements carry the
    /// overlays along instead of leaving them at stale world coordinates.
    public private(set) var tableAnchor: ARAnchor?
    /// One shared anchor for the pre-lock corner cluster (anchor best
    /// practice: reuse a single anchor for nearby content). Tapped corners
    /// rebase against its ARKit-refreshed position so the rectangle stays
    /// glued to the cloth while the device moves mid-calibration.
    public private(set) var calibrationAnchor: ARAnchor?

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
    /// the camera. Pass a saved world map to attempt relocalization of a
    /// previously calibrated venue (the table anchor comes back through
    /// `restoredTableAnchorTransform` when ARKit re-recognizes the space).
    public func enablePlaneDetection(restoringWorldMapAt url: URL? = nil) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .automatic
        if let url,
           let data = try? Data(contentsOf: url),
           let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self,
                                                             from: data) {
            configuration.initialWorldMap = map
        }
        arView.session.run(configuration)
    }

    // MARK: - Calibration support (raycast, projection, anchoring)

    /// Raycast a screen point onto a horizontal plane. Uses the INFINITE
    /// extension of detected planes first — corner placement and handle
    /// drags must not be limited to the patch of plane ARKit happens to
    /// have mapped (rail corners often sit outside it). Falls back to
    /// estimated planes, then to a pure geometric intersection with the
    /// horizontal plane at `fallbackPlaneHeight` (world y, meters) so a
    /// drag over feature-poor cloth never dead-zones once corners exist.
    public func raycastHorizontalPlane(screenPoint: CGPoint,
                                       fallbackPlaneHeight: Double? = nil) -> Vec3? {
        let queries: [ARRaycastQuery.Target] = [.existingPlaneInfinite, .estimatedPlane]
        for target in queries {
            if let hit = arView.raycast(from: screenPoint, allowing: target,
                                        alignment: .horizontal).first {
                let t = hit.worldTransform.columns.3
                return Vec3(Double(t.x), Double(t.y), Double(t.z))
            }
        }
        guard let fallbackPlaneHeight,
              let ray = arView.ray(through: screenPoint) else { return nil }
        let origin = Vec3(Double(ray.origin.x), Double(ray.origin.y),
                          Double(ray.origin.z))
        let direction = Vec3(Double(ray.direction.x), Double(ray.direction.y),
                             Double(ray.direction.z))
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (fallbackPlaneHeight - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    /// The up-normal of the raycast plane at a world point — for MVP
    /// horizontal planes this is world up; kept as a seam for angled
    /// surfaces later.
    public func horizontalPlaneNormal() -> Vec3 { Vec3(0, 1, 0) }

    /// Project a world point into the ARView's screen space (nil when the
    /// point is behind the camera).
    public func projectToScreen(_ world: Vec3) -> CGPoint? {
        arView.project(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
    }

    /// Drop the named world anchor for a locked calibration at the table
    /// origin, replacing any previous one. Returns the anchor's transform
    /// for AnchoredCalibration bookkeeping.
    @discardableResult
    public func placeTableAnchor(origin: Vec3) -> Transform3D {
        for anchor in arView.session.currentFrame?.anchors ?? []
        where anchor.name == Self.tableAnchorName {
            arView.session.remove(anchor: anchor)
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(Float(origin.x), Float(origin.y),
                                           Float(origin.z), 1)
        let anchor = ARAnchor(name: Self.tableAnchorName, transform: transform)
        arView.session.add(anchor: anchor)
        tableAnchor = anchor
        return Self.transform3D(from: transform)
    }

    // MARK: - Calibration cluster anchor (pre-lock corner stability)

    /// Drop the shared calibration anchor at the first tapped corner.
    public func placeCalibrationAnchor(at world: Vec3) {
        removeCalibrationAnchor()
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(Float(world.x), Float(world.y),
                                           Float(world.z), 1)
        let anchor = ARAnchor(name: "cuesync.calibrationCluster",
                              transform: transform)
        arView.session.add(anchor: anchor)
        calibrationAnchor = anchor
    }

    public func removeCalibrationAnchor() {
        if let calibrationAnchor {
            arView.session.remove(anchor: calibrationAnchor)
        }
        calibrationAnchor = nil
    }

    /// The cluster anchor's CURRENT position — ARKit updates anchors as it
    /// refines the map; reading through currentFrame picks that up.
    public var calibrationAnchorPosition: Vec3? {
        guard let id = calibrationAnchor?.identifier,
              let anchor = arView.session.currentFrame?.anchors
                .first(where: { $0.identifier == id }) else { return nil }
        let t = anchor.transform.columns.3
        return Vec3(Double(t.x), Double(t.y), Double(t.z))
    }

    /// Serialize the current world map (async — ARKit assembles it) so the
    /// venue relocalizes instantly on the next visit. Throws when the map
    /// isn't available yet (insufficient mapping); callers may retry later.
    public func saveWorldMap(to url: URL) async throws {
        // Archive inside the callback so only Sendable Data crosses the
        // continuation (ARWorldMap itself is not Sendable).
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            arView.session.getCurrentWorldMap { map, error in
                guard let map else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                do {
                    let archived = try NSKeyedArchiver.archivedData(
                        withRootObject: map, requiringSecureCoding: true)
                    continuation.resume(returning: archived)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    nonisolated static func transform3D(from m: simd_float4x4) -> Transform3D {
        Transform3D(columns: (0..<4).map { column in
            let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3][column]
            return SIMD4<Double>(Double(c.x), Double(c.y), Double(c.z), Double(c.w))
        })
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
        // Intrinsics travel with the frame so consumers (pipeline raycasts)
        // can unproject image points without touching ARKit.
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let intrinsics = CameraIntrinsics(
            focalX: Double(k.columns.0.x), focalY: Double(k.columns.1.y),
            principalX: Double(k.columns.2.x), principalY: Double(k.columns.2.y),
            imageWidth: Double(resolution.width), imageHeight: Double(resolution.height))
        let captured = CapturedFrame(
            timestamp: frame.timestamp,
            cameraTransform: transform,
            image: PixelBufferImage(pixelBuffer: copiedBuffer),
            intrinsics: intrinsics)
        continuation.resume(returning: captured)
    }

    /// The camera's current pose (camera-to-world), for aim derivation at
    /// UI cadence without pulling a full frame.
    public var currentCameraTransform: Transform3D? {
        guard let transform = arView.session.currentFrame?.camera.transform else {
            return nil
        }
        return Self.transform3D(from: transform)
    }

    /// Byte-for-byte copy of a pixel buffer into freshly allocated storage.
    /// Handles planar (ARKit's bi-planar YUV) and packed formats. Public so
    /// non-AR capture paths (front-camera preview) can decouple their
    /// buffers from the capture pool the same way.
    public nonisolated static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
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

    public nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let sawPlane = anchors.contains { $0 is ARPlaneAnchor }
        let restored = anchors.first { $0.name == Self.tableAnchorName }
        guard sawPlane || restored != nil else { return }
        let box = restored.map(AnchorBox.init)
        Task { @MainActor in
            if sawPlane { self.planeAvailable = true }
            if let box {
                self.restoredTableAnchorTransform = Self.transform3D(from: box.anchor.transform)
                self.tableAnchor = box.anchor
            }
        }
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

/// Transfers an ARAnchor reference from ARKit's session queue to the main
/// actor (ARAnchor itself is not Sendable; the reference is immutable).
private struct AnchorBox: @unchecked Sendable {
    let anchor: ARAnchor
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
    /// World position of the root at creation; layout positions arrive in
    /// world space and are re-expressed relative to this so the anchored
    /// root can carry them through ARKit's map refinements.
    private let rootOrigin: Vec3
    /// Strip thickness (m) and lift above the cloth to avoid z-fighting.
    private static let stripWidth = 0.008
    private static let stripLift = 0.002

    /// Root under the table's ARAnchor when one exists — anchored content
    /// follows ARKit's refinements; identity-world content drifts (anchor
    /// best practice). Falls back to a world-fixed root without one.
    public init(arView: ARView, tableAnchor: ARAnchor? = nil) {
        if let tableAnchor {
            root = AnchorEntity(anchor: tableAnchor)
            let t = tableAnchor.transform.columns.3
            rootOrigin = Vec3(Double(t.x), Double(t.y), Double(t.z))
        } else {
            root = AnchorEntity(world: matrix_identity_float4x4)
            rootOrigin = .zero
        }
        arView.scene.addAnchor(root)
    }

    /// World → root-local (the anchor was created translation-only).
    private func local(_ world: Vec3, lift: Double) -> SIMD3<Float> {
        SIMD3<Float>(Float(world.x - rootOrigin.x),
                     Float(world.y - rootOrigin.y + lift),
                     Float(world.z - rootOrigin.z))
    }

    public func render(_ layout: OverlayLayout, planeNormalUp: Bool = true) {
        root.children.removeAll()

        // Tracked-ball rings first (visually lowest): flat rings on the
        // cloth at each tracked ball, the cue ball's filled + white so the
        // user always sees which ball the app treats as the cue — and can
        // see where to tap when designating one manually.
        for ball in layout.balls {
            let ringRadius = max(ball.radius * 1.35, 0.03)
            let mesh = MeshResource.generateCylinder(
                height: Float(Self.stripWidth / 2),
                radius: Float(ringRadius))
            let color: UIColor = ball.isCue ? .white : uiColor(from: 0xF5A623)
            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: ball.isCue ? 0.9 : 0.45)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = local(ball.position, lift: Self.stripLift)
            root.addChild(entity)
        }

        for strip in layout.strips {
            let mesh = MeshResource.generateBox(
                width: Float(strip.length),
                height: Float(Self.stripWidth / 2),
                depth: Float(Self.stripWidth))
            var material = UnlitMaterial(color: uiColor(from: strip.color))
            material.blending = .transparent(opacity: .init(floatLiteral: strip.dashed ? 0.7 : 0.95))
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = local(strip.midpoint, lift: Self.stripLift)
            entity.orientation = simd_quatf(angle: Float(strip.angle),
                                            axis: SIMD3<Float>(0, planeNormalUp ? 1 : -1, 0))
            root.addChild(entity)
        }

        if let ghost = layout.ghostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: 0.35)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = local(ghost.position, lift: ghost.radius)
            root.addChild(entity)
        }

        for pocket in layout.highlightedPockets {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(pocket.radius * 1.2))
            var material = UnlitMaterial(color: uiColor(from: 0x2FA36B))
            material.blending = .transparent(opacity: 0.5)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = local(pocket.position, lift: Self.stripLift)
            root.addChild(entity)
        }

        // Called pocket (M6-02): amber ring while aiming, felt green when
        // the prediction is on line into it.
        if let called = layout.calledPocket {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(called.radius))
            let color: UInt32 = layout.calledPocketSatisfied ? 0x2FA36B : 0xF5A623
            var material = UnlitMaterial(color: uiColor(from: color))
            material.blending = .transparent(
                opacity: layout.calledPocketSatisfied ? 0.85 : 0.6)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = local(called.position, lift: Self.stripLift * 2)
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
