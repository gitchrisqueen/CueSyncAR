//
//  FrameSourcing.swift
//  ARExperience
//
//  The seam between "where camera frames come from" and everything that
//  consumes them. The live app pulls from ARSessionCoordinator (ARKit);
//  replay pulls from a recorded session bundle (SessionReplay); the future
//  Simulator replay view swaps one for the other at this boundary. Pure
//  protocol — no ARKit import — so it exists on every platform.
//

import CueSyncCore
import Foundation

/// A pull-based source of camera frames (see ARSessionCoordinator for why
/// frames are pulled, not pushed: retained capture buffers stall ARKit).
public protocol FrameSourcing: Sendable {
    /// Await the next frame. Returns nil when the source is exhausted, the
    /// session pauses, or the awaiting task is cancelled. Callers are
    /// expected to be a single polling loop.
    func nextFrame() async -> CapturedFrame?
}
