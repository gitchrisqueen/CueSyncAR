//
//  SnapshotReprojectionTests.swift
//  CueSync AR
//

import Foundation
import Testing
@testable import SessionReplay

@Suite("Snapshot reprojection")
struct SnapshotReprojectionTests {

    /// Device recordings are the only bundles that carry overlay snapshots;
    /// the scripted fixtures have none, which the report must survive.
    static let deviceBundles = ["device-aimed-cue", "device-lying-cue"]

    @Test("It reports a number on real recordings, and says how it got it",
          arguments: SnapshotReprojectionTests.deviceBundles)
    func reportsOnDeviceBundles(name: String) throws {
        let bundle = try SessionBundleReader().read(from: fixtureDirectory(for: name))
        let report = SnapshotReprojectionReport.compute(bundle: bundle)
        // Not a bar. This is the instrument being proven to read at all —
        // the checklist row it serves has never been scored because this
        // did not exist.
        #expect(report.samples > 0, "\(name): no marker matched any detection")
        #expect(report.p50 >= 0)
        #expect(report.p95 >= report.p50)
        #expect(report.maximum >= report.p95)
        print("\(name): \(report.summary)")
        print("   convention: \(report.convention)")
    }

    @Test("A bundle with no snapshots reports nothing rather than failing")
    func scriptedBundlesAreEmptyNotBroken() throws {
        let bundle = try SessionBundleReader().read(from: fixtureDirectory(for: "scripted-5ball"))
        let report = SnapshotReprojectionReport.compute(bundle: bundle)
        #expect(report.samples == 0)
        #expect(report.summary == "reprojection: no matched markers")
    }

    @Test("The lift is what makes the number mean anything")
    func theLiftMatters() throws {
        let bundle = try SessionBundleReader().read(from: fixtureDirectory(for: "device-aimed-cue"))
        let lifted = SnapshotReprojectionReport.compute(bundle: bundle)
        // With NO lift, markers are cloth-contact points and boxes are
        // sphere centres, so the report measures one ball radius of
        // parallax and calls it error. That artefact is the reason this
        // convention is stated in the type itself.
        let unlifted = SnapshotReprojectionReport.compute(bundle: bundle, ballRadius: 0)
        print("lifted p50=\(lifted.p50)  unlifted p50=\(unlifted.p50)")
        #expect(lifted.p50 != unlifted.p50)
    }

    @Test("Percentiles are ordered and handle the empty case")
    func percentiles() {
        #expect(SnapshotReprojectionReport.percentile([], 0.5) == 0)
        #expect(SnapshotReprojectionReport.percentile([1], 0.95) == 1)
        #expect(SnapshotReprojectionReport.percentile([1, 2, 3, 4], 0.5) == 3)
        #expect(SnapshotReprojectionReport.percentile([1, 2, 3, 4], 0.95) == 4)
    }
}

@Suite("Surface gate counters")
struct SurfaceGateCountersTests {

    /// The counters existed as a log line every fortieth frame and were
    /// otherwise thrown away. Device-checklist row 7 ("nothing renders past
    /// the cushion nose") names them as its offline proxy, so they have to
    /// reach `OutputRecord` — and they have to be non-trivially populated,
    /// or the row would be scored against a field that is always zero.
    @Test("Real recordings actually exercise the gate")
    func deviceBundlesRejectSomething() throws {
        let directory = try fixtureDirectory(for: "device-lying-cue")
        let outputs = try #require(try SessionBundleReader().outputs(in: directory))
        let rejected = outputs.reduce(0) { $0 + $1.surfaceGate.rejected }
        // A cue lying on the cloth projects boxes off the table constantly;
        // if this ever reads zero the gate has stopped running, not the
        // recording changed.
        #expect(rejected > 0, "the gate rejected nothing across \(outputs.count) frames")
    }

    @Test("Scripted fixtures are clean, which is why they are the control")
    func scriptedBundlesRejectNothing() throws {
        let directory = try fixtureDirectory(for: "scripted-5ball")
        let outputs = try #require(try SessionBundleReader().outputs(in: directory))
        // Synthetic detections are exact forward projections, so anything
        // rejected here would be a bug in the gate rather than in the world.
        #expect(outputs.allSatisfy { $0.surfaceGate.rejected == 0 })
        #expect(outputs.allSatisfy { $0.surfaceGate.suppressed == 0 })
    }

    @Test("No tracked ball was ever suppressed in the committed recordings")
    func suppressionIsZeroSoFar() throws {
        // Recorded as a fact, not a bar: the reporting invariant (every ball
        // in TableState is inside the playing surface) has never had to fire
        // on real data. If a future change makes this non-zero, that is
        // worth knowing rather than silently absorbing.
        for name in ["device-aimed-cue", "device-lying-cue"] {
            let directory = try fixtureDirectory(for: name)
            let outputs = try #require(try SessionBundleReader().outputs(in: directory))
            let suppressed = outputs.reduce(0) { $0 + $1.surfaceGate.suppressed }
            #expect(suppressed == 0, "\(name) suppressed \(suppressed) tracks")
        }
    }
}
