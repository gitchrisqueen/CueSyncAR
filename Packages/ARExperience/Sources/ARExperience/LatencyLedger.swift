//
//  LatencyLedger.swift
//  ARExperience
//
//  Where the camera-to-overlay milliseconds go, as stages that add up.
//
//  One frame's life, every stamp on the same monotonic clock (system uptime,
//  the clock ARFrame.timestamp uses):
//
//    captured  the camera's own timestamp for the frame
//    delivered ARKit called the session delegate with it
//    received  the AR loop got it back from `nextFrame()` on the main actor
//    ingested  the task that hands it to the pipeline began to run
//    produced  the perception pipeline yielded the output for it
//    consumed  the task reading the pipeline's output stream got it
//    arrived   the main actor began handling that output
//    drawn     the overlay for it was composed and handed to the renderer
//
//  and the stages between them:
//
//    deliver   captured  -> delivered   ARKit's own delay; not ours to change
//    resume    delivered -> received    waiting for the main actor to resume
//                                       the loop
//    ingest    received  -> ingested    the frame waiting for the main actor
//                                       to run the loop's tail and then the
//                                       ingest task (0 when ingest does not
//                                       use the main actor)
//    pipeline  ingested  -> produced    the pipeline actor's wait, the
//                                       change gate, detect, project, track,
//                                       appearance
//    stream    produced  -> consumed    the output stream's hand-over to the
//                                       task that reads it (off the main
//                                       actor)
//    hop       consumed  -> arrived     waiting for the main actor to start
//                                       the output handler
//    wait      arrived   -> drawn start the handler's own work, then waiting
//                                       for the draw to run
//    render    drawn start -> drawn end composing the layout and the scene
//                                       update (RealityKit's display frame
//                                       after that is not visible to the app)
//
//  They sum to `total` exactly, by construction, so a stage cannot be
//  double-counted or lost. The older `overlayLatencyMs` stops at `arrived`
//  (plus the handler's pre-ranking work): it never saw the wait for the
//  loop's next tick or the render call, which is why moving the draw did not
//  move it.
//
//  Pure arithmetic plus a small lock-protected ledger: tested on Linux.
//

import Foundation

public struct LatencyStages: Sendable, Equatable {
    public static let names = ["deliver", "resume", "ingest", "pipeline", "stream", "hop", "wait", "render"]

    /// Milliseconds.
    public var deliver: Double
    public var resume: Double
    public var ingest: Double
    public var pipeline: Double
    public var stream: Double
    public var hop: Double
    public var wait: Double
    public var render: Double

    /// Camera timestamp to the end of the draw, in milliseconds: the sum of
    /// the stages, which is also `drawnEnd - captured`.
    public var total: Double { deliver + resume + ingest + pipeline + stream + hop + wait + render }

    public var byName: [String: Double] {
        ["deliver": deliver, "resume": resume, "ingest": ingest, "pipeline": pipeline,
         "stream": stream, "hop": hop, "wait": wait, "render": render, "total": total]
    }

    /// The stages for one frame, from its stamps in seconds.
    ///
    /// Nil when the stamps are not in order or the whole span is absurd: two
    /// clocks, a stamp from another frame, or a clock that stepped. A wrong
    /// number is worse than none, because someone will quote it.
    public init?(captured: TimeInterval, delivered: TimeInterval, received: TimeInterval,
                 ingested: TimeInterval, produced: TimeInterval, consumed: TimeInterval,
                 arrived: TimeInterval, drawStart: TimeInterval, drawEnd: TimeInterval) {
        let stamps = [captured, delivered, received, ingested, produced, consumed,
                      arrived, drawStart, drawEnd]
        guard stamps.allSatisfy(\.isFinite) else { return nil }
        for (earlier, later) in zip(stamps, stamps.dropFirst()) where later < earlier { return nil }
        guard drawEnd - captured < 10 else { return nil }
        deliver = (delivered - captured) * 1000
        resume = (received - delivered) * 1000
        ingest = (ingested - received) * 1000
        pipeline = (produced - ingested) * 1000
        stream = (consumed - produced) * 1000
        hop = (arrived - consumed) * 1000
        wait = (drawStart - arrived) * 1000
        render = (drawEnd - drawStart) * 1000
    }
}

/// Collects the stamps of the frames that go by and folds each drawn frame
/// into a rolling window. Shared between the camera delegate's queue, the
/// perception pipeline's output task and the main actor, hence the lock.
public final class LatencyLedger: @unchecked Sendable {
    /// One per process. The delegate that stamps `delivered` and the app that
    /// stamps the rest have no other object in common.
    public static let shared = LatencyLedger()

    /// Rolling window, in drawn frames.
    public static let window = 40
    /// Frames remembered between "pulled" and "output arrived".
    static let remembered = 32

    private struct InFlight {
        var captured: TimeInterval
        var delivered: TimeInterval?
        var received: TimeInterval?
        var ingested: TimeInterval?
        var consumed: TimeInterval?
    }

    private struct Arrival {
        var captured: TimeInterval
        var delivered: TimeInterval
        var received: TimeInterval
        var ingested: TimeInterval
        var produced: TimeInterval
        var consumed: TimeInterval
        var arrived: TimeInterval
    }

    private let lock = NSLock()
    private var inFlight: [InFlight] = []
    private var latest: Arrival?
    private var samples: [LatencyStages] = []
    private var supersededCount = 0
    private var rejectedCount = 0
    private var incompleteCount = 0

    public init() {}

    /// ARKit handed the frame to the delegate. Called on the session queue.
    public func noteDelivered(captured: TimeInterval, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        inFlight.append(InFlight(captured: captured, delivered: now, received: nil))
        if inFlight.count > Self.remembered { inFlight.removeFirst() }
    }

    /// The loop got the frame back from `nextFrame()`.
    public func noteReceived(captured: TimeInterval, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let index = inFlight.lastIndex(where: { $0.captured == captured }) {
            inFlight[index].received = now
        }
    }

    /// The task that hands the frame to the pipeline began to run.
    public func noteIngested(captured: TimeInterval, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let index = inFlight.lastIndex(where: { $0.captured == captured }) {
            inFlight[index].ingested = now
        }
    }

    /// The task reading the pipeline's output stream got the output.
    public func noteConsumed(captured: TimeInterval, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let index = inFlight.lastIndex(where: { $0.captured == captured }) {
            inFlight[index].consumed = now
        }
    }

    /// The main actor began handling the pipeline's output for the frame.
    /// `produced` is the pipeline's own stamp for yielding it; nil (a replay,
    /// an older pipeline) counts the frame as incomplete.
    public func noteArrived(captured: TimeInterval, produced: TimeInterval?, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let produced,
              let entry = inFlight.last(where: { $0.captured == captured }),
              let delivered = entry.delivered, let received = entry.received,
              let ingested = entry.ingested, let consumed = entry.consumed else {
            incompleteCount += 1
            return
        }
        // A newer output arriving before the last one was drawn replaces it:
        // the older state was never shown, and saying so keeps the means
        // honest about what the player actually saw.
        if latest != nil { supersededCount += 1 }
        latest = Arrival(captured: captured, delivered: delivered, received: received,
                         ingested: ingested, produced: produced, consumed: consumed, arrived: now)
    }

    /// The overlay for the newest arrived output was drawn (or found to need
    /// no change). Nothing to do when no output has arrived since the last draw.
    public func noteDrawn(start: TimeInterval, end: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let arrival = latest else { return }
        latest = nil
        guard let stages = LatencyStages(captured: arrival.captured, delivered: arrival.delivered,
                                         received: arrival.received, ingested: arrival.ingested,
                                         produced: arrival.produced, consumed: arrival.consumed,
                                         arrived: arrival.arrived, drawStart: start, drawEnd: end) else {
            rejectedCount += 1
            return
        }
        samples.append(stages)
        if samples.count > Self.window { samples.removeFirst() }
    }

    /// The seconds the newest undrawn output has been waiting since it
    /// arrived, or nil. Used to time the pre-ranking part of the handler.
    public func arrivedAt() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return latest?.arrived
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        inFlight.removeAll()
        latest = nil
        samples.removeAll()
        supersededCount = 0
        rejectedCount = 0
        incompleteCount = 0
    }

    public struct Summary: Sendable, Equatable {
        /// Rolling mean per stage, plus `total`, in milliseconds.
        public var meanMs: [String: Double]
        /// Median and worst camera-to-drawn time in the window.
        public var medianTotalMs: Double
        public var worstTotalMs: Double
        public var samples: Int
        /// Outputs replaced by a newer one before they were drawn.
        public var superseded: Int
        /// Frames dropped for out-of-order stamps, or missing stamps.
        public var rejected: Int
        public var incomplete: Int
    }

    /// Nil until one frame has been drawn.
    public var summary: Summary? {
        lock.lock(); defer { lock.unlock() }
        guard !samples.isEmpty else { return nil }
        var means: [String: Double] = [:]
        for name in LatencyStages.names + ["total"] {
            let sum = samples.reduce(0) { $0 + ($1.byName[name] ?? 0) }
            means[name] = sum / Double(samples.count)
        }
        let totals = samples.map(\.total).sorted()
        return Summary(meanMs: means, medianTotalMs: totals[totals.count / 2],
                       worstTotalMs: totals.last ?? 0, samples: samples.count,
                       superseded: supersededCount, rejected: rejectedCount,
                       incomplete: incompleteCount)
    }
}
