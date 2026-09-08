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

    public init(sessionID: String, recordedAt: String, source: String,
                description: String, frameCount: Int, video: VideoInfo? = nil,
                schemaVersion: Int = SessionBundleSchema.version) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.source = source
        self.description = description
        self.frameCount = frameCount
        self.video = video
    }

    func canonical() -> JSONValue {
        var video: JSONValue = .null
        if let info = self.video {
            video = .object(["fileName": .string(info.fileName),
                             "width": .int(info.width),
                             "height": .int(info.height)])
        }
        return .object([
            "schemaVersion": .int(schemaVersion),
            "sessionID": .string(sessionID),
            "recordedAt": .string(recordedAt),
            "source": .string(source),
            "description": .string(description),
            "frameCount": .int(frameCount),
            "video": video
        ])
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

    public init(_ calibration: TableCalibration) {
        origin = [calibration.origin.x, calibration.origin.y, calibration.origin.z]
        xAxis = [calibration.xAxis.x, calibration.xAxis.y, calibration.xAxis.z]
        yAxis = [calibration.yAxis.x, calibration.yAxis.y, calibration.yAxis.z]
        size = Size(calibration.size)
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
        return .object([
            "origin": .doubles(origin),
            "xAxis": .doubles(xAxis),
            "yAxis": .doubles(yAxis),
            "size": .object(sizeObject)
        ])
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

    public init(index: Int, timestamp: TimeInterval, cameraTransform: [Double],
                intrinsics: RecordedIntrinsics? = nil, image: RecordedImageInfo? = nil) {
        self.index = index
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.image = image
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
        let m = cameraTransform
        return Transform3D(columns: (0..<4).map { c in
            SIMD4(m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3])
        })
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
        return .object([
            "index": .int(index),
            "timestamp": .double(timestamp),
            "cameraTransform": .doubles(cameraTransform),
            "intrinsics": .optional(intrinsics?.canonical()),
            "image": image
        ])
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
