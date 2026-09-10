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
import CueSyncUI
import Foundation
import PerceptionKit
import TableSpace

#if canImport(ARKit) && canImport(RealityKit) && os(iOS)
import ARKit
import RealityKit

@MainActor
public final class ARSessionCoordinator: NSObject, ARSessionDelegate, FrameSourcing {
    /// Name of the world anchor the locked table calibration hangs off.
    public nonisolated static let tableAnchorName = "cuesync.tableOrigin"

    public let arView: ARView
    private let pendingRequest = FrameRequestBox()
    /// T1.4 instrumentation: counters for the ARFrame-retention hunt. The
    /// delegate (session queue) and snapshot path (main actor) both write;
    /// the app layer reads a snapshot ~every few seconds and logs it.
    private let diagnostics = DiagnosticsBox()
    /// Session-recording side channel: one DeliveredFrameMeta per frame
    /// handed out (table-anchor pose, display transform, orientation),
    /// keyed by timestamp. Written in the delegate; read by the recorder.
    let frameMetaRing = FrameMetaRingBox()
    /// Viewport facts the delegate needs to compute a display transform,
    /// refreshed from the main actor by `refreshViewportInfo()`.
    let viewportBox = ViewportInfoBox()
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
    /// The configuration the session is running, kept so a camera hand-off
    /// can resume with the same one (and the same world map) instead of
    /// letting RealityKit auto-configure a fresh, re-origined session.
    private var lastConfiguration: ARConfiguration?

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
        lastConfiguration = configuration
        arView.session.run(configuration)
    }

    // MARK: - Camera hand-off (front-camera preview)

    /// True while the AR session is suspended for the front-camera preview.
    /// The app's session loop reads this to stop pulling frames — a paused
    /// session never delivers one, so an ungated `nextFrame()` would hang.
    public private(set) var isSuspendedForCameraHandoff = false

    /// Suspend the AR session so a plain AVCapture front-camera preview can
    /// own the camera, WITHOUT destroying the session.
    ///
    /// The distinction matters more than it looks. Tearing the ARView down
    /// (which is what removing it from the view hierarchy does) drops the
    /// world origin, and every calibration corner is stored in world
    /// coordinates — so the corners came back somewhere else entirely when
    /// the user flipped back. Pausing keeps the session object, its anchors
    /// and its map; `resumeFromCameraHandoff()` re-runs the SAME
    /// configuration with no `.resetTracking`, so ARKit relocalizes into the
    /// original origin and the corners land where they were left.
    public func suspendForCameraHandoff() {
        guard !isSuspendedForCameraHandoff else { return }
        isSuspendedForCameraHandoff = true
        pendingRequest.take()?.resume(returning: nil)
        arView.session.pause()
    }

    /// Resume after the front-camera preview released the camera. Re-runs
    /// the last configuration with NO reset options: resetting tracking or
    /// removing anchors here would reintroduce exactly the corner-drift bug
    /// this pair exists to fix.
    public func resumeFromCameraHandoff() {
        guard isSuspendedForCameraHandoff else { return }
        isSuspendedForCameraHandoff = false
        let configuration = lastConfiguration ?? ARWorldTrackingConfiguration()
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
        // ORDER MATTERS, and getting it wrong put the calibration quad in
        // the air above the cloth.
        //
        // This used to try `.existingPlaneInfinite` FIRST. That target takes
        // any horizontal plane ARKit has found ANYWHERE and extends it to
        // infinity, then returns the first intersection along the ray. In a
        // room the size of a games room that is a lot of planes — the floor,
        // the rail tops, a side table, a chair seat, the console under the
        // TV — and a tap aimed at a cushion nose can land on the infinite
        // extension of a surface metres away at the wrong height. It also
        // meant the caller's `fallbackPlaneHeight` was effectively dead
        // code, because an infinite plane almost always hits something.
        //
        // `.existingPlaneGeometry` only hits where a plane actually has
        // detected extent, which is the honest question: is there a real
        // surface under this pixel.
        let queries: [ARRaycastQuery.Target] =
            [.existingPlaneGeometry, .estimatedPlane, .existingPlaneInfinite]
        var hit: Vec3?
        for target in queries {
            if let result = arView.raycast(from: screenPoint, allowing: target,
                                           alignment: .horizontal).first {
                let t = result.worldTransform.columns.3
                hit = Vec3(Double(t.x), Double(t.y), Double(t.z))
                break
            }
        }
        // A KNOWN cloth height outranks whatever ARKit found. It is measured
        // from the balls actually resting on the actual cloth, so when a hit
        // disagrees with it by more than a cushion's thickness, the hit is on
        // something else — the rail, the floor, the furniture — and the cloth
        // is the answer the caller wanted.
        if let fallbackPlaneHeight {
            if let hit, ClothHeightCheck.trusts(hitHeight: hit.y, clothHeight: fallbackPlaneHeight) {
                return hit
            }
            if let onCloth = intersect(screenPoint: screenPoint,
                                       planeHeight: fallbackPlaneHeight) {
                return onCloth
            }
        }
        return hit
    }


    /// Ray/horizontal-plane intersection at a known height.
    private func intersect(screenPoint: CGPoint, planeHeight: Double) -> Vec3? {
        guard let ray = arView.ray(through: screenPoint) else { return nil }
        let origin = Vec3(Double(ray.origin.x), Double(ray.origin.y),
                          Double(ray.origin.z))
        let direction = Vec3(Double(ray.direction.x), Double(ray.direction.y),
                             Double(ray.direction.z))
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (planeHeight - origin.y) / direction.y
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

    /// The table anchor's CURRENT transform (B3 anchor following).
    /// `tableAnchor` is the object ARKit handed us at lock/restore and is
    /// never mutated; refinements arrive as replacement anchors in
    /// `currentFrame`, looked up by identifier. Nil until the anchor is
    /// present in the current frame.
    public var currentTableAnchorTransform: Transform3D? {
        guard let id = tableAnchor?.identifier,
              let anchor = arView.session.currentFrame?.anchors
                .first(where: { $0.identifier == id }) else { return nil }
        return Self.transform3D(from: anchor.transform)
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
        diagnostics.add(\.framesSeen)
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
            diagnostics.add(\.copyFailures)
            continuation.resume(returning: nil)
            return
        }
        diagnostics.add(\.framesDelivered)
        // Side channel for the session recorder: everything about THIS
        // frame that a CapturedFrame cannot carry, read here and released
        // with the ARFrame — the ring holds only value types.
        frameMetaRing.record(Self.deliveredMeta(for: frame, viewport: viewportBox.current))
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

    /// Value-type extract of a frame's recording side channel. Runs on the
    /// session queue inside the delegate callback; touches no buffers.
    nonisolated static func deliveredMeta(for frame: ARFrame,
                                          viewport: ViewportInfo) -> DeliveredFrameMeta {
        let anchor = frame.anchors.first { $0.name == Self.tableAnchorName }
        var display: [Double]?
        if viewport.width > 0, viewport.height > 0 {
            display = affineComponents(frame.displayTransform(
                for: orientation(named: viewport.interfaceOrientation),
                viewportSize: CGSize(width: viewport.width, height: viewport.height)))
        }
        return DeliveredFrameMeta(
            timestamp: frame.timestamp,
            tableAnchorTransform: anchor.map { transform3D(from: $0.transform) },
            displayTransform: display,
            viewport: viewport)
    }

    /// Snapshot the RENDERED view (camera background + RealityKit overlay
    /// entities) as JPEG — the debug mirror's frame source. Captures what
    /// the user actually sees, unlike raw camera frames.
    public func snapshotJPEG(compressionQuality: CGFloat = 0.5) async -> Data? {
        // Prime retention suspect (T1.4): RealityKit's snapshot pipeline
        // retains drawables/frames internally. Count + time every call so a
        // device run can correlate snapshot cadence with the "retaining N
        // ARFrames" warning; in-flight count exposes pile-ups when snapshot
        // completion falls behind the mirror's 1 Hz request rate.
        diagnostics.add(\.snapshotsInFlight)
        let started = ContinuousClock.now
        defer {
            diagnostics.add(\.snapshotsInFlight, delta: -1)
            diagnostics.recordSnapshot(milliseconds: (ContinuousClock.now - started)
                .totalMilliseconds)
        }
        return await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                continuation.resume(
                    returning: image?.jpegData(compressionQuality: compressionQuality))
            }
        }
    }

    /// Read-and-continue snapshot of the T1.4 counters.
    public nonisolated func frameDiagnostics() -> FrameDiagnostics {
        diagnostics.snapshot()
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

    /// What ARKit says tracking is doing right now (CueSyncUI's ARKit-free
    /// vocabulary), so the HUD can act on the CAUSE rather than parse a
    /// sentence.
    ///
    /// This used to be published only as `sessionEvent`, built with
    /// `String(describing: reason)` — which is how a player in a dim room
    /// came to read "Tracking limited: insufficientFeatures" while
    /// `HUDStatus.degraded(.lowLight)` ("Need more light") sat in the
    /// design system with nothing able to produce it.
    public private(set) var trackingCondition: TrackingCondition = .normal

    /// The one place ARKit's own enum is read. Everything downstream — the
    /// capsule, the calibration tap advice, the log line, the mirror —
    /// works from `TrackingCondition`, which is pure and tested on Linux.
    public nonisolated func session(_ session: ARSession,
                                    cameraDidChangeTrackingState camera: ARCamera) {
        let condition: TrackingCondition = switch camera.trackingState {
        case .normal: .normal
        case .notAvailable: .unavailable
        case .limited(.excessiveMotion): .excessiveMotion
        case .limited(.insufficientFeatures): .insufficientFeatures
        case .limited(.relocalizing): .relocalizing
        case .limited(.initializing): .initializing
        // A reason this ARKit knows and this build does not: treat it as
        // initializing (quiet, self-resolving) rather than inventing a
        // diagnosis for it.
        case .limited: .initializing
        }
        noteTracking(condition)
    }

    private nonisolated func noteTracking(_ condition: TrackingCondition) {
        Task { @MainActor in
            self.sessionEvent = condition.diagnostic
            self.trackingCondition = condition
        }
    }

    /// Session health that is not about tracking quality (failures,
    /// interruptions). Developer-facing: it reaches the log and the debug
    /// mirror, never the status capsule.
    private nonisolated func report(_ message: String?) {
        Task { @MainActor in
            self.sessionEvent = message
        }
    }
}

/// T1.4 counters: how camera frames flow (or pile up) through the delegate
/// and the mirror snapshot path. Values are cumulative since session start.
public struct FrameDiagnostics: Sendable, Equatable {
    /// Delegate `didUpdate` callbacks observed (≈ camera FPS × uptime).
    public var framesSeen = 0
    /// Frames deep-copied and handed to a `nextFrame()` caller.
    public var framesDelivered = 0
    /// Deep-copy allocation failures (should stay 0; growth = memory pressure).
    public var copyFailures = 0
    /// Completed `arView.snapshot` calls (the mirror's frame source).
    public var snapshotsCompleted = 0
    /// Snapshot calls currently outstanding — sustained >1 means snapshot
    /// completion is slower than the mirror cadence (retention suspect).
    public var snapshotsInFlight = 0
    /// Total wall-clock spent in completed snapshot calls.
    public var snapshotTotalMilliseconds = 0.0

    public init() {}

    public var averageSnapshotMilliseconds: Double {
        snapshotsCompleted > 0 ? snapshotTotalMilliseconds / Double(snapshotsCompleted) : 0
    }
}

/// Lock-protected counter storage shared by the ARKit session queue (frame
/// delegate) and the main actor (snapshot path, reads).
private final class DiagnosticsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values = FrameDiagnostics()

    func add(_ keyPath: WritableKeyPath<FrameDiagnostics, Int>, delta: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        values[keyPath: keyPath] += delta
    }

    func recordSnapshot(milliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.snapshotsCompleted += 1
        values.snapshotTotalMilliseconds += milliseconds
    }

    func snapshot() -> FrameDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private extension Duration {
    var totalMilliseconds: Double {
        Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1e15
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
    /// Strip thickness (m) and lift above the cloth to avoid z-fighting.
    private static let stripWidth = 0.008
    private static let stripLift = 0.002
    /// Design palette for people; the metric palette (opaque, colour-
    /// keyable — see MetricPalette) while a session is being recorded.
    /// Takes effect on the next `render`.
    public var paletteMode: OverlayPaletteMode = .design
    /// The markers of the layout most recently rendered, in placement
    /// order — what a projection snapshot asks `arView.project` about.
    public private(set) var renderedMarkers: [RenderedMarker] = []

    /// Root under the table's ARAnchor when one exists — anchored content
    /// follows ARKit's refinements; identity-world content drifts (anchor
    /// best practice). Falls back to a world-fixed root without one.
    public init(arView: ARView, tableAnchor: ARAnchor? = nil) {
        if let tableAnchor {
            root = AnchorEntity(anchor: tableAnchor)
        } else {
            root = AnchorEntity(world: matrix_identity_float4x4)
        }
        arView.scene.addAnchor(root)
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

    /// Parent to the anchored root, THEN set the world position — parenting
    /// first lets RealityKit resolve world→anchor-local against the current
    /// anchor transform.
    private func place(_ entity: ModelEntity, at world: SIMD3<Float>) {
        root.addChild(entity)
        entity.setPosition(world, relativeTo: nil)
    }

    public func render(_ layout: OverlayLayout, planeNormalUp: Bool = true) {
        root.children.removeAll()
        renderedMarkers = layout.renderedMarkers
        let metric = paletteMode == .metric

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
            var material = UnlitMaterial(color: metric
                ? uiColor(from: MetricPalette.color(for: ball.isCue ? .cueBall : .ball)) : color)
            material.blending = metric ? .opaque : .transparent(opacity: ball.isCue ? 0.9 : 0.45)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(ball.position, lift: Self.stripLift))
        }

        // The recommended shot is drawn UNDER the live aim, thinner and
        // fainter. Same colour language, different weight: a plan reads as
        // a plan, and the live line stays the one the eye follows.
        func renderStrips(_ strips: [OverlayLayout.Strip]) {
            for strip in strips {
                let plan = strip.role == .plan
                let width = Self.stripWidth * (plan ? 0.5 : 1)
                let mesh = MeshResource.generateBox(
                    width: Float(strip.length),
                    height: Float(width / 2),
                    depth: Float(width))
                let stripColor = metric
                    ? MetricPalette.color(for: MetricPalette.stripMarker(forDesignColor: strip.color))
                    : strip.color
                var material = UnlitMaterial(color: uiColor(from: stripColor))
                let opacity: Float = plan ? 0.4 : (strip.dashed ? 0.7 : 0.95)
                material.blending = metric ? .opaque
                    : .transparent(opacity: .init(floatLiteral: opacity))
                let entity = ModelEntity(mesh: mesh, materials: [material])
                place(entity, at: worldPoint(strip.midpoint,
                                             lift: Self.stripLift * (plan ? 0.6 : 1)))
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
                                          relativeTo: nil)
                }
            }
        }

        renderStrips(layout.targetStrips)
        renderStrips(layout.strips)

        if let ghost = layout.ghostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: metric
                ? uiColor(from: MetricPalette.color(for: .ghostBall)) : .white)
            material.blending = metric ? .opaque : .transparent(opacity: 0.35)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(ghost.position, lift: ghost.radius))
        }

        for pocket in layout.highlightedPockets {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(pocket.radius * 1.2))
            var material = UnlitMaterial(color: uiColor(
                from: metric ? MetricPalette.color(for: .pocket) : 0x2FA36B))
            material.blending = metric ? .opaque : .transparent(opacity: 0.5)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(pocket.position, lift: Self.stripLift))
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
            place(entity, at: worldPoint(called.position, lift: Self.stripLift * 2))
        }

        // The ball being shot at, the pocket it is going to, and where the
        // cue ball has to arrive to send it there. Drawn last so the ball
        // the percentage refers to is never buried under a path.
        if let target = layout.targetBall {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(target.radius))
            var material = UnlitMaterial(color: uiColor(
                from: metric ? MetricPalette.color(for: .pocket) : 0x2FA36B))
            material.blending = metric ? .opaque : .transparent(opacity: 0.75)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(target.position, lift: Self.stripLift * 1.6))
        }
        if let pocket = layout.targetPocket {
            let mesh = MeshResource.generateCylinder(height: Float(Self.stripWidth / 2),
                                                     radius: Float(pocket.radius * 1.35))
            var material = UnlitMaterial(color: uiColor(
                from: metric ? MetricPalette.color(for: .pocket) : 0x2FA36B))
            material.blending = metric ? .opaque : .transparent(opacity: 0.4)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(pocket.position, lift: Self.stripLift))
        }
        if let ghost = layout.targetGhostBall {
            let mesh = MeshResource.generateSphere(radius: Float(ghost.radius))
            var material = UnlitMaterial(color: metric
                ? uiColor(from: MetricPalette.color(for: .ghostBall)) : uiColor(from: 0x2FA36B))
            material.blending = metric ? .opaque : .transparent(opacity: 0.25)
            let entity = ModelEntity(mesh: mesh, materials: [material])
            place(entity, at: worldPoint(ghost.position, lift: ghost.radius))
        }
    }

    public func clear() {
        root.children.removeAll()
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
