import Foundation
import Testing
@testable import PerceptionKit

/// Drives the probe the way the app does across launches: every "launch"
/// starts from whatever the store holds, and a "crash" is simply dropping
/// the in-memory probe without disarming it.
@Suite("DetectorComputeProbe")
struct DetectorComputeProbeTests {
    typealias Record = DetectorComputeProbeRecord

    /// One launch: read the store, decide, hand back the probe.
    private func launch(_ store: InMemoryDetectorComputeProbeStore,
                        optedOut: Bool = false) -> DetectorComputeProbe {
        DetectorComputeProbe(launching: store.load(), optedOut: optedOut)
    }

    /// Arm and persist — the step the app must complete before every
    /// risky Neural Engine call.
    private func armAndPersist(_ probe: inout DetectorComputeProbe,
                               to store: InMemoryDetectorComputeProbeStore) throws {
        probe.arm()
        try store.save(probe.record)
    }

    // MARK: First run

    @Test func aFreshInstallAttemptsTheNeuralEngine() {
        let probe = DetectorComputeProbe(launching: Record(), optedOut: false)
        #expect(probe.units == .cpuAndNeuralEngine)
        #expect(probe.phase == .attempting)
        #expect(!probe.crashedLastRun)
        #expect(!probe.relaunchNeeded)
        // Nothing is armed until the app says a risky step is next.
        #expect(!probe.record.armed)
        #expect(probe.record.crashes == 0)
    }

    @Test func armingSetsTheMarkerThatMustBePersistedBeforeTheCall() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var probe = launch(store)
        try armAndPersist(&probe, to: store)
        #expect(probe.record.armed)
        #expect(store.load().armed)
        #expect(store.saves == 1)
    }

    // MARK: Successful run

    @Test func theFirstInferenceReturningClearsTheMarkerAndCountsASuccess() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var probe = launch(store)
        try armAndPersist(&probe, to: store)          // model load
        probe.disarm()                                 // load returned
        try store.save(probe.record)
        #expect(!store.load().armed)
        #expect(probe.phase == .attempting)            // inference still ahead
        try armAndPersist(&probe, to: store)          // first inference
        probe.recordSuccess()
        try store.save(probe.record)
        #expect(probe.phase == .succeeded)
        #expect(probe.units == .cpuAndNeuralEngine)
        #expect(!probe.record.armed)
        #expect(probe.record.successes == 1)
        #expect(probe.record.crashes == 0)
        #expect(!probe.record.pinnedToCPU)
        // The next launch attempts again — no pin was ever set.
        let next = launch(store)
        #expect(next.units == .cpuAndNeuralEngine)
        #expect(next.phase == .attempting)
        #expect(next.record.successes == 1)
    }

    @Test func aNormalExitBetweenLoadAndFirstInferenceIsNotACrash() throws {
        // The owner opened the app, never locked a calibration, and the
        // system later killed it in the background. The marker was only
        // ever set around the load, which returned.
        let store = InMemoryDetectorComputeProbeStore()
        var probe = launch(store)
        try armAndPersist(&probe, to: store)
        probe.disarm()
        try store.save(probe.record)
        let next = launch(store)
        #expect(next.units == .cpuAndNeuralEngine)
        #expect(!next.crashedLastRun)
        #expect(next.record.crashes == 0)
    }

    // MARK: Crashed last run

    @Test func aMarkerFoundSetAtLaunchMeansTheLastRunCrashedAndForcesTheCPU() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var first = launch(store)
        try armAndPersist(&first, to: store)
        // SIGABRT here: `first` is simply never disarmed.

        let second = launch(store)
        #expect(second.units == .cpuOnly)
        #expect(second.phase == .fellBack)
        #expect(second.crashedLastRun)
        #expect(second.record.crashes == 1)
        #expect(second.record.pinnedToCPU)
        // The marker is consumed by the launch, so the crash is counted
        // exactly once even if this record is persisted and re-read.
        #expect(!second.record.armed)
        try store.save(second.record)

        // A later launch stays pinned but knows the crash was not just now.
        let third = launch(store)
        #expect(third.units == .cpuOnly)
        #expect(third.phase == .fellBack)
        #expect(!third.crashedLastRun)
        #expect(third.record.crashes == 1)
    }

    @Test func armIsANoOpOnTheCPUSoAStrayMarkerCannotBeWritten() throws {
        let store = InMemoryDetectorComputeProbeStore(record: {
            var record = Record()
            record.pinnedToCPU = true
            return record
        }())
        var probe = launch(store)
        #expect(probe.units == .cpuOnly)
        probe.arm()
        #expect(!probe.record.armed)
        probe.recordSuccess()
        #expect(probe.phase == .fellBack)
        #expect(probe.record.successes == 0)
    }

    // MARK: Reset

    @Test func resetLiftsThePinAndTheNextLaunchTriesAgain() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var first = launch(store)
        try armAndPersist(&first, to: store)
        var fallback = launch(store)
        #expect(fallback.units == .cpuOnly)

        fallback.reset()
        try store.save(fallback.record)
        // This run is still on the CPU — only a relaunch can retry.
        #expect(fallback.units == .cpuOnly)
        #expect(fallback.relaunchNeeded)
        #expect(!fallback.record.pinnedToCPU)
        #expect(!fallback.record.armed)

        let retry = launch(store)
        #expect(retry.units == .cpuAndNeuralEngine)
        #expect(retry.phase == .attempting)
        #expect(!retry.crashedLastRun)
        // History survives the reset.
        #expect(retry.record.crashes == 1)
    }

    @Test func resetWhileAlreadyOnTheNeuralEngineNeedsNoRelaunch() {
        var probe = DetectorComputeProbe(launching: Record(), optedOut: false)
        probe.reset()
        #expect(!probe.relaunchNeeded)
        #expect(probe.units == .cpuAndNeuralEngine)
    }

    // MARK: Repeated crashes

    @Test func repeatedCrashesAccumulateAcrossResets() throws {
        let store = InMemoryDetectorComputeProbeStore()
        for expectedCrashes in 1...3 {
            var attempt = launch(store)
            #expect(attempt.units == .cpuAndNeuralEngine)
            try armAndPersist(&attempt, to: store)
            // crash
            var fallback = launch(store)
            #expect(fallback.units == .cpuOnly)
            #expect(fallback.crashedLastRun)
            #expect(fallback.record.crashes == expectedCrashes)
            fallback.reset()
            try store.save(fallback.record)
        }
        #expect(store.load().crashes == 3)
        #expect(!store.load().pinnedToCPU)
    }

    @Test func withoutAResetACrashPinIsPermanent() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var first = launch(store)
        try armAndPersist(&first, to: store)
        for _ in 0..<5 {
            let later = launch(store)
            #expect(later.units == .cpuOnly)
            try store.save(later.record)
        }
        #expect(store.load().crashes == 1)
    }

    // MARK: Opt-out

    @Test func theSettingsPinWinsOverAFreshRecord() {
        let probe = DetectorComputeProbe(launching: Record(), optedOut: true)
        #expect(probe.units == .cpuOnly)
        #expect(probe.phase == .optedOut)
        #expect(!probe.record.pinnedToCPU)
        #expect(!probe.record.armed)
    }

    @Test func optingOutStillCountsACrashFoundAtLaunch() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var first = launch(store)
        try armAndPersist(&first, to: store)
        let optedOut = launch(store, optedOut: true)
        #expect(optedOut.units == .cpuOnly)
        #expect(optedOut.phase == .optedOut)
        #expect(optedOut.crashedLastRun)
        #expect(optedOut.record.crashes == 1)
        #expect(optedOut.record.pinnedToCPU)
    }

    // MARK: Non-crash load failure

    @Test func aThrowingNeuralEngineLoadFallsBackForThisRunWithoutPinning() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var probe = launch(store)
        try armAndPersist(&probe, to: store)
        probe.recordLoadFailure()
        try store.save(probe.record)
        #expect(probe.units == .cpuOnly)
        #expect(probe.phase == .loadFailed)
        #expect(!probe.record.armed)
        #expect(!probe.record.pinnedToCPU)
        let next = launch(store)
        #expect(next.units == .cpuAndNeuralEngine)
        #expect(next.record.crashes == 0)
    }

    // MARK: Summary lines

    @Test func summariesNameTheUnitAndTheReason() throws {
        let store = InMemoryDetectorComputeProbeStore()
        var probe = launch(store)
        #expect(probe.summary.contains("Neural Engine"))
        #expect(probe.summary.contains("pending"))
        probe.recordSuccess()
        #expect(probe.summary.contains("probe passed"))

        try armAndPersist(&probe, to: store)
        var fallback = launch(store)
        #expect(fallback.summary.hasPrefix("Detector: CPU"))
        #expect(fallback.summary.contains("crashed last run"))
        fallback.reset()
        #expect(fallback.summary.hasSuffix("[relaunch to apply]"))

        #expect(DetectorComputeProbe(launching: Record(), optedOut: true).summary
                    .contains("pinned in Settings"))
    }

    // MARK: File store

    @Test func theFileStoreRoundTripsAndCreatesItsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuesync-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDetectorComputeProbeStore(
            url: directory.appendingPathComponent("nested/probe.json"))
        #expect(store.load() == Record())

        var record = Record()
        record.armed = true
        record.crashes = 2
        try store.save(record)
        // Read back through a brand-new store over the same path — the
        // "relaunch" path; nothing in memory carries over.
        #expect(FileDetectorComputeProbeStore(url: store.url).load() == record)
    }

    @Test func aCorruptMarkerFileReadsAsAFreshRecord() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuesync-probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(FileDetectorComputeProbeStore(url: url).load() == Record())
    }
}
