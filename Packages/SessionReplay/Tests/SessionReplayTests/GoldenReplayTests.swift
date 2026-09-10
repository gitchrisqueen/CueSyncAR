import CueSyncCore
import Foundation
import PerceptionKit
import Testing
@testable import SessionReplay

// The FIXED EVAL SET (11-EXECUTION-VERIFICATION T2.2, the ratchet): every
// committed bundle under Fixtures/Sessions replays byte-equal to its
// committed outputs.jsonl and clears the accuracy bars. A perception,
// tracking or physics change that alters an output fails here; if the
// change is intended, regenerate DELIBERATELY —
//
//     CUESYNC_REGENERATE_FIXTURES=1 swift test --package-path Packages/SessionReplay --filter Golden
//
// — review the diff of outputs.jsonl, and explain the change in the PR
// (04-TESTING-STRATEGY: goldens are never silently regenerated). The
// regenerating run records an issue on purpose so it can never pass green.
//
// CI runs exactly this suite via Scripts/verify/replay-golden.sh
// (`--filter Golden`), on Linux — the committed golden was produced on
// macOS, so a green run there is the cross-platform, cross-process
// byte-equality proof.

/// Steadiness bars — how much the guide is allowed to move on its own.
///
/// Separate from accuracy because they need no ground truth, which is what
/// lets a real recording be a gate at all: nobody has tape-measured the
/// balls in these, but "the aim source may not flip more than N times a
/// minute" is checkable on any bundle.
///
/// Every bar is set at the CURRENT measured value (rounded outward), so
/// this file is a ratchet: it cannot silently get worse, and each Phase-2
/// PR tightens the numbers it improves.
private struct StabilityBars {
    /// Guards the whole set: every other bar improves when nothing is
    /// drawn, so without a floor here a change that suppressed the guide
    /// entirely would look like a clean sweep.
    var minAimedFrameRate: Double = 0
    /// Ceiling on how often a guide is drawn, for clips where drawing one
    /// is the fault.
    var maxAimedFrameRate: Double = 1
    var maxStickPresentRate: Double = 1
    var minStickAimRate: Double = 0
    var maxSourceTransitionsPerMinute: Double = .infinity
    var maxHeadingDeltaMax: Double = .infinity
    var maxPlanChangedRate: Double = 1
    var maxSegmentCount: Int = .max
    var maxPredictionLengthP95: Double = .infinity
    var maxFarEndShiftP95: Double = .infinity
    var maxTrackChurn: Int = .max
    var maxCueIDChanges: Int = .max
}

/// Every committed golden bundle, its accuracy bars (when it has truth),
/// and its stability bars.
private struct GoldenBundle {
    let name: String
    var warmupFrames: Int = 0
    /// Accuracy needs ground truth; a recorded bundle has none until
    /// someone measures the balls, so these are optional.
    var maxPositionRMS: Double?
    var minRecall: Double?
    var minPrecision: Double?
    var stability = StabilityBars()
}

private let goldenBundles: [GoldenBundle] = [
    // Appearance gate is 3 frames, so frames 0–2 legitimately report nothing.
    GoldenBundle(name: "scripted-5ball", warmupFrames: 3,
                 maxPositionRMS: 0.02, minRecall: 0.98, minPrecision: 0.98),

    // Two stationary balls in CONTACT (centres one diameter apart, well
    // inside the 8 cm association gate) plus a cue ball, with one of the
    // pair dropped from detection for 3.1 s — longer than the 2.5 s grace,
    // so its track is genuinely retired and has to reclaim its OWN id
    // rather than its neighbour's. Three balls, three ids, no rebirths:
    // the bars are exact because the scene is synthetic and static.
    // `minRecall` is 0.96 rather than the 0.98 the other scripted bundle
    // holds, and the 2 % is bought deliberately: ball B is removed from
    // detection for 31 frames, which outlasts the 2.5 s grace on purpose, so
    // its track really is retired for ~6 frames and then spends 3 more
    // re-earning confirmation. Those 9 ball-frames are the scenario, not a
    // regression — the point of the fixture is that the id on the far side
    // of that gap is the SAME id, which `maxTrackChurn: 0` and
    // `frozenPairKeepsBothIdentities` are what actually assert.
    GoldenBundle(name: "scripted-frozen-pair", warmupFrames: 3,
                 maxPositionRMS: 0.02, minRecall: 0.96, minPrecision: 0.98,
                 stability: StabilityBars(maxTrackChurn: 0, maxCueIDChanges: 0)),

    // 300 frames of the operator AIMING a real cue, 2026-09-09. The clip
    // the stick gate has to accept.
    // `maxHeadingDeltaMax` was 3.0 and is now 7.0 — a bar deliberately
    // LOOSENED, which needs saying out loud. Aim continuity changes which
    // of a quad's two near-mirror diagonals wins, so a genuine re-aim now
    // costs one visible step here (measured 6.0 deg on this clip) where the
    // old code simply never re-acquired. What it bought, on the 1291-frame
    // recording that actually contained the pathology: the worst per-frame
    // swing fell from 21.2 to 2.1 degrees, and the far-end shift on THIS
    // clip fell from 2.03 m to 1.63 m — so `maxFarEndShiftP95` is tightened
    // 2.2 -> 1.7 in the same change. Net: one bar out, one bar in, both
    // measured.
    GoldenBundle(name: "device-aimed-cue",
                 stability: StabilityBars(
                    // Ratcheted 0.35 -> 0.40 at the measured 42.0 %. This is the
                    // headline feature's real number: the aim line is off screen
                    // MORE OFTEN THAN ON, on the clip where the operator is
                    // aiming a real cue. It is a floor, so it can only be moved
                    // up, and moving it up is the point of C7's provisional line.
                    minAimedFrameRate: 0.40,
                    minStickAimRate: 0.95,
                    maxSourceTransitionsPerMinute: 1.0,
                    maxHeadingDeltaMax: 7.0,
                    maxPlanChangedRate: 0.23,
                    maxSegmentCount: 4,
                    maxPredictionLengthP95: 2.0,
                    maxFarEndShiftP95: 1.3,
                    // Track-identity churn (Phase 3.1): 11 -> 7 measured, on
                    // re-identification of retired ids. Every other bar in
                    // this block is unmoved, which is the point — the change
                    // alters WHAT A BALL IS CALLED after a detection gap and
                    // nothing else, so aim, plan and guide geometry replay
                    // byte-for-byte as before apart from the ids.
                    //
                    // `maxCueIDChanges` ratchets 6 -> 4 at the measured
                    // value, but read it honestly: all 4 are the operator
                    // physically MOVING the cue ball between shots with the
                    // detector losing it for seconds in between. Nothing
                    // offline can tie those together, and nothing should.
                    maxTrackChurn: 7,
                    maxCueIDChanges: 4)),

    // 300 frames with the cue LYING ON THE CLOTH, same table, same evening.
    // The clip the stick gate has to REJECT: today it accepts a discarded
    // cue on 99.7 % of frames and lets it own the aim outright, which is
    // more reliably than it accepts a cue being aimed with (74 %). That
    // inversion is the bug; `maxStickPresentRate` is the ratchet on it.
    GoldenBundle(name: "device-lying-cue",
                 stability: StabilityBars(
                    // A CEILING, not a floor: on this clip a guide is a
                    // false positive, so fewer is better. It exists to
                    // catch a regression that starts drawing them again.
                    maxAimedFrameRate: 0.55,
                    maxStickPresentRate: 1.0,
                    maxSourceTransitionsPerMinute: 1.0,
                    maxHeadingDeltaMax: 5.0,
                    maxPlanChangedRate: 0.27,
                    maxSegmentCount: 3,
                    maxPredictionLengthP95: 0.8,
                    maxFarEndShiftP95: 0.2,
                    // 6 -> 0. This clip's whole churn was ONE flickering
                    // rail detection at (-0.076, +0.511) being reborn seven
                    // times; re-identification hands it back its own id, and
                    // the eight real balls now hold eight ids for the full
                    // 66 seconds. Zero is the right bar precisely because
                    // the layout never changes.
                    maxTrackChurn: 0,
                    maxCueIDChanges: 0))
]

/// The bundles that come from a generator rather than from a device, so
/// regeneration can rewrite their inputs as well as their outputs.
private struct ScriptedGenerator {
    let name: String
    let make: @Sendable () -> SessionBundle
}

private let scriptedGenerators: [ScriptedGenerator] = [
    ScriptedGenerator(name: ScriptedFiveBall.sessionID, make: ScriptedFiveBall.makeBundle),
    ScriptedGenerator(name: ScriptedFrozenPair.sessionID, make: ScriptedFrozenPair.makeBundle)
]

private let fixturesSubdirectory = "Fixtures/Sessions"

// Internal, not private: SnapshotReprojectionTests loads the same fixtures.
func fixtureDirectory(for name: String) throws -> URL {
    let root = try #require(Bundle.module.resourceURL,
                            "test bundle has no resources — check Package.swift")
    return root.appendingPathComponent(fixturesSubdirectory).appendingPathComponent(name)
}

/// The fixture directory in the SOURCE tree (for regeneration only).
private func sourceFixtureDirectory(for name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(fixturesSubdirectory)
        .appendingPathComponent(name)
}

private var regenerationRequested: Bool {
    ProcessInfo.processInfo.environment["CUESYNC_REGENERATE_FIXTURES"] == "1"
}

@Suite("Golden replay — fixed eval set", .serialized)
struct GoldenReplayTests {
    @Test func fixtureDirectoryMatchesManifest() throws {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent(fixturesSubdirectory)
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        #expect(Set(onDisk) == Set(goldenBundles.map(\.name)),
                "bundles on disk and the golden list diverged: \(onDisk.sorted())")
    }

    /// The scripted bundles are generated code — their committed input
    /// files must be exactly what the generators write today.
    @Test(arguments: scriptedGenerators.map(\.name))
    func committedInputsMatchTheGenerator(name: String) throws {
        let generator = try #require(scriptedGenerators.first { $0.name == name })
        let directory = try fixtureDirectory(for: name)
        let expected = SessionBundleWriter.inputTexts(for: generator.make())
        for (file, text) in expected.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let committed = try Data(contentsOf: directory.appendingPathComponent(file.rawValue))
            #expect(committed == Data(text.utf8),
                    "\(file.rawValue) differs from the generator output — regenerate deliberately")
        }
    }

    @Test(arguments: goldenBundles.map(\.name))
    func replayIsByteIdenticalAcrossRunsInOneProcess(name: String) async throws {
        let bundle = try SessionBundleReader().read(from: try fixtureDirectory(for: name))
        let first = try await ReplayRunner().run(bundle)
        let second = try await ReplayRunner().run(bundle)
        #expect(first.outputsData == second.outputsData)
        #expect(first.outputs.count == bundle.frames.count)
        #expect(first.droppedFrames.isEmpty)
    }

    /// The committed outputs.jsonl was written by a DIFFERENT process (and,
    /// in CI, a different OS): equality here is the fresh-process proof.
    @Test(arguments: goldenBundles.map(\.name))
    func replayMatchesTheCommittedGolden(name: String) async throws {
        if regenerationRequested {
            try await regenerate(name)
            return
        }
        let directory = try fixtureDirectory(for: name)
        let bundle = try SessionBundleReader().read(from: directory)
        let result = try await ReplayRunner().run(bundle)

        let committed = try #require(try SessionBundleReader().outputsData(in: directory),
                                     "\(name) has no committed outputs.jsonl")
        if result.outputsData != committed {
            let expectedText = String(bytes: committed, encoding: .utf8) ?? ""
            let expectedLines = expectedText.split(separator: "\n")
            let actualLines = result.outputsText.split(separator: "\n")
            let firstDifference = zip(expectedLines, actualLines).enumerated()
                .first { $0.element.0 != $0.element.1 }?.offset
                ?? min(expectedLines.count, actualLines.count)
            Issue.record("""
                \(name): replay output differs from the committed golden at line \(firstDifference + 1) \
                (expected \(expectedLines.count) lines, got \(actualLines.count)). \
                Expected: \(expectedLines.indices.contains(firstDifference) ? expectedLines[firstDifference] : "<eof>")
                Actual:   \(actualLines.indices.contains(firstDifference) ? actualLines[firstDifference] : "<eof>")
                """)
        }
    }

    /// Rewrite the SOURCE-tree fixture: the scripted bundle's inputs come
    /// from the generator (written, then re-read, so the golden is replayed
    /// from the six-decimal text exactly as CI will read it); a recorded
    /// bundle's inputs are left alone. Always records an issue.
    private func regenerate(_ name: String) async throws {
        let target = sourceFixtureDirectory(for: name)
        if let generator = scriptedGenerators.first(where: { $0.name == name }) {
            try SessionBundleWriter().write(generator.make(), to: target)
        }
        let bundle = try SessionBundleReader().read(from: target)
        let result = try await ReplayRunner().run(bundle)
        try SessionBundleWriter().writeOutputs(result.outputs, to: target)
        Issue.record("regenerated \(target.path) — review the diff before committing")
    }

    @Test(arguments: goldenBundles.map(\.name))
    func accuracyClearsTheBars(name: String) async throws {
        let golden = try #require(goldenBundles.first { $0.name == name })
        guard let maxPositionRMS = golden.maxPositionRMS,
              let minRecall = golden.minRecall,
              let minPrecision = golden.minPrecision else {
            // A recorded bundle with no tape-measured truth. Its stability
            // bars still gate it; accuracy waits for someone to measure the
            // balls (plan v5 Phase 5.1).
            return
        }
        let directory = try fixtureDirectory(for: name)
        let bundle = try SessionBundleReader().read(from: directory)
        let truth = try #require(bundle.truth, "\(name) has no truth.json")
        let result = try await ReplayRunner().run(bundle)
        let report = AccuracyReport.compute(outputs: result.outputs, truth: truth,
                                            warmupFrames: golden.warmupFrames)
        #expect(report.positionRMS <= maxPositionRMS, "\(report.summary)")
        #expect(report.recall >= minRecall, "\(report.summary)")
        #expect(report.precision >= minPrecision, "\(report.summary)")
        #expect(report.identitySwitches == 0, "\(report.summary)")
        #expect(report.trackChurn == 0, "\(report.summary)")
    }

    /// The steadiness ratchet. Prints the full report on every run so a PR
    /// can quote before/after numbers without extra tooling.
    @Test(arguments: goldenBundles.map(\.name))
    func stabilityClearsTheBars(name: String) async throws {
        let golden = try #require(goldenBundles.first { $0.name == name })
        let bars = golden.stability
        let directory = try fixtureDirectory(for: name)
        let bundle = try SessionBundleReader().read(from: directory)
        let result = try await ReplayRunner().run(bundle)
        let report = StabilityReport.compute(outputs: result.outputs)
        print("StabilityReport [\(name)] \(report.summary)")

        #expect(report.aimedFrameRate >= bars.minAimedFrameRate, "\(report.summary)")
        #expect(report.aimedFrameRate <= bars.maxAimedFrameRate, "\(report.summary)")
        #expect(report.stickPresentRate <= bars.maxStickPresentRate, "\(report.summary)")
        #expect(report.stickAimRate >= bars.minStickAimRate, "\(report.summary)")
        #expect(report.sourceTransitionsPerMinute <= bars.maxSourceTransitionsPerMinute,
                "\(report.summary)")
        #expect(report.headingDeltaMax <= bars.maxHeadingDeltaMax, "\(report.summary)")
        #expect(report.planChangedRate <= bars.maxPlanChangedRate, "\(report.summary)")
        #expect(report.segmentCountMax <= bars.maxSegmentCount, "\(report.summary)")
        #expect(report.predictionLengthP95 <= bars.maxPredictionLengthP95, "\(report.summary)")
        #expect(report.farEndShiftP95 <= bars.maxFarEndShiftP95, "\(report.summary)")
        #expect(report.trackChurn <= bars.maxTrackChurn, "\(report.summary)")
        #expect(report.cueIDChanges <= bars.maxCueIDChanges, "\(report.summary)")
    }

    /// Two balls resting in contact must never trade or lose identities —
    /// neither to association (each sits inside the other's 8 cm gate every
    /// frame) nor to re-identification (the one that is retired has to
    /// reclaim its own id, not its neighbour's).
    @Test func frozenPairKeepsBothIdentities() async throws {
        let directory = try fixtureDirectory(for: ScriptedFrozenPair.sessionID)
        let bundle = try SessionBundleReader().read(from: directory)
        let outputs = try await ReplayRunner().run(bundle).outputs

        // Exactly three ids for the whole clip: no ball is ever reborn.
        let ids = Set(outputs.flatMap { $0.balls.map(\.id) })
        #expect(ids.count == 3, "ids issued: \(ids.sorted())")

        // The pair really is one diameter apart and really is inside the
        // association gate — if either stops being true the test has
        // stopped testing what it is named for.
        let separation = ScriptedFrozenPair.frozenA.distance(to: ScriptedFrozenPair.frozenB)
        #expect(abs(separation - Ball.standardRadius * 2) < 1e-12)
        #expect(separation < TrackerConfig.default.gatingDistance)

        // Identity by position: the id nearest each truth ball on the first
        // fully-acquired frame is still the id nearest it on the last one.
        func identity(at frame: Int, near target: Vec2) throws -> Int {
            let record = try #require(outputs.first { $0.frame == frame })
            let ball = try #require(record.balls.min {
                Vec2($0.x, $0.y).distance(to: target) < Vec2($1.x, $1.y).distance(to: target)
            }, "frame \(frame) reported no balls")
            #expect(Vec2(ball.x, ball.y).distance(to: target) < 0.03,
                    "frame \(frame): nearest ball is \(ball.x), \(ball.y), not near \(target)")
            return ball.id
        }
        let last = ScriptedFrozenPair.frameCount - 1
        let beforeDropout = ScriptedFrozenPair.dropoutFrames.lowerBound - 1
        for target in [ScriptedFrozenPair.cuePosition,
                       ScriptedFrozenPair.frozenA, ScriptedFrozenPair.frozenB] {
            #expect(try identity(at: beforeDropout, near: target)
                    == identity(at: last, near: target),
                    "identity at \(target) changed across the dropout")
        }

        // Ball A is never dropped, so it is present on every reported frame
        // and its id never changes — the neighbour's retirement must not
        // disturb it.
        let aIDs = Set(outputs.compactMap { record in
            record.balls.min {
                Vec2($0.x, $0.y).distance(to: ScriptedFrozenPair.frozenA)
                    < Vec2($1.x, $1.y).distance(to: ScriptedFrozenPair.frozenA)
            }.flatMap {
                Vec2($0.x, $0.y).distance(to: ScriptedFrozenPair.frozenA) < 0.03 ? $0.id : nil
            }
        })
        #expect(aIDs.count == 1, "ball A changed id: \(aIDs.sorted())")

        // The dropout genuinely outlasts the grace, so this exercises
        // re-identification and not merely the miss budget.
        let dropoutSeconds = Double(ScriptedFrozenPair.dropoutFrames.count)
            / ScriptedFrozenPair.frameRate
        #expect(dropoutSeconds > TrackerConfig.default.visibleMissGrace)
        // ... and ball B really is absent from the reported state for part
        // of it, i.e. the track was retired rather than coasting.
        let bMissing = outputs.contains { record in
            record.frame > ScriptedFrozenPair.dropoutFrames.lowerBound
                && record.frame <= ScriptedFrozenPair.dropoutFrames.upperBound
                && !record.balls.contains {
                    Vec2($0.x, $0.y).distance(to: ScriptedFrozenPair.frozenB) < 0.03
                }
        }
        #expect(bMissing, "ball B never left the reported state — the dropout is too short")
    }

    /// The script's scenario actually happens in the replay: designation
    /// makes a cue ball, the stick takes the aim, the hold outlives the
    /// stick, device pose returns, the dropout ball never disappears.
    @Test func scriptedScenarioPlaysOutAsWritten() async throws {
        let directory = try fixtureDirectory(for: ScriptedFiveBall.sessionID)
        let bundle = try SessionBundleReader().read(from: directory)
        let outputs = try await ReplayRunner().run(bundle).outputs
        func output(_ frame: Int) throws -> OutputRecord {
            try #require(outputs.first { $0.frame == frame })
        }
        // Before designation: five balls tracked, none of them a cue → no aim.
        #expect(try output(4).balls.count == 5)
        #expect(try output(4).balls.allSatisfy { $0.kind == "unknown" })
        #expect(try output(4).aim == nil)
        // From the designation frame on: exactly one cue ball, an aim exists.
        for frame in ScriptedFiveBall.designateFrame..<ScriptedFiveBall.frameCount {
            let record = try output(frame)
            #expect(record.balls.filter { $0.kind == "cue" }.count == 1, "frame \(frame)")
            #expect(record.aim != nil, "frame \(frame)")
            #expect(record.balls.count == 5, "frame \(frame): dropout must not erase ball 3")
        }
        #expect(try output(ScriptedFiveBall.designateFrame).aim?.source == "devicePose")
        for frame in ScriptedFiveBall.stickFrames {
            #expect(try output(frame).stick != nil, "frame \(frame)")
            #expect(try output(frame).aim?.source == "stick", "frame \(frame)")
        }
        // 2.5 s hold at 10 Hz: frames 15…39 still stick, 40 onward device pose.
        let holdEnd = ScriptedFiveBall.stickFrames.upperBound + 25
        for frame in (ScriptedFiveBall.stickFrames.upperBound + 1)...holdEnd {
            #expect(try output(frame).stick == nil, "frame \(frame)")
            #expect(try output(frame).aim?.source == "stick", "frame \(frame)")
        }
        for frame in (holdEnd + 1)..<ScriptedFiveBall.frameCount {
            #expect(try output(frame).aim?.source == "devicePose", "frame \(frame)")
        }
        // The spurious 22 % box is listed in the raw labels but never tracked.
        #expect(try output(ScriptedFiveBall.spuriousFrame).labels.contains("color-ball 22%"))
        #expect(try output(ScriptedFiveBall.spuriousFrame).balls.count == 5)
        // Called pocket toggles on at frame 18 and stays.
        #expect(try output(ScriptedFiveBall.callPocketFrame - 1).calledPocket == nil)
        #expect(try output(ScriptedFiveBall.callPocketFrame).calledPocket == "cornerTopRight")
        #expect(try output(ScriptedFiveBall.frameCount - 1).calledPocket == "cornerTopRight")
    }
}
