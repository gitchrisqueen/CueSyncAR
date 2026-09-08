//
//  ProjectionSnapshot.swift
//  ARExperience
//
//  "Where did the renderer put each overlay on the screen?" — the
//  bracketed projection snapshot a session recording takes at ~1 Hz. The
//  marker list is derived purely from the OverlayLayout the renderer was
//  last given (stable order, tested on Linux); the ARKit-gated half asks
//  `arView.project` for each marker between two reads of the camera and
//  table-anchor pose. Equal before/after poses make the record a truth an
//  offline projection can be checked against; unequal ones mean the
//  device moved mid-snapshot and the record is only a bound.
//

import CueSyncCore
import Foundation

public enum RenderedMarkerKind: String, Sendable, Equatable, CaseIterable {
    case ball
    case cueBall
    case ghostBall
    case pocket
    case calledPocket
    /// A trajectory strip's midpoint (its id is the ball the strip belongs to).
    case strip
}

/// One overlay entity's world-space placement as handed to the renderer.
public struct RenderedMarker: Sendable, Equatable {
    public var kind: RenderedMarkerKind
    public var id: Int?
    public var world: Vec3

    public init(kind: RenderedMarkerKind, id: Int? = nil, world: Vec3) {
        self.kind = kind
        self.id = id
        self.world = world
    }
}

extension OverlayLayout {
    /// Every entity `OverlayRenderer.render` places for this layout, in
    /// the order it places them: ball rings, strips, ghost ball, pocket
    /// highlights, called pocket. Balls carry their array position as id
    /// (the layout has no ball ids); strips carry their ball id.
    public var renderedMarkers: [RenderedMarker] {
        var markers: [RenderedMarker] = []
        for (index, ball) in balls.enumerated() {
            markers.append(RenderedMarker(kind: ball.isCue ? .cueBall : .ball,
                                          id: index, world: ball.position))
        }
        for strip in strips {
            markers.append(RenderedMarker(kind: .strip, id: strip.ballID.rawValue,
                                          world: strip.midpoint))
        }
        if let ghostBall {
            markers.append(RenderedMarker(kind: .ghostBall, world: ghostBall.position))
        }
        for (index, pocket) in highlightedPockets.enumerated() {
            markers.append(RenderedMarker(kind: .pocket, id: index, world: pocket.position))
        }
        if let calledPocket {
            markers.append(RenderedMarker(kind: .calledPocket, world: calledPocket.position))
        }
        return markers
    }
}

/// Camera + table-anchor pose read from the session's current frame.
public struct PoseSample: Sendable, Equatable {
    public var frameTimestamp: TimeInterval
    public var cameraTransform: Transform3D
    public var tableAnchorTransform: Transform3D?

    public init(frameTimestamp: TimeInterval, cameraTransform: Transform3D,
                tableAnchorTransform: Transform3D? = nil) {
        self.frameTimestamp = frameTimestamp
        self.cameraTransform = cameraTransform
        self.tableAnchorTransform = tableAnchorTransform
    }
}

/// A marker and where the renderer projected it (nil: behind the camera).
public struct ProjectedMarker: Sendable, Equatable {
    public var marker: RenderedMarker
    /// View points.
    public var screen: Vec2?

    public init(marker: RenderedMarker, screen: Vec2?) {
        self.marker = marker
        self.screen = screen
    }
}

public struct ProjectionSnapshot: Sendable, Equatable {
    public var before: PoseSample
    public var after: PoseSample
    public var markers: [ProjectedMarker]
    public var viewport: ViewportInfo
    /// [a, b, c, d, tx, ty] of ARKit's display transform, if known.
    public var displayTransform: [Double]?
    public var paletteMode: OverlayPaletteMode

    public init(before: PoseSample, after: PoseSample, markers: [ProjectedMarker],
                viewport: ViewportInfo, displayTransform: [Double]? = nil,
                paletteMode: OverlayPaletteMode) {
        self.before = before
        self.after = after
        self.markers = markers
        self.viewport = viewport
        self.displayTransform = displayTransform
        self.paletteMode = paletteMode
    }

    /// True when nothing moved between the two pose reads.
    public var poseStable: Bool { before == after }
}

#if canImport(ARKit) && canImport(RealityKit) && os(iOS)
import ARKit
import RealityKit
import UIKit

extension ARSessionCoordinator {
    /// Read the current viewport (size, scale, orientation) into the box
    /// the frame delegate stamps deliveries with. Call at loop cadence.
    public func refreshViewportInfo() {
        let size = arView.bounds.size
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .unknown
        viewportBox.current = ViewportInfo(
            width: Double(size.width), height: Double(size.height),
            displayScale: Double(arView.traitCollection.displayScale),
            interfaceOrientation: Self.orientationName(orientation))
    }

    /// The viewport as last refreshed (any queue).
    public nonisolated var currentViewport: ViewportInfo { viewportBox.current }

    /// The side channel for a delivered frame, by its timestamp. Safe
    /// from any queue.
    public nonisolated func deliveredFrameMeta(at timestamp: TimeInterval) -> DeliveredFrameMeta? {
        frameMetaRing.meta(at: timestamp)
    }

    /// Newest delivered-frame side channel entry (any queue).
    public nonisolated var lastDeliveredFrameMeta: DeliveredFrameMeta? {
        frameMetaRing.latest
    }

    /// Bracketed projection of `markers` through RealityKit's own
    /// `arView.project`. Nil when the session has no current frame yet.
    public func projectionSnapshot(markers: [RenderedMarker],
                                   paletteMode: OverlayPaletteMode) -> ProjectionSnapshot? {
        guard let before = poseSample() else { return nil }
        let projected = markers.map { marker -> ProjectedMarker in
            let point = arView.project(SIMD3<Float>(Float(marker.world.x),
                                                    Float(marker.world.y),
                                                    Float(marker.world.z)))
            return ProjectedMarker(marker: marker,
                                   screen: point.map { Vec2(Double($0.x), Double($0.y)) })
        }
        let after = poseSample() ?? before
        let viewport = viewportBox.current
        return ProjectionSnapshot(before: before, after: after, markers: projected,
                                  viewport: viewport,
                                  displayTransform: currentDisplayTransform(viewport: viewport),
                                  paletteMode: paletteMode)
    }

    /// Camera + table-anchor pose from the session's current frame. The
    /// ARFrame is read and released inside this call — never stored.
    private func poseSample() -> PoseSample? {
        guard let frame = arView.session.currentFrame else { return nil }
        let anchor = frame.anchors.first { $0.name == Self.tableAnchorName }
        return PoseSample(frameTimestamp: frame.timestamp,
                          cameraTransform: Self.transform3D(from: frame.camera.transform),
                          tableAnchorTransform: anchor.map { Self.transform3D(from: $0.transform) })
    }

    private func currentDisplayTransform(viewport: ViewportInfo) -> [Double]? {
        guard viewport.width > 0, viewport.height > 0,
              let frame = arView.session.currentFrame else { return nil }
        return Self.affineComponents(frame.displayTransform(
            for: Self.orientation(named: viewport.interfaceOrientation),
            viewportSize: CGSize(width: viewport.width, height: viewport.height)))
    }

    nonisolated static func affineComponents(_ t: CGAffineTransform) -> [Double] {
        [Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty)]
    }

    nonisolated static func orientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
    }

    nonisolated static func orientation(named name: String) -> UIInterfaceOrientation {
        switch name {
        case "portrait": .portrait
        case "portraitUpsideDown": .portraitUpsideDown
        case "landscapeLeft": .landscapeLeft
        case "landscapeRight": .landscapeRight
        default: .portrait
        }
    }
}
#endif
