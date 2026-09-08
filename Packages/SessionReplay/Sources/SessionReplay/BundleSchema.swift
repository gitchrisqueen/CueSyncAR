//
//  BundleSchema.swift
//  SessionReplay
//
//  The Codable record types of a session bundle and their conversions to
//  and from the CueSyncCore domain types. The wire schema is deliberately
//  its OWN set of flat structs rather than the domain types' synthesized
//  Codable shapes: bundles outlive contract details (and Core's enums with
//  associated values encode unreadably). Decoding uses JSONDecoder; every
//  write goes through `canonical()` → CanonicalJSON so the bytes never
//  depend on an encoder's formatting choices.
//

import CueSyncCore
import Foundation
import TableSpace

// MARK: - Manifest

public struct SessionManifest: Sendable, Equatable, Codable {
    public struct VideoInfo: Sendable, Equatable, Codable {
        public var fileName: String
        public var width: Int
        public var height: Int

        public init(fileName: String, width: Int, height: Int) {
            self.fileName = fileName
            self.width = width
            self.height = height
        }
    }

    public var schemaVersion: Int
    /// Stable identifier chosen by the recorder (never a random UUID —
    /// bundles must be reproducible byte-for-byte).
    public var sessionID: String
    /// ISO-8601 text supplied by the recorder; scripted bundles use a
    /// fixed literal.
    public var recordedAt: String
    /// "scripted" for generated bundles, "device" for on-device captures.
    public var source: String
    public var description: String
    public var frameCount: Int
    /// Present only when the bundle carries video; a bundle without video
    /// is fully valid (frames carry pose + intrinsics, detections carry
    /// boxes — nothing in the replay needs pixels).
    public var video: VideoInfo?
    /// How the bundle was captured on a device (build, model, display,
    /// cadence). Absent on scripted bundles.
    public var recording: RecordingInfo?
    /// sha256 (lower-case hex) of every other file in the bundle, keyed by
    /// file name — what `SessionBundleIntegrity` and Scripts/pull-session.sh
    /// verify. Absent on scripted bundles (the generator is their proof).
    public var files: [String: String]?

    public init(sessionID: String, recordedAt: String, source: String,
                description: String, frameCount: Int, video: VideoInfo? = nil,
                recording: RecordingInfo? = nil, files: [String: String]? = nil,
                schemaVersion: Int = SessionBundleSchema.version) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.source = source
        self.description = description
        self.frameCount = frameCount
        self.video = video
        self.recording = recording
        self.files = files
    }

    func canonical() -> JSONValue {
        var video: JSONValue = .null
        if let info = self.video {
            video = .object(["fileName": .string(info.fileName),
                             "width": .int(info.width),
                             "height": .int(info.height)])
        }
        var object: [String: JSONValue] = [
            "schemaVersion": .int(schemaVersion),
            "sessionID": .string(sessionID),
            "recordedAt": .string(recordedAt),
            "source": .string(source),
            "description": .string(description),
            "frameCount": .int(frameCount),
            "video": video
        ]
        // Optional blocks are omitted (not null) when absent so scripted
        // bundles written before they existed stay byte-identical.
        if let recording { object["recording"] = recording.canonical() }
        if let files {
            object["files"] = .object(files.mapValues(JSONValue.string))
        }
        return .object(object)
    }
}

// MARK: - Calibration

public struct RecordedCalibration: Sendable, Equatable, Codable {
    public struct Size: Sendable, Equatable, Codable {
        /// "sevenFoot" | "eightFoot" | "nineFoot" | "custom".
        public var name: String
        public var width: Double?
        public var height: Double?

        public init(_ size: TableSize) {
            switch size {
            case .sevenFoot: self.init(name: "sevenFoot")
            case .eightFoot: self.init(name: "eightFoot")
            case .nineFoot: self.init(name: "nineFoot")
            case .custom(let width, let height):
                self.init(name: "custom", width: width, height: height)
            }
        }

        public init(name: String, width: Double? = nil, height: Double? = nil) {
            self.name = name
            self.width = width
            self.height = height
        }

        public func tableSize() throws -> TableSize {
            switch name {
            case "sevenFoot": return .sevenFoot
            case "eightFoot": return .eightFoot
            case "nineFoot": return .nineFoot
            case "custom":
                guard let width, let height, width > 0, height > 0 else {
                    throw SessionBundleError.invalidCalibration("custom size needs width and height")
                }
                return .custom(width: width, height: height)
            default:
                throw SessionBundleError.invalidCalibration("unknown table size '\(name)'")
            }
        }
    }

    public var origin: [Double]
    public var xAxis: [Double]
    public var yAxis: [Double]
    public var size: Size
    /// B3 anchor following: the table ARAnchor's transform at the moment
    /// this calibration was expressed (16 doubles, column-major). With it,
    /// and per-frame `RecordedFrameMeta.tableAnchorTransform`, the replay
    /// re-derives the calibration each frame exactly as the live pipeline
    /// did. Absent on scripted bundles (calibration stays pinned).
    public var anchorTransform: [Double]?

    public init(_ calibration: TableCalibration, anchorTransform: Transform3D? = nil) {
        origin = [calibration.origin.x, calibration.origin.y, calibration.origin.z]
        xAxis = [calibration.xAxis.x, calibration.xAxis.y, calibration.xAxis.z]
        yAxis = [calibration.yAxis.x, calibration.yAxis.y, calibration.yAxis.z]
        size = Size(calibration.size)
        self.anchorTransform = anchorTransform.map { $0.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] } }
    }

    /// The lock-time anchor transform, or nil when the bundle has none.
    public func anchorTransform3D() throws -> Transform3D? {
        guard let anchorTransform else { return nil }
        guard anchorTransform.count == 16 else {
            throw SessionBundleError.invalidCalibration("anchorTransform must have 16 components")
        }
        return Transform3D.fromFlat(anchorTransform)
    }

    public func tableCalibration() throws -> TableCalibration {
        guard origin.count == 3, xAxis.count == 3, yAxis.count == 3 else {
            throw SessionBundleError.invalidCalibration("origin/axes must have 3 components")
        }
        let x = Vec3(xAxis[0], xAxis[1], xAxis[2])
        let y = Vec3(yAxis[0], yAxis[1], yAxis[2])
        guard x.length > 1e-9, y.length > 1e-9, abs(x.normalized.dot(y.normalized)) < 0.01 else {
            throw SessionBundleError.invalidCalibration("axes must be non-zero and orthogonal")
        }
        return TableCalibration(origin: Vec3(origin[0], origin[1], origin[2]),
                                xAxis: x, yAxis: y, size: try size.tableSize())
    }

    func canonical() -> JSONValue {
        var sizeObject: [String: JSONValue] = ["name": .string(size.name)]
        if let width = size.width { sizeObject["width"] = .double(width) }
        if let height = size.height { sizeObject["height"] = .double(height) }
        var object: [String: JSONValue] = [
            "origin": .doubles(origin),
            "xAxis": .doubles(xAxis),
            "yAxis": .doubles(yAxis),
            "size": .object(sizeObject)
        ]
        if let anchorTransform { object["anchorTransform"] = .doubles(anchorTransform) }
        return .object(object)
    }
}

extension Transform3D {
    /// 16 column-major doubles → transform (callers check the count).
    static func fromFlat(_ m: [Double]) -> Transform3D {
        Transform3D(columns: (0..<4).map { c in
            SIMD4(m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3])
        })
    }
}

// MARK: - Frames

/// Pinhole intrinsics in image pixels (mirrors CueSyncCore.CameraIntrinsics).
public struct RecordedIntrinsics: Sendable, Equatable, Codable {
    public var focalX: Double
    public var focalY: Double
    public var principalX: Double
    public var principalY: Double
    public var imageWidth: Double
    public var imageHeight: Double

    public init(_ k: CameraIntrinsics) {
        focalX = k.focalX
        focalY = k.focalY
        principalX = k.principalX
        principalY = k.principalY
        imageWidth = k.imageWidth
        imageHeight = k.imageHeight
    }

    public var cameraIntrinsics: CameraIntrinsics {
        CameraIntrinsics(focalX: focalX, focalY: focalY,
                         principalX: principalX, principalY: principalY,
                         imageWidth: imageWidth, imageHeight: imageHeight)
    }

    func canonical() -> JSONValue {
        .object([
            "focalX": .double(focalX), "focalY": .double(focalY),
            "principalX": .double(principalX), "principalY": .double(principalY),
            "imageWidth": .double(imageWidth), "imageHeight": .double(imageHeight)
        ])
    }
}

/// Image dimensions (and, once video lands, the frame's index in it).
public struct RecordedImageInfo: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public var videoFrame: Int?

    public init(width: Int, height: Int, videoFrame: Int? = nil) {
        self.width = width
        self.height = height
        self.videoFrame = videoFrame
    }
}

/// Pixel-less stand-in for the frame image: carries dimensions only, so
/// detectors that need pixels (Core ML, Roboflow) fail loudly rather than
/// silently seeing black, while the recorded-detection path needs nothing.
public struct RecordedImage: ImageBufferProviding {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Everything about one captured frame EXCEPT its pixels — the replay's
/// own frame type. (`CapturedFrame` in CueSyncCore is a frozen contract;
/// this type is the persistent form and converts both ways.)
public struct RecordedFrameMeta: Sendable, Equatable, Codable {
    public var index: Int
    public var timestamp: TimeInterval
    /// Camera-to-world transform, 16 doubles column-major (c0.x c0.y c0.z
    /// c0.w c1.x ...) — the `Transform3D.columns` flattening.
    public var cameraTransform: [Double]
    public var intrinsics: RecordedIntrinsics?
    public var image: RecordedImageInfo?
    /// True when the recorder had to skip this frame's pixels because the
    /// video encoder was busy (back-pressure). The frame is still in the
    /// replay — only `image.videoFrame` is missing — and the flag makes the
    /// gap visible instead of silently misaligning video and detections.
    public var videoDropped: Bool?
    /// Device-recording side channel (ARExperience.DeliveredFrameMeta):
    /// the table ARAnchor's transform in this frame (16 doubles), ARKit's
    /// display transform for the viewport ([a, b, c, d, tx, ty]) and the
    /// interface orientation name. All absent on scripted bundles.
    public var tableAnchorTransform: [Double]?
    public var displayTransform: [Double]?
    public var interfaceOrientation: String?

    public init(index: Int, timestamp: TimeInterval, cameraTransform: [Double],
                intrinsics: RecordedIntrinsics? = nil, image: RecordedImageInfo? = nil,
                videoDropped: Bool? = nil, tableAnchorTransform: [Double]? = nil,
                displayTransform: [Double]? = nil, interfaceOrientation: String? = nil) {
        self.index = index
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.image = image
        self.videoDropped = videoDropped
        self.tableAnchorTransform = tableAnchorTransform
        self.displayTransform = displayTransform
        self.interfaceOrientation = interfaceOrientation
    }

    public init(index: Int, frame: CapturedFrame) {
        self.init(index: index,
                  timestamp: frame.timestamp,
                  cameraTransform: frame.cameraTransform.columns.flatMap { [$0.x, $0.y, $0.z, $0.w] },
                  intrinsics: frame.intrinsics.map(RecordedIntrinsics.init),
                  image: frame.image.map { RecordedImageInfo(width: $0.width, height: $0.height) })
    }

    public func transform3D() throws -> Transform3D {
        guard cameraTransform.count == 16 else {
            throw SessionBundleError.invalidTransform(index)
        }
        return Transform3D.fromFlat(cameraTransform)
    }

    /// The table anchor's transform in this frame (B3 anchor following),
    /// or nil when the frame carries none.
    public func tableAnchorTransform3D() throws -> Transform3D? {
        guard let tableAnchorTransform else { return nil }
        guard tableAnchorTransform.count == 16 else {
            throw SessionBundleError.invalidTransform(index)
        }
        return Transform3D.fromFlat(tableAnchorTransform)
    }

    public func capturedFrame() throws -> CapturedFrame {
        CapturedFrame(timestamp: timestamp,
                      cameraTransform: try transform3D(),
                      image: image.map { RecordedImage(width: $0.width, height: $0.height) },
                      intrinsics: intrinsics?.cameraIntrinsics)
    }

    func canonical() -> JSONValue {
        var image: JSONValue = .null
        if let info = self.image {
            var object: [String: JSONValue] = ["width": .int(info.width),
                                               "height": .int(info.height)]
            if let videoFrame = info.videoFrame { object["videoFrame"] = .int(videoFrame) }
            image = .object(object)
        }
        var object: [String: JSONValue] = [
            "index": .int(index),
            "timestamp": .double(timestamp),
            "cameraTransform": .doubles(cameraTransform),
            "intrinsics": .optional(intrinsics?.canonical()),
            "image": image
        ]
        // Emitted only when set, so frames written before the fields
        // existed (and every frame whose pixels made it) are unchanged.
        if videoDropped == true { object["videoDropped"] = .bool(true) }
        if let tableAnchorTransform { object["tableAnchorTransform"] = .doubles(tableAnchorTransform) }
        if let displayTransform { object["displayTransform"] = .doubles(displayTransform) }
        if let interfaceOrientation { object["interfaceOrientation"] = .string(interfaceOrientation) }
        return .object(object)
    }
}

// MARK: - Detections

public struct RecordedDetection: Sendable, Equatable, Codable {
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(_ detection: Detection2D) {
        label = detection.classLabel
        x = detection.boundingBox.x
        y = detection.boundingBox.y
        width = detection.boundingBox.width
        height = detection.boundingBox.height
        confidence = detection.confidence
    }

    public init(label: String, x: Double, y: Double, width: Double, height: Double,
                confidence: Double) {
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }

    public var detection2D: Detection2D {
        Detection2D(classLabel: label,
                    boundingBox: NormalizedRect(x: x, y: y, width: width, height: height),
                    confidence: confidence)
    }

    func canonical() -> JSONValue {
        .object([
            "label": .string(label),
            "x": .double(x), "y": .double(y),
            "width": .double(width), "height": .double(height),
            "confidence": .double(confidence)
        ])
    }
}

/// The detector's output for one frame, keyed by the frame's timestamp
/// (the only frame identity a DetectionProviding sees).
public struct RecordedDetectionFrame: Sendable, Equatable, Codable {
    public var frame: Int
    public var timestamp: TimeInterval
    public var detections: [RecordedDetection]

    public init(frame: Int, timestamp: TimeInterval, detections: [RecordedDetection]) {
        self.frame = frame
        self.timestamp = timestamp
        self.detections = detections
    }

    func canonical() -> JSONValue {
        .object([
            "frame": .int(frame),
            "timestamp": .double(timestamp),
            "detections": .array(detections.map { $0.canonical() })
        ])
    }
}

// MARK: - Events

/// A user action during the session, applied by the replay at its frame
/// (after that frame's perception output, before the aim/solve step).
public struct RecordedEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Tap-to-designate the cue ball nearest (x, y) in table space.
        case designateCueBall
        /// Toggle the called pocket (`pocket` = PocketID raw value).
        case callPocket
        /// Long-press reset: drop every track and start fresh.
        case resetTracking
        /// Free-text marker; no effect on replay.
        case note
    }

    public var frame: Int
    public var timestamp: TimeInterval
    public var kind: Kind
    public var x: Double?
    public var y: Double?
    public var pocket: String?
    public var note: String?

    public init(frame: Int, timestamp: TimeInterval, kind: Kind,
                x: Double? = nil, y: Double? = nil, pocket: String? = nil,
                note: String? = nil) {
        self.frame = frame
        self.timestamp = timestamp
        self.kind = kind
        self.x = x
        self.y = y
        self.pocket = pocket
        self.note = note
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = [
            "frame": .int(frame),
            "timestamp": .double(timestamp),
            "kind": .string(kind.rawValue)
        ]
        if let x { object["x"] = .double(x) }
        if let y { object["y"] = .double(y) }
        if let pocket { object["pocket"] = .string(pocket) }
        if let note { object["note"] = .string(note) }
        return .object(object)
    }
}

// MARK: - Truth

public struct TruthBall: Sendable, Equatable, Codable {
    /// Kind label (see `KindLabel`); informational — matching is by position.
    public var kind: String
    public var x: Double
    public var y: Double

    public init(kind: String, x: Double, y: Double) {
        self.kind = kind
        self.x = x
        self.y = y
    }

    public var position: Vec2 { Vec2(x, y) }

    func canonical() -> JSONValue {
        .object(["kind": .string(kind), "x": .double(x), "y": .double(y)])
    }
}

public struct TruthFrame: Sendable, Equatable, Codable {
    public var frame: Int
    public var balls: [TruthBall]

    public init(frame: Int, balls: [TruthBall]) {
        self.frame = frame
        self.balls = balls
    }
}

/// Ground truth for AccuracyReport: a static layout (`balls`) that applies
/// to every frame, optionally overridden per frame (`frames`). Ball ORDER
/// is the truth identity used for identity-switch counting, so keep it
/// stable across per-frame layouts.
public struct SessionTruth: Sendable, Equatable, Codable {
    /// A tracked ball within this distance (m) of a truth ball matches it.
    public var matchRadius: Double
    public var balls: [TruthBall]
    public var frames: [TruthFrame]?
    /// Provenance — how the truth was obtained (tape measure, script, ...).
    public var method: String

    public init(matchRadius: Double = 0.03, balls: [TruthBall],
                frames: [TruthFrame]? = nil, method: String) {
        self.matchRadius = matchRadius
        self.balls = balls
        self.frames = frames
        self.method = method
    }

    /// The truth layout in force at `frame`.
    public func balls(atFrame frame: Int) -> [TruthBall] {
        frames?.first { $0.frame == frame }?.balls ?? balls
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = [
            "matchRadius": .double(matchRadius),
            "method": .string(method),
            "balls": .array(balls.map { $0.canonical() })
        ]
        if let frames {
            object["frames"] = .array(frames.map {
                .object(["frame": .int($0.frame),
                         "balls": .array($0.balls.map { $0.canonical() })])
            })
        }
        return .object(object)
    }
}
