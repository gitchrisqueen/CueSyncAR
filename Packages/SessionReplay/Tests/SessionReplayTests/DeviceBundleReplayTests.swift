import Foundation
import Testing
@testable import SessionReplay

// The acceptance check for a bundle recorded ON THE DEVICE, runnable on
// macOS and Linux with no hardware:
//
//     CUESYNC_REPLAY_BUNDLE=Sessions/device-20260907T213045Z \
//         swift test --package-path Packages/SessionReplay --filter DeviceBundleReplay
//
// It reads the bundle, verifies every file against the manifest's sha256
// map, validates the structure, replays it twice in-process (byte-equal),
// and then either compares against an existing outputs.jsonl next to it
// (byte-equal — run once on macOS to write it, once on Linux to prove
// it) or writes that golden. Without the variable the suite passes with a
// note, so CI is unaffected.

private var bundlePath: String? {
    ProcessInfo.processInfo.environment["CUESYNC_REPLAY_BUNDLE"]
}

@Suite("DeviceBundleReplay — replay a recorded bundle byte-equal")
struct DeviceBundleReplayTests {
    @Test func recordedBundleReplaysByteEqual() async throws {
        guard let path = bundlePath else {
            // Swift Testing on the 6.1 toolchain has no skip/warning
            // severity; a note on stdout is the honest alternative.
            print("DeviceBundleReplay: no CUESYNC_REPLAY_BUNDLE set — nothing to replay (not a failure)")
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let bundle = try SessionBundleReader().read(from: directory)
        if bundle.manifest.files != nil {
            let verified = try SessionBundleIntegrity.verify(directory: directory)
            #expect(!verified.isEmpty)
        }
        #expect(bundle.frames.count == bundle.manifest.frameCount)
        #expect(!bundle.detections.isEmpty, "a recording with no detections cannot judge anything")

        let first = try await ReplayRunner().run(bundle)
        let second = try await ReplayRunner().run(bundle)
        #expect(first.outputsText == second.outputsText, "replay is not deterministic in-process")
        #expect(first.outputs.count + first.droppedFrames.count == bundle.frames.count)

        let goldenURL = directory.appendingPathComponent(SessionBundleFile.outputs.rawValue)
        if let golden = try SessionBundleReader().outputsData(in: directory) {
            #expect(golden == first.outputsData,
                    "outputs.jsonl differs from this platform's replay — cross-platform byte-equality broken")
        } else {
            try SessionBundleWriter().writeOutputs(first.outputs, to: directory)
            print("DeviceBundleReplay: wrote golden \(goldenURL.path) "
                  + "(\(first.outputs.count) frames, \(first.droppedFrames.count) dropped); "
                  + "re-run on the other platform to prove byte-equality")
        }
    }
}
