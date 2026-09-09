//
//  RealBundleStabilityTests.swift
//  SessionReplayTests
//
//  Prints the stability report for whatever real bundle is pointed at by
//  CUESYNC_REPLAY_BUNDLE. Not a gate — a measuring instrument, so a PR can
//  quote before/after numbers from the operator's own table.
//

import Foundation
import Testing
@testable import SessionReplay

@Suite("Real bundle stability")
struct RealBundleStabilityTests {
    @Test("Report stability for CUESYNC_REPLAY_BUNDLE, when set")
    func reportStability() async throws {
        guard let path = ProcessInfo.processInfo.environment["CUESYNC_REPLAY_BUNDLE"] else {
            print("RealBundleStability: CUESYNC_REPLAY_BUNDLE unset — skipping")
            return
        }
        let bundle = try SessionBundleReader()
            .read(from: URL(fileURLWithPath: path, isDirectory: true))
        let result = try await ReplayRunner().run(bundle)
        let report = StabilityReport.compute(outputs: result.outputs)
        print("StabilityReport [\(URL(fileURLWithPath: path).lastPathComponent)]")
        print("  frames \(report.frames) over \(String(format: "%.0f", report.seconds))s, "
              + "dropped \(result.droppedFrames.count)")
        print("  " + report.summary)
        #expect(report.frames > 0)
    }
}
