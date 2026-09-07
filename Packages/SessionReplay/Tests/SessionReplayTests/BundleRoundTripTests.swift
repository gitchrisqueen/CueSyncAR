import CueSyncCore
import Foundation
import TableSpace
import Testing
@testable import SessionReplay

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionReplayTests-\(name)-\(UInt64.random(in: 0...UInt64.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SessionBundle — write / read round trip")
struct BundleRoundTripTests {
    @Test func writtenBundleReadsBackEqualAndReserializesByteEqual() throws {
        let bundle = ScriptedFiveBall.makeBundle()
        let directory = try temporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        try SessionBundleWriter().write(bundle, to: directory)
        let reread = try SessionBundleReader().read(from: directory)

        // Values pass through the six-decimal grid, so the structures are
        // equal only after one round trip — but the TEXT is a fixed point.
        let firstTexts = SessionBundleWriter.inputTexts(for: bundle)
        let secondTexts = SessionBundleWriter.inputTexts(for: reread)
        #expect(firstTexts == secondTexts)
        #expect(reread.manifest == bundle.manifest)
        #expect(reread.frames.count == bundle.frames.count)
        #expect(reread.events == bundle.events)
        #expect(reread.truth != nil)

        // Every expected file exists; no outputs yet; no video needed.
        for file in SessionBundleFile.required + [.truth] {
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file.rawValue).path), "\(file.rawValue)")
        }
        #expect(try SessionBundleReader().outputsData(in: directory) == nil)
        #expect(reread.manifest.video == nil)
    }

    @Test func truthIsOptional() throws {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.truth = nil
        let directory = try temporaryDirectory("notruth")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionBundleWriter().write(bundle, to: directory)
        let reread = try SessionBundleReader().read(from: directory)
        #expect(reread.truth == nil)
    }

    @Test func missingRequiredFileIsReported() throws {
        let bundle = ScriptedFiveBall.makeBundle()
        let directory = try temporaryDirectory("missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionBundleWriter().write(bundle, to: directory)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(SessionBundleFile.detections.rawValue))
        #expect(throws: SessionBundleError.missingFile("detections.jsonl")) {
            try SessionBundleReader().read(from: directory)
        }
    }

    @Test func malformedLineIsReportedWithItsLineNumber() throws {
        let bundle = ScriptedFiveBall.makeBundle()
        let directory = try temporaryDirectory("malformed")
        defer { try? FileManager.default.removeItem(at: directory) }
        try SessionBundleWriter().write(bundle, to: directory)
        let url = directory.appendingPathComponent(SessionBundleFile.events.rawValue)
        var text = try String(contentsOf: url, encoding: .utf8)
        text += "\r\n{not json}\n"
        try Data(text.utf8).write(to: url)
        #expect(throws: SessionBundleError.malformedLine(file: "events.jsonl", line: 5)) {
            try SessionBundleReader().read(from: directory)
        }
    }

    @Test func outputsRoundTrip() throws {
        let directory = try temporaryDirectory("outputs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = OutputRecord(
            frame: 3, timestamp: 100.3,
            balls: [OutputBall(Ball(id: BallID(4), kind: .solid(2), position: Vec2(0.1, -0.2),
                                    confidence: 0.91))],
            stick: [[0, 0], [1, 0], [1, 0.1], [0, 0.1]],
            labels: ["color-ball 91%"],
            aim: nil, prediction: nil, planChanged: false,
            calledPocket: "sideTop", calledShotOnLine: false)
        try SessionBundleWriter().writeOutputs([record], to: directory)
        let reread = try #require(try SessionBundleReader().outputs(in: directory))
        #expect(reread == [record])
        let data = try #require(try SessionBundleReader().outputsData(in: directory))
        #expect(Data(SessionBundleWriter.outputsText([record]).utf8) == data)
    }
}

@Suite("SessionBundle — validation")
struct BundleValidationTests {
    @Test func acceptsTheScriptedBundle() throws {
        try ScriptedFiveBall.makeBundle().validate()
    }

    @Test func rejectsWrongSchemaVersion() {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.manifest.schemaVersion = 99
        #expect(throws: SessionBundleError.unsupportedSchemaVersion(99)) { try bundle.validate() }
    }

    @Test func rejectsFrameCountMismatch() {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.manifest.frameCount = 3
        #expect(throws: SessionBundleError.frameCountMismatch(manifest: 3, frames: 45)) {
            try bundle.validate()
        }
    }

    @Test func rejectsUnorderedFramesAndDuplicateTimestamps() {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.frames.swapAt(0, 1)
        #expect(throws: SessionBundleError.framesNotIndexOrdered) { try bundle.validate() }

        var duplicated = ScriptedFiveBall.makeBundle()
        duplicated.frames[1].timestamp = duplicated.frames[0].timestamp
        #expect(throws: SessionBundleError.duplicateTimestamp(duplicated.frames[0].timestamp)) {
            try duplicated.validate()
        }
    }

    @Test func rejectsDetectionsForUnknownFrames() {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.detections.append(RecordedDetectionFrame(frame: 77, timestamp: 1, detections: []))
        #expect(throws: SessionBundleError.detectionsForUnknownFrame(77)) { try bundle.validate() }
    }

    @Test func rejectsMalformedTransformsAndCalibrations() {
        var bundle = ScriptedFiveBall.makeBundle()
        bundle.frames[2].cameraTransform = [1, 2, 3]
        #expect(throws: SessionBundleError.invalidTransform(2)) { try bundle.validate() }

        var badSize = ScriptedFiveBall.makeBundle()
        badSize.calibration.size = RecordedCalibration.Size(name: "pocketBilliards")
        #expect(throws: SessionBundleError.invalidCalibration("unknown table size 'pocketBilliards'")) {
            try badSize.validate()
        }
        var customNoDims = ScriptedFiveBall.makeBundle()
        customNoDims.calibration.size = RecordedCalibration.Size(name: "custom")
        #expect(throws: SessionBundleError.self) { try customNoDims.validate() }
        var skewed = ScriptedFiveBall.makeBundle()
        skewed.calibration.yAxis = [1, 0, 0]
        #expect(throws: SessionBundleError.self) { try skewed.validate() }
    }

    @Test func calibrationConvertsBothWaysIncludingCustomSizes() throws {
        let custom = TableCalibration(origin: Vec3(1, 2, 3), xAxis: Vec3(0, 0, 1),
                                      yAxis: Vec3(1, 0, 0),
                                      size: .custom(width: 2.2, height: 1.1))
        let recorded = RecordedCalibration(custom)
        #expect(recorded.size.name == "custom")
        #expect(try recorded.tableCalibration() == custom)
        for size in TableSize.standardSizes {
            let calibration = TableCalibration(origin: .zero, xAxis: Vec3(1, 0, 0),
                                               yAxis: Vec3(0, 0, -1), size: size)
            #expect(try RecordedCalibration(calibration).tableCalibration() == calibration)
        }
    }

    @Test func frameMetaConvertsBothWays() throws {
        let frame = ScriptedFiveBall.capturedFrame(4)
        let meta = RecordedFrameMeta(index: 4, frame: frame)
        #expect(meta.cameraTransform.count == 16)
        #expect(meta.image == RecordedImageInfo(width: 1920, height: 1440))
        let restored = try meta.capturedFrame()
        #expect(restored.timestamp == frame.timestamp)
        #expect(restored.cameraTransform == frame.cameraTransform)
        #expect(restored.intrinsics == frame.intrinsics)
        #expect(restored.image?.width == 1920)
        #expect(restored.image?.height == 1440)
    }

    @Test func detectionConvertsBothWays() {
        let detection = Detection2D(classLabel: "white-ball",
                                    boundingBox: NormalizedRect(x: 0.1, y: 0.2, width: 0.03, height: 0.04),
                                    confidence: 0.77)
        #expect(RecordedDetection(detection).detection2D == detection)
    }
}

@Suite("KindLabel")
struct KindLabelTests {
    @Test(arguments: [Ball.Kind.cue, .eight, .solid(1), .solid(7), .stripe(9), .stripe(15), .unknown])
    func roundTrips(kind: Ball.Kind) {
        #expect(KindLabel.kind(for: KindLabel.label(for: kind)) == kind)
    }

    @Test func unknownLabelsNeverTrap() {
        #expect(KindLabel.kind(for: "solid-8") == .unknown)
        #expect(KindLabel.kind(for: "stripe-3") == .unknown)
        #expect(KindLabel.kind(for: "banana") == .unknown)
        #expect(KindLabel.kind(for: "eight") == .eight)
    }
}
