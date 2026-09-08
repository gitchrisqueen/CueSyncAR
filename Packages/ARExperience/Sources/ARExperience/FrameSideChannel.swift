//
//  FrameSideChannel.swift
//  ARExperience
//
//  Per-frame facts a `CapturedFrame` cannot carry (the contract is
//  frozen) but a session recording needs: where the table anchor was
//  when this exact frame was captured, how the camera image maps onto
//  the screen, and which way the interface was oriented. The coordinator
//  writes one entry per DELIVERED frame from ARKit's delegate queue; the
//  recorder looks it up by the frame's timestamp from wherever it runs.
//  Pure Foundation — the ring and its lock box are unit-tested on Linux.
//

import CueSyncCore
import Foundation

/// The view the AR content is rendered into, as far as projection math
/// needs it. Refreshed from the main actor at loop cadence.
public struct ViewportInfo: Sendable, Equatable {
    /// Size in points.
    public var width: Double
    public var height: Double
    /// Points-to-pixels scale.
    public var displayScale: Double
    /// "portrait" | "portraitUpsideDown" | "landscapeLeft" |
    /// "landscapeRight" | "unknown".
    public var interfaceOrientation: String

    public init(width: Double, height: Double, displayScale: Double,
                interfaceOrientation: String) {
        self.width = width
        self.height = height
        self.displayScale = displayScale
        self.interfaceOrientation = interfaceOrientation
    }

    public static let unknown = ViewportInfo(width: 0, height: 0, displayScale: 1,
                                             interfaceOrientation: "unknown")
}

/// What was true of the AR session at the instant one frame was handed
/// out. Keyed by the frame's timestamp (the only identity a frame has).
public struct DeliveredFrameMeta: Sendable, Equatable {
    public var timestamp: TimeInterval
    /// The locked table ARAnchor's transform in this frame (nil before lock).
    public var tableAnchorTransform: Transform3D?
    /// ARKit's display transform for the viewport in force — normalized
    /// image → normalized view — as [a, b, c, d, tx, ty]. Nil when the
    /// viewport was unknown (before the view laid out).
    public var displayTransform: [Double]?
    public var viewport: ViewportInfo

    public init(timestamp: TimeInterval, tableAnchorTransform: Transform3D? = nil,
                displayTransform: [Double]? = nil, viewport: ViewportInfo) {
        self.timestamp = timestamp
        self.tableAnchorTransform = tableAnchorTransform
        self.displayTransform = displayTransform
        self.viewport = viewport
    }
}

/// Fixed-capacity history of delivered-frame metadata, newest last.
/// Frames are pulled one at a time, so a consumer is at most a frame or
/// two behind delivery; the capacity is generous so a slow detector
/// (hosted API round trips) still finds its frame.
public struct FrameMetaRing: Sendable, Equatable {
    public let capacity: Int
    private var entries: [DeliveredFrameMeta] = []

    public init(capacity: Int = 32) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func record(_ meta: DeliveredFrameMeta) {
        entries.append(meta)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Exact-timestamp lookup (frames are identified by their timestamp).
    public func meta(at timestamp: TimeInterval) -> DeliveredFrameMeta? {
        entries.last { $0.timestamp == timestamp }
    }

    public var latest: DeliveredFrameMeta? { entries.last }
    public var count: Int { entries.count }
}

/// Lock-protected ring shared between ARKit's session queue (writer) and
/// whichever queue the recorder runs on (reader).
public final class FrameMetaRingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: FrameMetaRing

    public init(capacity: Int = 32) {
        ring = FrameMetaRing(capacity: capacity)
    }

    public func record(_ meta: DeliveredFrameMeta) {
        lock.lock()
        ring.record(meta)
        lock.unlock()
    }

    public func meta(at timestamp: TimeInterval) -> DeliveredFrameMeta? {
        lock.lock()
        defer { lock.unlock() }
        return ring.meta(at: timestamp)
    }

    public var latest: DeliveredFrameMeta? {
        lock.lock()
        defer { lock.unlock() }
        return ring.latest
    }
}

/// Lock-protected viewport cache: written by the main actor at loop
/// cadence, read on ARKit's delegate queue when a frame is delivered.
public final class ViewportInfoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ViewportInfo.unknown

    public init() {}

    public var current: ViewportInfo {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
