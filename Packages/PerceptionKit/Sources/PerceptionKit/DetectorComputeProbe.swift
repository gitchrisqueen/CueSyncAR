//
//  DetectorComputeProbe.swift
//  PerceptionKit
//
//  T1.3: the crash-safe probe behind the bundled detector's compute-unit
//  choice. Asking Core ML for the Neural Engine can abort the process
//  (an uncatchable C++ assertion inside MPSGraph's MLIR passes on iOS 26 —
//  see 09-SESSION-STATE.md "ANE re-export"), and an abort at first
//  inference crash-loops the app with no way back short of reinstalling.
//
//  The probe turns that into a self-healing experiment: a marker is
//  persisted BEFORE every risky Neural Engine step and cleared AFTER the
//  step returns. A launch that finds the marker still set knows the last
//  run died inside such a step, pins the detector to the CPU, and says so.
//  The decision logic is a pure value type here so every path is tested
//  on Linux; the app owns the file I/O ordering (arm → persist → risky
//  call → disarm → persist) and the Core ML calls themselves.
//

import Foundation

/// The compute units the bundled detector can be asked for. A plain enum
/// (not `MLComputeUnits`) so the state machine builds and tests on Linux;
/// the app maps it onto `MLModelConfiguration.computeUnits`.
public enum DetectorComputeUnits: String, Sendable, Equatable, Codable {
    /// The known-safe path (pinned since 2026-07-23).
    case cpuOnly
    /// The candidate: never tried on device before this probe existed. NOT
    /// `.all` — the GPU/MPSGraph route is the one proven to abort.
    case cpuAndNeuralEngine
}

/// What survives between launches — the on-disk half of the probe.
public struct DetectorComputeProbeRecord: Sendable, Equatable, Codable {
    /// True from just before a risky Neural Engine step (model load, first
    /// inference) until just after that step returned. Found true at
    /// launch ⇒ the previous run died inside the step.
    public var armed = false
    /// Launches that found `armed` still set.
    public var crashes = 0
    /// Launches on which the first Neural Engine inference returned.
    public var successes = 0
    /// Set by a detected crash, cleared by `DetectorComputeProbe.reset()`.
    /// While set, every launch stays on the CPU.
    public var pinnedToCPU = false

    public init() {}
}

/// One launch's compute-unit decision and what happened to it.
///
/// Lifecycle, as the app drives it:
/// 1. `init(launching:optedOut:)` reads the record and decides the units.
/// 2. Before each risky Neural Engine step: `arm()`, then PERSIST `record`
///    (synchronously, flushed) before making the call.
/// 3. After the step returns: `disarm()` (model load) or `recordSuccess()`
///    (first inference), then persist again.
/// 4. `reset()` lifts a crash pin; the retry happens on the next launch.
public struct DetectorComputeProbe: Sendable, Equatable {
    /// Where this launch's attempt stands.
    public enum Phase: String, Sendable, Equatable, Codable {
        /// Neural Engine requested; the first inference has not returned yet.
        case attempting
        /// The first Neural Engine inference returned — the pin can stay off.
        case succeeded
        /// A previous run died inside a Neural Engine step; CPU this run.
        case fellBack
        /// The owner pinned the CPU in Settings; nothing was attempted.
        case optedOut
        /// The Neural Engine model load threw (a Swift error, not an
        /// abort) or the marker could not be written; CPU this run, no pin.
        case loadFailed
    }

    /// The record as it should be on disk right now.
    public private(set) var record: DetectorComputeProbeRecord
    /// What the detector is (to be) loaded with this run.
    public private(set) var units: DetectorComputeUnits
    public private(set) var phase: Phase
    /// True when THIS launch found the marker set — distinguishes "fell
    /// back just now" from "still pinned from an earlier crash".
    public let crashedLastRun: Bool
    /// Set by `reset()` while running on the CPU: the record no longer
    /// matches what this run loaded, and only a relaunch can retry.
    public private(set) var relaunchNeeded = false

    /// Decide this launch's units from what the last run left behind.
    ///
    /// - Parameter optedOut: the owner's deliberate CPU pin from Settings.
    ///   It wins over everything, but a marker found set is still counted
    ///   as a crash so the history stays honest.
    public init(launching record: DetectorComputeProbeRecord, optedOut: Bool) {
        var record = record
        let crashed = record.armed
        if crashed {
            record.armed = false
            record.crashes += 1
            record.pinnedToCPU = true
        }
        self.record = record
        crashedLastRun = crashed
        if optedOut {
            units = .cpuOnly
            phase = .optedOut
        } else if record.pinnedToCPU {
            units = .cpuOnly
            phase = .fellBack
        } else {
            units = .cpuAndNeuralEngine
            phase = .attempting
        }
    }

    /// Mark a risky step as about to start. The caller MUST persist
    /// `record` before making the call. A no-op on the CPU: there is
    /// nothing risky to guard, and a stray marker would read as a crash.
    public mutating func arm() {
        guard units == .cpuAndNeuralEngine else { return }
        record.armed = true
    }

    /// A risky step returned. Clears the marker; the phase is unchanged
    /// (a returned model load still leaves the first inference ahead).
    public mutating func disarm() {
        record.armed = false
    }

    /// The first Neural Engine inference returned a result.
    public mutating func recordSuccess() {
        guard units == .cpuAndNeuralEngine else { return }
        record.armed = false
        record.successes += 1
        phase = .succeeded
    }

    /// The Neural Engine could not be used this run for a NON-crash reason
    /// (model load threw, marker unwritable). Falls back to the CPU for
    /// this run without pinning: the next launch tries again.
    public mutating func recordLoadFailure() {
        record.armed = false
        units = .cpuOnly
        phase = .loadFailed
    }

    /// Lift a crash pin so the next launch attempts the Neural Engine
    /// again. Counters are kept — repeated crashes stay visible.
    public mutating func reset() {
        record.pinnedToCPU = false
        record.armed = false
        if units == .cpuOnly { relaunchNeeded = true }
    }

    /// One line for the HUD, the log and the mirror's `summary` field.
    public var summary: String {
        let detail: String
        switch phase {
        case .attempting:
            detail = "Neural Engine, probing — first inference pending"
        case .succeeded:
            detail = "Neural Engine, probe passed (\(record.successes) run\(record.successes == 1 ? "" : "s"))"
        case .fellBack:
            detail = crashedLastRun
                ? "CPU — Neural Engine crashed last run (\(record.crashes) total); reset to retry"
                : "CPU — pinned after \(record.crashes) Neural Engine crash\(record.crashes == 1 ? "" : "es"); reset to retry"
        case .optedOut:
            detail = "CPU — pinned in Settings"
        case .loadFailed:
            detail = "CPU — Neural Engine load failed this run (not a crash)"
        }
        return "Detector: \(detail)" + (relaunchNeeded ? " [relaunch to apply]" : "")
    }
}

// MARK: - Persistence

/// Where the probe record lives between launches. The app uses the file
/// store; tests use the in-memory one.
public protocol DetectorComputeProbeStore: Sendable {
    /// The stored record; a missing or unreadable store yields a fresh
    /// record (never a throw — a corrupt marker must not brick detection).
    func load() -> DetectorComputeProbeRecord
    /// Persist `record` so that it is on disk when this returns.
    func save(_ record: DetectorComputeProbeRecord) throws
}

/// Test double: keeps the record in memory and counts saves, so a test
/// can assert the marker was persisted BEFORE the risky call.
public final class InMemoryDetectorComputeProbeStore: DetectorComputeProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DetectorComputeProbeRecord?
    private var saveCount = 0

    public init(record: DetectorComputeProbeRecord? = nil) {
        stored = record
    }

    /// Number of `save` calls so far.
    public var saves: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveCount
    }

    public func load() -> DetectorComputeProbeRecord {
        lock.lock()
        defer { lock.unlock() }
        return stored ?? DetectorComputeProbeRecord()
    }

    public func save(_ record: DetectorComputeProbeRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        stored = record
        saveCount += 1
    }
}

/// The production store: one small JSON file.
///
/// Durability argument (this is the whole point of the design): the
/// failure being guarded against is a SIGABRT of the app process, not a
/// power loss. `Data.write(to:options:.atomic)` writes a temporary file
/// and renames it over `url`; both are synchronous system calls, so when
/// `save` returns the marker is in the kernel's page cache under its final
/// name and the death of the writing process cannot lose it. The extra
/// `fsync` (`FileHandle.synchronize`) then pushes it to storage so even a
/// power cut mid-probe is covered. Nothing here is queued or deferred —
/// unlike `UserDefaults`, whose writes are proxied to `cfprefsd` and are
/// not guaranteed to have left the process when an abort follows at once.
public struct FileDetectorComputeProbeStore: DetectorComputeProbeStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> DetectorComputeProbeRecord {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(DetectorComputeProbeRecord.self, from: data) else {
            return DetectorComputeProbeRecord()
        }
        return record
    }

    public func save(_ record: DetectorComputeProbeRecord) throws {
        let data = try JSONEncoder().encode(record)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
