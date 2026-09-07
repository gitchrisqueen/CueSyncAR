//
//  RecordedFrameSource.swift
//  SessionReplay
//
//  FrameSourcing over a bundle's frames.jsonl: hands out the recorded
//  frames in index order, then nil. This is what a Simulator replay view
//  plugs into the app loop in place of ARSessionCoordinator (later task);
//  ReplayRunner iterates the frames directly.
//

import ARExperience
import CueSyncCore
import Foundation

public actor RecordedFrameSource: FrameSourcing {
    private let frames: [RecordedFrameMeta]
    private var cursor = 0

    public init(frames: [RecordedFrameMeta]) {
        self.frames = frames.sorted { $0.index < $1.index }
    }

    public init(bundle: SessionBundle) {
        self.init(frames: bundle.frames)
    }

    /// Frames not yet handed out.
    public var remaining: Int { frames.count - cursor }

    /// The next recorded frame, or nil once exhausted (or if a recorded
    /// transform is malformed — the reader's validation rejects those
    /// before a bundle gets this far).
    public func nextFrame() async -> CapturedFrame? {
        guard cursor < frames.count else { return nil }
        defer { cursor += 1 }
        return try? frames[cursor].capturedFrame()
    }

    /// Start over from the first frame.
    public func rewind() {
        cursor = 0
    }
}
