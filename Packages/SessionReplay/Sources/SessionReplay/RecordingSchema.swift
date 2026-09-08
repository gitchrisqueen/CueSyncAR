//
//  RecordingSchema.swift
//  SessionReplay
//
//  The parts of the bundle schema that only a DEVICE recording fills in:
//  the manifest's `recording` block (which build, which model, what
//  display, what cadence), the ~1 Hz overlay-projection snapshots, and the
//  integrity check over the manifest's per-file sha256 map. Everything
//  here is pure Foundation so the reader side runs on Linux; the writer
//  side is SessionBundleRecorder.
//
//  Privacy rule for every field: nothing host-specific or personally
//  identifying — no device names, user names, addresses or absolute paths.
//  Hardware model ("iPhone17,1") and OS version are hardware class, not
//  identity, and matter because camera intrinsics differ per model.
//

import ARExperience
import CueSyncCore
import Foundation

// MARK: - Manifest: recording block

public struct RecordingInfo: Sendable, Equatable, Codable {
    /// Git identity of the build that recorded (from the app's build-identity
    /// stamp — `unknown` when the stamp is missing, never re-derived).
    public var appCommit: String
    public var appBranch: String
    public var appDirty: Bool
    public var appVersion: String
    /// "on-device" or "hosted".
    public var detector: String
    /// Bundled model resource name and the sha256 of its compiled directory.
    public var modelName: String?
    public var modelSHA256: String?
    /// Hardware class ("iPad13,18") and OS version ("26.0").
    public var hardwareModel: String
    public var systemVersion: String
    /// Points-to-pixels scale of the display, and the ARView's size in points
    /// — with the camera intrinsics, enough to reproduce `arView.project`.
    public var displayScale: Double
    public var viewWidth: Double
    public var viewHeight: Double
    /// Camera image size in pixels (what frames.jsonl intrinsics refer to).
    public var nativeWidth: Int
    public var nativeHeight: Int
    /// The app loop's sleep between ticks; frames are pulled at most once per tick.
    public var tickMilliseconds: Int
    public var snapshotIntervalSeconds: Double
    /// The recording cap and how long this one actually ran.
    public var capSeconds: Int
    public var durationSeconds: Double
    /// Video bookkeeping (`videoFrames` = frames whose pixels made it).
    public var videoCodec: String?
    public var videoFrames: Int
    public var videoDroppedFrames: Int
    /// Live settings in force, so ReplayConfig can match them.
    public var guideSpeed: Double
    public var visibleMissGrace: Double
    public var practiceMode: String
    /// Whether overlays were rendered in the machine-readable metric palette.
    public var metricPalette: Bool
    /// B3 A/B switch in force: whether the live pipeline re-derived the
    /// calibration from the table anchor each frame. The replay honours it.
    public var followsTableAnchor: Bool
    /// "user" | "cap" | "error: <short reason>".
    public var stopReason: String

    public init(appCommit: String, appBranch: String, appDirty: Bool, appVersion: String,
                detector: String, modelName: String? = nil, modelSHA256: String? = nil,
                hardwareModel: String, systemVersion: String,
                displayScale: Double, viewWidth: Double, viewHeight: Double,
                nativeWidth: Int, nativeHeight: Int,
                tickMilliseconds: Int, snapshotIntervalSeconds: Double,
                capSeconds: Int, durationSeconds: Double,
                videoCodec: String? = nil, videoFrames: Int, videoDroppedFrames: Int,
                guideSpeed: Double, visibleMissGrace: Double, practiceMode: String,
                metricPalette: Bool, followsTableAnchor: Bool = true, stopReason: String) {
        self.appCommit = appCommit
        self.appBranch = appBranch
        self.appDirty = appDirty
        self.appVersion = appVersion
        self.detector = detector
        self.modelName = modelName
        self.modelSHA256 = modelSHA256
        self.hardwareModel = hardwareModel
        self.systemVersion = systemVersion
        self.displayScale = displayScale
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.tickMilliseconds = tickMilliseconds
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.capSeconds = capSeconds
        self.durationSeconds = durationSeconds
        self.videoCodec = videoCodec
        self.videoFrames = videoFrames
        self.videoDroppedFrames = videoDroppedFrames
        self.guideSpeed = guideSpeed
        self.visibleMissGrace = visibleMissGrace
        self.practiceMode = practiceMode
        self.metricPalette = metricPalette
        self.followsTableAnchor = followsTableAnchor
        self.stopReason = stopReason
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = [
            "appCommit": .string(appCommit), "appBranch": .string(appBranch),
            "appDirty": .bool(appDirty), "appVersion": .string(appVersion),
            "detector": .string(detector),
            "hardwareModel": .string(hardwareModel), "systemVersion": .string(systemVersion),
            "displayScale": .double(displayScale),
            "viewWidth": .double(viewWidth), "viewHeight": .double(viewHeight),
            "nativeWidth": .int(nativeWidth), "nativeHeight": .int(nativeHeight),
            "tickMilliseconds": .int(tickMilliseconds),
            "snapshotIntervalSeconds": .double(snapshotIntervalSeconds),
            "capSeconds": .int(capSeconds), "durationSeconds": .double(durationSeconds),
            "videoFrames": .int(videoFrames), "videoDroppedFrames": .int(videoDroppedFrames),
            "guideSpeed": .double(guideSpeed), "visibleMissGrace": .double(visibleMissGrace),
            "practiceMode": .string(practiceMode),
            "metricPalette": .bool(metricPalette), "followsTableAnchor": .bool(followsTableAnchor),
            "stopReason": .string(stopReason)
        ]
        if let modelName { object["modelName"] = .string(modelName) }
        if let modelSHA256 { object["modelSHA256"] = .string(modelSHA256) }
        if let videoCodec { object["videoCodec"] = .string(videoCodec) }
        return .object(object)
    }
}

// MARK: - Snapshots

/// Camera + table-anchor pose at one instant (16 doubles column-major
/// each, the `Transform3D.columns` flattening; anchor nil before lock).
public struct SnapshotPose: Sendable, Equatable, Codable {
    public var frameTimestamp: TimeInterval
    public var cameraTransform: [Double]
    public var tableAnchorTransform: [Double]?

    public init(frameTimestamp: TimeInterval, cameraTransform: [Double],
                tableAnchorTransform: [Double]? = nil) {
        self.frameTimestamp = frameTimestamp
        self.cameraTransform = cameraTransform
        self.tableAnchorTransform = tableAnchorTransform
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = [
            "frameTimestamp": .double(frameTimestamp),
            "cameraTransform": .doubles(cameraTransform)
        ]
        if let tableAnchorTransform {
            object["tableAnchorTransform"] = .doubles(tableAnchorTransform)
        }
        return .object(object)
    }
}

/// One rendered overlay marker and where the renderer projected it.
public struct SnapshotMarker: Sendable, Equatable, Codable {
    /// ARExperience.RenderedMarkerKind raw value: "ball" | "cueBall" |
    /// "ghostBall" | "pocket" | "calledPocket" | "strip" (a strip's midpoint).
    public var kind: String
    /// Ball index / strip's ball id / pocket index where one exists.
    public var id: Int?
    /// World-space position handed to the renderer (meters).
    public var world: [Double]
    /// `arView.project` result in view POINTS; nil when behind the camera.
    public var screen: [Double]?

    public init(kind: String, id: Int? = nil, world: [Double], screen: [Double]? = nil) {
        self.kind = kind
        self.id = id
        self.world = world
        self.screen = screen
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind), "world": .doubles(world)]
        if let id { object["id"] = .int(id) }
        if let screen { object["screen"] = .doubles(screen) }
        return .object(object)
    }
}

/// A bracketed projection snapshot: pose read BEFORE projecting every
/// marker, the projections, pose read AFTER. When `poseStable` the two
/// poses are identical and an offline projection of `markers[].world`
/// through the before-pose must land on `markers[].screen`; when not, the
/// device moved mid-snapshot and the record is a bound, not a truth.
public struct RecordedSnapshot: Sendable, Equatable, Codable {
    public var index: Int
    /// Latest recorded frame index when the snapshot was taken (-1: none yet).
    public var frame: Int
    public var before: SnapshotPose
    public var after: SnapshotPose
    public var poseStable: Bool
    /// View size in points, display scale and interface orientation.
    public var viewWidth: Double
    public var viewHeight: Double
    public var displayScale: Double
    public var interfaceOrientation: String
    /// ARKit display transform (normalized image → normalized view) as the
    /// six affine components [a, b, c, d, tx, ty]; nil when unavailable.
    public var displayTransform: [Double]?
    public var metricPalette: Bool
    public var markers: [SnapshotMarker]

    public init(index: Int, frame: Int, before: SnapshotPose, after: SnapshotPose,
                viewWidth: Double, viewHeight: Double, displayScale: Double,
                interfaceOrientation: String, displayTransform: [Double]? = nil,
                metricPalette: Bool, markers: [SnapshotMarker]) {
        self.index = index
        self.frame = frame
        self.before = before
        self.after = after
        self.poseStable = before.cameraTransform == after.cameraTransform
            && before.tableAnchorTransform == after.tableAnchorTransform
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.displayScale = displayScale
        self.interfaceOrientation = interfaceOrientation
        self.displayTransform = displayTransform
        self.metricPalette = metricPalette
        self.markers = markers
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(index),
            "frame": .int(frame),
            "before": before.canonical(),
            "after": after.canonical(),
            "poseStable": .bool(poseStable),
            "viewWidth": .double(viewWidth),
            "viewHeight": .double(viewHeight),
            "displayScale": .double(displayScale),
            "interfaceOrientation": .string(interfaceOrientation),
            "metricPalette": .bool(metricPalette),
            "markers": .array(markers.map { $0.canonical() })
        ]
        if let displayTransform { object["displayTransform"] = .doubles(displayTransform) }
        return .object(object)
    }
}

extension SnapshotPose {
    public init(_ sample: PoseSample) {
        self.init(frameTimestamp: sample.frameTimestamp,
                  cameraTransform: sample.cameraTransform.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] },
                  tableAnchorTransform: sample.tableAnchorTransform.map {
                      $0.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }
                  })
    }
}

extension RecordedSnapshot {
    /// The bundle record of an ARExperience projection snapshot.
    public init(index: Int, frame: Int, projection: ProjectionSnapshot) {
        self.init(index: index, frame: frame,
                  before: SnapshotPose(projection.before),
                  after: SnapshotPose(projection.after),
                  viewWidth: projection.viewport.width,
                  viewHeight: projection.viewport.height,
                  displayScale: projection.viewport.displayScale,
                  interfaceOrientation: projection.viewport.interfaceOrientation,
                  displayTransform: projection.displayTransform,
                  metricPalette: projection.paletteMode == .metric,
                  markers: projection.markers.map { projected in
                      SnapshotMarker(kind: projected.marker.kind.rawValue,
                                     id: projected.marker.id,
                                     world: [projected.marker.world.x, projected.marker.world.y,
                                             projected.marker.world.z],
                                     screen: projected.screen.map { [$0.x, $0.y] })
                  })
    }
}

// MARK: - Integrity

public enum SessionBundleIntegrity {
    /// Verify every file named in manifest.json's `files` map against the
    /// bytes on disk. Returns the verified file names (sorted). Throws the
    /// first missing or mismatching file, or `manifestWithoutHashes` for a
    /// bundle that was never hashed (scripted bundles).
    @discardableResult
    public static func verify(directory: URL) throws -> [String] {
        let manifestURL = directory.appendingPathComponent(SessionBundleFile.manifest.rawValue)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SessionBundleError.missingFile(SessionBundleFile.manifest.rawValue)
        }
        let manifest = try JSONDecoder().decode(SessionManifest.self,
                                                from: try Data(contentsOf: manifestURL))
        guard let files = manifest.files, !files.isEmpty else {
            throw SessionBundleError.manifestWithoutHashes
        }
        var verified: [String] = []
        for name in files.keys.sorted() {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SessionBundleError.integrityFileMissing(name)
            }
            guard try SHA256.hexDigest(ofFileAt: url) == files[name] else {
                throw SessionBundleError.integrityMismatch(name)
            }
            verified.append(name)
        }
        return verified
    }

    /// sha256 of every regular file directly inside `directory` except
    /// manifest.json itself, keyed by file name.
    public static func hashFiles(in directory: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard name != SessionBundleFile.manifest.rawValue, !name.hasPrefix(".") else { continue }
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            hashes[name] = try SHA256.hexDigest(ofFileAt: url)
        }
        return hashes
    }
}
