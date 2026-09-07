import CueSyncCore
import Foundation
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

/// Every committed golden bundle and its accuracy bars.
private struct GoldenBundle {
    let name: String
    let warmupFrames: Int
    let maxPositionRMS: Double
    let minRecall: Double
    let minPrecision: Double
}

private let goldenBundles: [GoldenBundle] = [
    // Appearance gate is 3 frames, so frames 0–2 legitimately report nothing.
    GoldenBundle(name: "scripted-5ball", warmupFrames: 3,
                 maxPositionRMS: 0.02, minRecall: 0.98, minPrecision: 0.98)
]

private let fixturesSubdirectory = "Fixtures/Sessions"

private func fixtureDirectory(for name: String) throws -> URL {
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

    /// scripted-5ball is generated code (ScriptedFiveBall) — the committed
    /// input files must be exactly what the generator writes today.
    @Test func committedInputsMatchTheGenerator() throws {
        let directory = try fixtureDirectory(for: ScriptedFiveBall.sessionID)
        let expected = SessionBundleWriter.inputTexts(for: ScriptedFiveBall.makeBundle())
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
        if name == ScriptedFiveBall.sessionID {
            try SessionBundleWriter().write(ScriptedFiveBall.makeBundle(), to: target)
        }
        let bundle = try SessionBundleReader().read(from: target)
        let result = try await ReplayRunner().run(bundle)
        try SessionBundleWriter().writeOutputs(result.outputs, to: target)
        Issue.record("regenerated \(target.path) — review the diff before committing")
    }

    @Test(arguments: goldenBundles.map(\.name))
    func accuracyClearsTheBars(name: String) async throws {
        let golden = try #require(goldenBundles.first { $0.name == name })
        let directory = try fixtureDirectory(for: name)
        let bundle = try SessionBundleReader().read(from: directory)
        let truth = try #require(bundle.truth, "\(name) has no truth.json")
        let result = try await ReplayRunner().run(bundle)
        let report = AccuracyReport.compute(outputs: result.outputs, truth: truth,
                                            warmupFrames: golden.warmupFrames)
        #expect(report.positionRMS <= golden.maxPositionRMS, "\(report.summary)")
        #expect(report.recall >= golden.minRecall, "\(report.summary)")
        #expect(report.precision >= golden.minPrecision, "\(report.summary)")
        #expect(report.identitySwitches == 0, "\(report.summary)")
        #expect(report.trackChurn == 0, "\(report.summary)")
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
