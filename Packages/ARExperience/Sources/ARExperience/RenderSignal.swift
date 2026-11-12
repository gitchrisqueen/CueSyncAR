//
//  RenderSignal.swift
//  ARExperience
//
//  "A new table state has landed: draw it now."
//
//  The overlay used to be drawn only by the AR loop, once per tick, so a
//  result that finished just after a tick waited out the rest of the period
//  (up to 100 ms, 50 ms on average). The producer calls `signal()` when the
//  state lands and one consumer task draws; the loop still draws every tick
//  for what changes between states (the live aim).
//
//  Signals coalesce: many before the consumer runs wake it once, because the
//  drawing reads the newest state and not a queue of them.
//

import Foundation

public final class RenderSignal: Sendable {
    /// The single consumer iterates this.
    public let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self,
                                                        bufferingPolicy: .bufferingNewest(1))
    }

    /// Wake the consumer. Safe from any thread; never blocks.
    public func signal() {
        continuation.yield()
    }

    /// End the stream (tests, shutdown).
    public func finish() {
        continuation.finish()
    }
}
