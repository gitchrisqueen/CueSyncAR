import Foundation
import Testing
@testable import PerceptionKit

/// `#expect` cannot wrap a mutating call directly; route through a helper.
private func admit(_ throttle: inout IngestThrottle, at time: TimeInterval) -> Bool {
    throttle.admit(at: time)
}

@Suite("IngestThrottle")
struct IngestThrottleTests {
    @Test func firstFrameAlwaysPasses() {
        var throttle = IngestThrottle(minimumInterval: 0.5)
        #expect(admit(&throttle, at: 100))
    }

    @Test func admitsOnceTheIntervalElapsedSinceTheLastAdmission() {
        var throttle = IngestThrottle(minimumInterval: 0.5)
        #expect(admit(&throttle, at: 100.0))
        #expect(!admit(&throttle, at: 100.2))
        #expect(!admit(&throttle, at: 100.4))
        // Measured from the last ADMITTED frame, not the last offered one.
        #expect(admit(&throttle, at: 100.5))
        #expect(!admit(&throttle, at: 100.9))
        #expect(admit(&throttle, at: 101.0))
    }

    @Test func sameTimestampsProduceSameDecisions() {
        // Determinism by construction: the decision is a pure function of
        // the timestamp sequence, never of wall time.
        let times: [TimeInterval] = [0, 0.1, 0.3, 0.55, 0.6, 1.2, 1.3, 1.71]
        var a = IngestThrottle(minimumInterval: 0.5)
        var b = IngestThrottle(minimumInterval: 0.5)
        let decisionsA = times.map { a.admit(at: $0) }
        let decisionsB = times.map { b.admit(at: $0) }
        #expect(decisionsA == decisionsB)
        #expect(decisionsA == [true, false, false, true, false, true, false, true])
    }

    @Test func clockGoingBackwardsRebasesInsteadOfBlocking() {
        var throttle = IngestThrottle(minimumInterval: 0.5)
        #expect(admit(&throttle, at: 500))
        #expect(admit(&throttle, at: 10))
        #expect(!admit(&throttle, at: 10.1))
    }

    @Test func resetLetsTheNextFramePass() {
        var throttle = IngestThrottle(minimumInterval: 0.5)
        #expect(admit(&throttle, at: 100))
        #expect(!admit(&throttle, at: 100.1))
        throttle.reset()
        #expect(admit(&throttle, at: 100.1))
    }
}
