//
//  SessionBundle.swift
//  SessionReplay
//
//  The in-memory bundle plus its reader and writer. Reading uses
//  JSONDecoder (parsing is exact on every platform); writing goes through
//  CanonicalJSON only. Files are plain text under one directory so a bundle
//  is diffable, git-friendly and inspectable with `jq`.
//

import Foundation

public enum SessionBundleFile: String, CaseIterable, Sendable {
    case manifest = "manifest.json"
    case calibration = "calibration.json"
    case frames = "frames.jsonl"
    case detections = "detections.jsonl"
    case events = "events.jsonl"
    case truth = "truth.json"
    case outputs = "outputs.jsonl"
    /// Device recordings only: ~1 Hz overlay-projection snapshots
    /// (RecordedSnapshot). Optional; scripted bundles have none.
    case snapshots = "snapshots.jsonl"

    /// Files a bundle must contain to replay. `truth` is needed only for
    /// AccuracyReport, `outputs` only exists once a golden was recorded.
    public static let required: [SessionBundleFile] = [.manifest, .calibration, .frames,
                                                       .detections, .events]
}

public enum SessionBundleError: Error, Equatable {
    case missingFile(String)
    case malformedLine(file: String, line: Int)
    case invalidEncoding(String)
    case unsupportedSchemaVersion(Int)
    case frameCountMismatch(manifest: Int, frames: Int)
    case framesNotIndexOrdered
    case duplicateTimestamp(Double)
    case detectionsForUnknownFrame(Int)
    case invalidCalibration(String)
    case invalidTransform(Int)
    /// manifest.json carries no `files` hashes to verify against.
    case manifestWithoutHashes
    /// A hashed file is missing from the directory.
    case integrityFileMissing(String)
    /// A file's bytes do not match the manifest's sha256.
    case integrityMismatch(String)
}

public struct SessionBundle: Sendable, Equatable {
    public var manifest: SessionManifest
    public var calibration: RecordedCalibration
    public var frames: [RecordedFrameMeta]
    public var detections: [RecordedDetectionFrame]
    public var events: [RecordedEvent]
    public var truth: SessionTruth?
    /// Overlay-projection snapshots (device recordings); empty otherwise.
    public var snapshots: [RecordedSnapshot]

    public init(manifest: SessionManifest, calibration: RecordedCalibration,
                frames: [RecordedFrameMeta], detections: [RecordedDetectionFrame],
                events: [RecordedEvent], truth: SessionTruth? = nil,
                snapshots: [RecordedSnapshot] = []) {
        self.manifest = manifest
        self.calibration = calibration
        self.frames = frames
        self.detections = detections
        self.events = events
        self.truth = truth
        self.snapshots = snapshots
    }

    /// Structural checks a replay relies on: schema version, frames in
    /// ascending index order with unique timestamps, detections attached
    /// to known frames, manifest count honest.
    public func validate() throws {
        guard manifest.schemaVersion == SessionBundleSchema.version else {
            throw SessionBundleError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard manifest.frameCount == frames.count else {
            throw SessionBundleError.frameCountMismatch(manifest: manifest.frameCount,
                                                        frames: frames.count)
        }
        var seenTimestamps = Set<Double>()
        var lastIndex = Int.min
        for frame in frames {
            guard frame.index > lastIndex else { throw SessionBundleError.framesNotIndexOrdered }
            lastIndex = frame.index
            guard seenTimestamps.insert(frame.timestamp).inserted else {
                throw SessionBundleError.duplicateTimestamp(frame.timestamp)
            }
            _ = try frame.transform3D()
        }
        let indices = Set(frames.map(\.index))
        for detected in detections where !indices.contains(detected.frame) {
            throw SessionBundleError.detectionsForUnknownFrame(detected.frame)
        }
        _ = try calibration.tableCalibration()
    }
}

// MARK: - Reader

public struct SessionBundleReader: Sendable {
    public init() {}

    /// Load and validate the bundle at `directory`. A bundle without
    /// `truth.json` loads with `truth == nil`; without video it is simply
    /// a bundle (nothing here reads pixels).
    public func read(from directory: URL) throws -> SessionBundle {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(SessionManifest.self,
                                          from: try data(for: .manifest, in: directory))
        let calibration = try decoder.decode(RecordedCalibration.self,
                                             from: try data(for: .calibration, in: directory))
        let frames: [RecordedFrameMeta] = try Self.decodeLines(
            try data(for: .frames, in: directory), file: .frames)
        let detections: [RecordedDetectionFrame] = try Self.decodeLines(
            try data(for: .detections, in: directory), file: .detections)
        let events: [RecordedEvent] = try Self.decodeLines(
            try data(for: .events, in: directory), file: .events)
        var truth: SessionTruth?
        if let truthData = try? data(for: .truth, in: directory) {
            truth = try decoder.decode(SessionTruth.self, from: truthData)
        }
        var snapshots: [RecordedSnapshot] = []
        if let snapshotData = try? data(for: .snapshots, in: directory) {
            snapshots = try Self.decodeLines(snapshotData, file: .snapshots)
        }
        let bundle = SessionBundle(manifest: manifest, calibration: calibration,
                                   frames: frames, detections: detections,
                                   events: events, truth: truth, snapshots: snapshots)
        try bundle.validate()
        return bundle
    }

    /// The committed golden, byte-for-byte, or nil when none is recorded.
    public func outputsData(in directory: URL) throws -> Data? {
        let url = directory.appendingPathComponent(SessionBundleFile.outputs.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Decode a committed outputs.jsonl (for reports over a golden).
    public func outputs(in directory: URL) throws -> [OutputRecord]? {
        guard let data = try outputsData(in: directory) else { return nil }
        return try Self.decodeLines(data, file: .outputs)
    }

    private func data(for file: SessionBundleFile, in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent(file.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionBundleError.missingFile(file.rawValue)
        }
        return try Data(contentsOf: url)
    }

    /// JSONL: one JSON document per line; blank lines ignored; CRLF tolerated.
    static func decodeLines<T: Decodable>(_ data: Data, file: SessionBundleFile) throws -> [T] {
        let decoder = JSONDecoder()
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw SessionBundleError.invalidEncoding(file.rawValue)
        }
        var records: [T] = []
        var lineNumber = 0
        // Swift treats "\r\n" as ONE Character, so split on either ending.
        for line in text.split(omittingEmptySubsequences: false,
                               whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            do {
                records.append(try decoder.decode(T.self, from: Data(line.utf8)))
            } catch {
                throw SessionBundleError.malformedLine(file: file.rawValue, line: lineNumber)
            }
        }
        return records
    }
}

// MARK: - Writer

public struct SessionBundleWriter: Sendable {
    public init() {}

    /// Write every input file of `bundle` into `directory` (created if
    /// needed), each in canonical form. Does not touch outputs.jsonl —
    /// see `writeOutputs`.
    public func write(_ bundle: SessionBundle, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (file, text) in Self.inputTexts(for: bundle) {
            try Self.write(text, to: directory.appendingPathComponent(file.rawValue))
        }
    }

    /// Record (or refresh) the golden for `directory`.
    public func writeOutputs(_ outputs: [OutputRecord], to directory: URL) throws {
        try Self.write(Self.outputsText(outputs),
                       to: directory.appendingPathComponent(SessionBundleFile.outputs.rawValue))
    }

    /// The canonical text of each input file, keyed by file.
    public static func inputTexts(for bundle: SessionBundle) -> [SessionBundleFile: String] {
        var texts: [SessionBundleFile: String] = [
            .manifest: CanonicalJSON.serialize(bundle.manifest.canonical()) + "\n",
            .calibration: CanonicalJSON.serialize(bundle.calibration.canonical()) + "\n",
            .frames: CanonicalJSON.serializeLines(bundle.frames.map { $0.canonical() }),
            .detections: CanonicalJSON.serializeLines(bundle.detections.map { $0.canonical() }),
            .events: CanonicalJSON.serializeLines(bundle.events.map { $0.canonical() })
        ]
        if let truth = bundle.truth {
            texts[.truth] = CanonicalJSON.serialize(truth.canonical()) + "\n"
        }
        if !bundle.snapshots.isEmpty {
            texts[.snapshots] = CanonicalJSON.serializeLines(bundle.snapshots.map { $0.canonical() })
        }
        return texts
    }

    /// Canonical outputs.jsonl text — the bytes the golden test compares.
    public static func outputsText(_ outputs: [OutputRecord]) -> String {
        CanonicalJSON.serializeLines(outputs.map { $0.canonical() })
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}
