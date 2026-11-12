import Foundation
import Testing
@testable import ARExperience

@Suite("LatencyStages: the arithmetic")
struct LatencyStagesTests {
    // Stamps in seconds on one clock.
    // captured, +40 delivered, +5 received, +15 ingested (the loop's tail),
    // +50 produced, +1 consumed, +24 arrived, +5 draw start, +5 draw end.
    private func stages(c: Double = 100.000, d: Double = 100.040, r: Double = 100.045,
                        i: Double = 100.060, p: Double = 100.110, n: Double = 100.111,
                        a: Double = 100.135, s: Double = 100.140,
                        e: Double = 100.145) -> LatencyStages? {
        LatencyStages(captured: c, delivered: d, received: r, ingested: i, produced: p,
                      consumed: n, arrived: a, drawStart: s, drawEnd: e)
    }

    @Test("Each stage is the gap between two neighbouring stamps, in ms")
    func stagesAreGaps() throws {
        let value = try #require(stages())
        #expect(abs(value.deliver - 40) < 1e-6)
        #expect(abs(value.resume - 5) < 1e-6)
        #expect(abs(value.ingest - 15) < 1e-6)
        #expect(abs(value.pipeline - 50) < 1e-6)
        #expect(abs(value.stream - 1) < 1e-6)
        #expect(abs(value.hop - 24) < 1e-6)
        #expect(abs(value.wait - 5) < 1e-6)
        #expect(abs(value.render - 5) < 1e-6)
    }

    @Test("The stages add up to camera-to-drawn exactly: none lost, none counted twice")
    func stagesSumToTheWholeSpan() throws {
        let value = try #require(stages())
        #expect(abs(value.total - 145) < 1e-6)
        let parts = LatencyStages.names.reduce(0.0) { $0 + (value.byName[$1] ?? .nan) }
        #expect(abs(parts - value.total) < 1e-9)
        #expect(abs(value.byName["total"]! - 145) < 1e-6)
    }

    @Test("Stamps out of order, non-finite, or an absurd span are refused, not clamped")
    func refusesNonsense() {
        #expect(stages(d: 99.9) == nil, "delivered before captured")
        #expect(stages(p: 100.05) == nil, "produced before it was ingested")
        #expect(stages(n: 100.10) == nil, "consumed before it was produced")
        #expect(stages(e: 100.13) == nil, "draw ended before it started")
        #expect(stages(c: .nan) == nil)
        #expect(stages(e: 111) == nil, "over ten seconds is two clocks")
    }

    @Test("A stage of zero is allowed: a state drawn the moment it arrives")
    func zeroStage() throws {
        let value = try #require(stages(s: 100.135, e: 100.135))
        #expect(value.wait == 0 && value.render == 0)
    }
}

@Suite("LatencyLedger: stamps to means")
struct LatencyLedgerTests {
    /// The frame's life up to the pipeline's output reaching the main actor.
    private func arrive(_ ledger: LatencyLedger, _ t: Double, skewMs: Double = 0) {
        let skew = skewMs / 1000
        ledger.noteDelivered(captured: t, at: t + 0.040)
        ledger.noteReceived(captured: t, at: t + 0.045)
        ledger.noteIngested(captured: t, at: t + 0.060)
        ledger.noteConsumed(captured: t, at: t + 0.111 + skew)
        ledger.noteArrived(captured: t, produced: t + 0.110 + skew, at: t + 0.135 + skew)
    }

    /// One frame through every stamp: 145 ms camera to drawn.
    private func run(_ ledger: LatencyLedger, captured t: Double, skewMs: Double = 0) {
        let skew = skewMs / 1000
        arrive(ledger, t, skewMs: skewMs)
        ledger.noteDrawn(start: t + 0.140 + skew, end: t + 0.145 + skew)
    }

    @Test("No summary until one frame has been drawn")
    func emptyUntilDrawn() {
        let ledger = LatencyLedger()
        #expect(ledger.summary == nil)
        arrive(ledger, 1)
        #expect(ledger.summary == nil, "arrived is not drawn")
    }

    @Test("A drawn frame produces the stage means and a total that is their sum")
    func oneFrame() throws {
        let ledger = LatencyLedger()
        run(ledger, captured: 50)
        let summary = try #require(ledger.summary)
        #expect(summary.samples == 1)
        #expect(abs(try #require(summary.meanMs["deliver"]) - 40) < 1e-6)
        #expect(abs(try #require(summary.meanMs["ingest"]) - 15) < 1e-6)
        #expect(abs(try #require(summary.meanMs["pipeline"]) - 50) < 1e-6)
        #expect(abs(try #require(summary.meanMs["hop"]) - 24) < 1e-6)
        #expect(abs(summary.medianTotalMs - 145) < 1e-6)
        let sum = LatencyStages.names.reduce(0.0) { $0 + (summary.meanMs[$1] ?? 0) }
        #expect(abs(sum - (summary.meanMs["total"] ?? .nan)) < 1e-6)
    }

    @Test("Median and worst are over the window; one stall moves the worst, not the median")
    func medianAndWorst() throws {
        let ledger = LatencyLedger()
        for index in 0..<9 { run(ledger, captured: 10 + Double(index)) }
        run(ledger, captured: 30, skewMs: 200)
        let summary = try #require(ledger.summary)
        #expect(summary.samples == 10)
        #expect(abs(summary.medianTotalMs - 145) < 1e-6)
        #expect(abs(summary.worstTotalMs - 345) < 1e-6)
    }

    @Test("An output replaced before it was drawn is counted as superseded, and only the newer is timed")
    func superseded() throws {
        let ledger = LatencyLedger()
        arrive(ledger, 1)
        arrive(ledger, 2)
        ledger.noteDrawn(start: 2.140, end: 2.145)
        let summary = try #require(ledger.summary)
        #expect(summary.superseded == 1)
        #expect(summary.samples == 1)
        #expect(abs(summary.medianTotalMs - 145) < 1e-6, "timed from frame 2, not frame 1")
        // A second draw with nothing new arrived adds nothing.
        ledger.noteDrawn(start: 2.2, end: 2.21)
        #expect(ledger.summary?.samples == 1)
    }

    @Test("A frame the ledger never saw pulled, or a pipeline with no stamp, is incomplete, not guessed")
    func incomplete() {
        let ledger = LatencyLedger()
        ledger.noteArrived(captured: 5, produced: 5.08, at: 5.11)
        ledger.noteDelivered(captured: 6, at: 6.04)
        ledger.noteReceived(captured: 6, at: 6.045)
        ledger.noteIngested(captured: 6, at: 6.06)
        ledger.noteConsumed(captured: 6, at: 6.1)
        ledger.noteArrived(captured: 6, produced: nil, at: 6.11)
        ledger.noteDrawn(start: 6.12, end: 6.13)
        #expect(ledger.summary == nil)
        // A frame whose ingest or stream stamp is missing is incomplete too.
        ledger.noteDelivered(captured: 8, at: 8.04)
        ledger.noteReceived(captured: 8, at: 8.045)
        ledger.noteArrived(captured: 8, produced: 8.08, at: 8.11)
        ledger.noteDrawn(start: 8.115, end: 8.12)
        run(ledger, captured: 7)
        #expect(ledger.summary?.incomplete == 3)
    }

    @Test("A draw with out-of-order stamps is rejected and counted")
    func rejected() {
        let ledger = LatencyLedger()
        arrive(ledger, 1)
        ledger.noteDrawn(start: 1.0, end: 1.01)   // drawn "before" it arrived
        #expect(ledger.summary == nil)
        run(ledger, captured: 2)
        #expect(ledger.summary?.rejected == 1)
    }

    @Test("The window keeps the newest frames only")
    func windowIsBounded() throws {
        let ledger = LatencyLedger()
        for index in 0..<(LatencyLedger.window + 25) { run(ledger, captured: 100 + Double(index)) }
        #expect(try #require(ledger.summary).samples == LatencyLedger.window)
    }

    @Test("Frames wait in a bounded list between pull and arrival")
    func inFlightIsBounded() {
        let ledger = LatencyLedger()
        for index in 0..<(LatencyLedger.remembered + 10) {
            ledger.noteDelivered(captured: Double(index), at: Double(index) + 0.04)
        }
        // The oldest was evicted, so its output cannot be timed.
        ledger.noteReceived(captured: 0, at: 0.045)
        ledger.noteIngested(captured: 0, at: 0.06)
        ledger.noteConsumed(captured: 0, at: 0.111)
        ledger.noteArrived(captured: 0, produced: 0.11, at: 0.135)
        ledger.noteDrawn(start: 0.14, end: 0.145)
        #expect(ledger.summary == nil)
    }

    @Test("Reset forgets everything")
    func reset() {
        let ledger = LatencyLedger()
        run(ledger, captured: 1)
        ledger.reset()
        #expect(ledger.summary == nil)
    }
}

@Suite("RenderSignal: draw when the state lands")
struct RenderSignalTests {
    @Test("A signal wakes the consumer")
    func wakes() async {
        let signal = RenderSignal()
        var iterator = signal.stream.makeAsyncIterator()
        signal.signal()
        #expect(await iterator.next() != nil)
    }

    @Test("Signals that arrive before the consumer runs coalesce into one wake")
    func coalesces() async {
        let signal = RenderSignal()
        for _ in 0..<7 { signal.signal() }
        signal.finish()
        var wakes = 0
        for await _ in signal.stream { wakes += 1 }
        #expect(wakes == 1)
    }

    @Test("A signal after the consumer has caught up wakes it again")
    func wakesAgain() async {
        let signal = RenderSignal()
        var iterator = signal.stream.makeAsyncIterator()
        signal.signal()
        _ = await iterator.next()
        signal.signal()
        #expect(await iterator.next() != nil)
    }

    @Test("Finishing ends the consumer's loop")
    func finishes() async {
        let signal = RenderSignal()
        signal.finish()
        var iterator = signal.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

@Suite("MirrorPacing: the mirror does its expensive work only when watched")
struct MirrorPacingTests {
    private let nobody = MirrorPacing.Watching(frame: false, state: false, ui: false)
    private let everyone = MirrorPacing.Watching(frame: true, state: true, ui: true)

    @Test("The first call does the frame and the state, so the first fetch finds something")
    func firstCall() {
        var pacing = MirrorPacing()
        let due = pacing.due(at: 0, watching: nobody)
        #expect(due.frame && due.state)
        #expect(!due.ui, "nobody asked for the UI snapshot")
    }

    @Test("Watched: a frame each second, the state every call")
    func watched() {
        var pacing = MirrorPacing()
        _ = pacing.due(at: 0, watching: everyone)
        var frames = 0, states = 0
        for tick in 1...30 {
            let due = pacing.due(at: Double(tick) * 0.1, watching: everyone)
            if due.frame { frames += 1 }
            if due.state { states += 1 }
        }
        #expect(frames == 3, "at 1.0, 2.0 and 3.0 s")
        #expect(states == 30)
    }

    @Test("Idle: a frame every 5 s and the state every second, not every tick")
    func idle() {
        var pacing = MirrorPacing()
        _ = pacing.due(at: 0, watching: nobody)
        var frames = 0, states = 0
        for tick in 1...100 {
            let due = pacing.due(at: Double(tick) * 0.1, watching: nobody)
            if due.frame { frames += 1 }
            if due.state { states += 1 }
        }
        #expect(frames == 2, "at 5 and 10 s")
        #expect(states == 10)
    }

    @Test("The UI snapshot is at most once a second however fast the loop ticks")
    func uiIsThrottled() {
        var pacing = MirrorPacing()
        var shots = 0
        for tick in 0..<50 {
            let due = pacing.due(at: Double(tick) * 0.1, watching: everyone)
            shots += due.ui ? 1 : 0
        }
        #expect(shots == 5, "over 4.9 s: at 0, 1, 2, 3 and 4 s")
    }

    @Test("A screenshot still in flight is not stacked on; it is retried the next call")
    func frameInFlight() {
        var pacing = MirrorPacing()
        _ = pacing.due(at: 0, watching: everyone)
        #expect(!pacing.due(at: 1.2, watching: everyone, frameInFlight: true).frame)
        #expect(pacing.due(at: 1.3, watching: everyone, frameInFlight: false).frame)
    }

    @Test("Someone starting to watch gets a fresh frame on the next call, not after the idle period")
    func startingToWatch() {
        var pacing = MirrorPacing()
        _ = pacing.due(at: 0, watching: nobody)
        #expect(!pacing.due(at: 2, watching: nobody).frame)
        #expect(pacing.due(at: 2.1, watching: everyone).frame, "2.1 s since the last is over the watched period")
    }

    @Test("A client that polls slowly is served a state at 40 percent of its interval, not every tick")
    func slowPoller() {
        func states(pollInterval: Double?) -> Int {
            var pacing = MirrorPacing()
            let watching = MirrorPacing.Watching(frame: false, state: true, ui: false,
                                                 statePollInterval: pollInterval)
            _ = pacing.due(at: 0, watching: watching)
            var count = 0
            for tick in 1...100 where pacing.due(at: Double(tick) * 0.1, watching: watching).state { count += 1 }
            return count
        }
        #expect(states(pollInterval: nil) == 100, "unknown interval: every tick, as before")
        #expect(states(pollInterval: 0.2) == 100, "4 to 6 Hz scripts get every tick")
        #expect(states(pollInterval: 2.5) == 10, "capped at once a second")
        #expect(states(pollInterval: 1.0) == 25, "every 0.4 s")
    }

    @Test("A clock that steps backwards cannot freeze the mirror")
    func clockStep() {
        var pacing = MirrorPacing()
        _ = pacing.due(at: 1000, watching: nobody)
        let due = pacing.due(at: 5, watching: nobody)
        #expect(due.frame && due.state)
    }
}
