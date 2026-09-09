//
//  OutputSchema.swift
//  SessionReplay
//
//  The outputs.jsonl record — one line per replayed frame, everything the
//  midsection derived for it — plus the ball-kind labels shared by every
//  bundle file. This IS the golden: byte-equality of these lines is the
//  fixed-eval-set contract, so the fields are flat, explicit, and written
//  only through `canonical()`.
//

import ARExperience
import CueSyncCore
import Foundation

// MARK: - Outputs (the golden)

public struct OutputBall: Sendable, Equatable, Codable {
    public var id: Int
    public var kind: String
    public var x: Double
    public var y: Double
    public var radius: Double
    public var confidence: Double

    /// Memberwise, for tests and tooling that build records directly
    /// rather than from a live `Ball`.
    public init(id: Int, kind: String, x: Double, y: Double,
                radius: Double, confidence: Double) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.radius = radius
        self.confidence = confidence
    }

    public init(_ ball: Ball) {
        id = ball.id.rawValue
        kind = KindLabel.label(for: ball.kind)
        x = ball.position.x
        y = ball.position.y
        radius = ball.radius
        confidence = ball.confidence
    }

    public var position: Vec2 { Vec2(x, y) }

    func canonical() -> JSONValue {
        .object([
            "id": .int(id), "kind": .string(kind),
            "x": .double(x), "y": .double(y),
            "radius": .double(radius), "confidence": .double(confidence)
        ])
    }
}

public struct OutputAim: Sendable, Equatable, Codable {
    public var source: String
    public var originX: Double
    public var originY: Double
    public var directionX: Double
    public var directionY: Double

    /// Memberwise, for tests and tooling.
    public init(source: String, originX: Double, originY: Double,
                directionX: Double, directionY: Double) {
        self.source = source
        self.originX = originX
        self.originY = originY
        self.directionX = directionX
        self.directionY = directionY
    }

    public init(_ plan: ShotPlan) {
        source = plan.source.rawValue
        originX = plan.aim.origin.x
        originY = plan.aim.origin.y
        directionX = plan.aim.direction.x
        directionY = plan.aim.direction.y
    }

    func canonical() -> JSONValue {
        .object([
            "source": .string(source),
            "originX": .double(originX), "originY": .double(originY),
            "directionX": .double(directionX), "directionY": .double(directionY)
        ])
    }
}

public struct OutputSegment: Sendable, Equatable, Codable {
    public var ball: Int
    public var kind: String
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double
    public var entrySpeed: Double

    public init(_ segment: TrajectorySegment) {
        ball = segment.ballID.rawValue
        kind = segment.kind.rawValue
        startX = segment.start.x
        startY = segment.start.y
        endX = segment.end.x
        endY = segment.end.y
        entrySpeed = segment.entrySpeed
    }

    func canonical() -> JSONValue {
        .object([
            "ball": .int(ball), "kind": .string(kind),
            "startX": .double(startX), "startY": .double(startY),
            "endX": .double(endX), "endY": .double(endY),
            "entrySpeed": .double(entrySpeed)
        ])
    }
}

public struct OutputEvent: Sendable, Equatable, Codable {
    public var type: String
    public var ball: Int
    public var x: Double?
    public var y: Double?
    public var struck: Int?
    public var pocket: String?

    public init(_ event: CollisionEvent) {
        switch event {
        case let .ballBall(moving, struckID, contact):
            type = "ballBall"
            ball = moving.rawValue
            x = contact.x
            y = contact.y
            struck = struckID.rawValue
        case let .cushion(ballID, point):
            type = "cushion"
            ball = ballID.rawValue
            x = point.x
            y = point.y
        case let .pocket(ballID, pocketID):
            type = "pocket"
            ball = ballID.rawValue
            pocket = pocketID.rawValue
        case let .rest(ballID, point):
            type = "rest"
            ball = ballID.rawValue
            x = point.x
            y = point.y
        }
    }

    func canonical() -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "ball": .int(ball)]
        if let x { object["x"] = .double(x) }
        if let y { object["y"] = .double(y) }
        if let struck { object["struck"] = .int(struck) }
        if let pocket { object["pocket"] = .string(pocket) }
        return .object(object)
    }
}

public struct OutputPrediction: Sendable, Equatable, Codable {
    public var segments: [OutputSegment]
    public var events: [OutputEvent]
    public var pocketed: [Int]

    public init(_ prediction: ShotPrediction) {
        segments = prediction.segments.map(OutputSegment.init)
        events = prediction.events.map(OutputEvent.init)
        pocketed = prediction.pocketedBalls.map(\.rawValue)
    }

    func canonical() -> JSONValue {
        .object([
            "segments": .array(segments.map { $0.canonical() }),
            "events": .array(events.map { $0.canonical() }),
            "pocketed": .array(pocketed.map(JSONValue.int))
        ])
    }
}

/// One rendered guide strip, in WORLD space.
///
/// Endpoints rather than a heading, for the same reason `OverlayLayout`
/// carries them: a heading has to name a frame, and naming the wrong one is
/// what drew every guide line a right angle off the cloth. Endpoints are
/// sums and products of the calibration basis, so they stay byte-identical
/// across platforms — an `atan2` here would not.
public struct OutputStrip: Sendable, Equatable, Codable {
    public var ball: Int
    public var start: [Double]
    public var end: [Double]
    public var dashed: Bool
    public var color: Int

    public init(ball: Int, start: [Double], end: [Double], dashed: Bool, color: Int) {
        self.ball = ball
        self.start = start
        self.end = end
        self.dashed = dashed
        self.color = color
    }

    func canonical() -> JSONValue {
        .object([
            "ball": .int(ball),
            "start": .doubles(start),
            "end": .doubles(end),
            "dashed": .bool(dashed),
            "color": .int(color)
        ])
    }
}

/// One line of outputs.jsonl: everything the replay derived for a frame.
public struct OutputRecord: Sendable, Equatable, Codable {
    public var frame: Int
    public var timestamp: TimeInterval
    /// Confirmed balls, ascending id.
    public var balls: [OutputBall]
    /// Stick footprint corners (table space, image order TL TR BR BL).
    public var stick: [[Double]]?
    public var labels: [String]
    public var aim: OutputAim?
    public var prediction: OutputPrediction?
    /// Whether the plan changed on this frame (a re-solve happened).
    public var planChanged: Bool
    public var calledPocket: String?
    public var calledShotOnLine: Bool
    /// Consecutive aimed frames the current aim source has held, counting
    /// this one; 0 when there is no aim. A source that flips every second
    /// is the "guides move in weird formations" symptom stated as a number.
    public var aimSourceRun: Int
    /// What the renderer would draw this frame — the composed overlay,
    /// which replay previously stopped short of. Without it "the strips
    /// drawn are the strips solved" was unverifiable offline.
    public var strips: [OutputStrip]?

    public init(frame: Int, timestamp: TimeInterval, balls: [OutputBall],
                stick: [[Double]]?, labels: [String], aim: OutputAim?,
                prediction: OutputPrediction?, planChanged: Bool,
                calledPocket: String?, calledShotOnLine: Bool,
                aimSourceRun: Int = 0, strips: [OutputStrip]? = nil) {
        self.frame = frame
        self.timestamp = timestamp
        self.balls = balls
        self.stick = stick
        self.labels = labels
        self.aim = aim
        self.prediction = prediction
        self.planChanged = planChanged
        self.calledPocket = calledPocket
        self.calledShotOnLine = calledShotOnLine
        self.aimSourceRun = aimSourceRun
        self.strips = strips
    }

    func canonical() -> JSONValue {
        .object([
            "frame": .int(frame),
            "timestamp": .double(timestamp),
            "balls": .array(balls.map { $0.canonical() }),
            "stick": .optional(stick.map { .array($0.map(JSONValue.doubles)) }),
            "labels": .array(labels.map(JSONValue.string)),
            "aim": .optional(aim?.canonical()),
            "prediction": .optional(prediction?.canonical()),
            "planChanged": .bool(planChanged),
            "calledPocket": .optional(calledPocket.map(JSONValue.string)),
            "calledShotOnLine": .bool(calledShotOnLine),
            "aimSourceRun": .int(aimSourceRun),
            "strips": .optional(strips.map { .array($0.map { $0.canonical() }) })
        ])
    }
}

// MARK: - Kind labels

/// Human-readable, round-trippable ball-kind labels for bundle files.
public enum KindLabel {
    public static func label(for kind: Ball.Kind) -> String {
        switch kind {
        case .cue: "cue"
        case .eight: "8"
        case .solid(let n): "solid-\(n)"
        case .stripe(let n): "stripe-\(n)"
        case .unknown: "unknown"
        }
    }

    public static func kind(for label: String) -> Ball.Kind {
        switch label {
        case "cue": return .cue
        case "8", "eight": return .eight
        case "unknown": return .unknown
        default:
            if label.hasPrefix("solid-"), let n = Int(label.dropFirst(6)), (1...7).contains(n) {
                return .solid(n)
            }
            if label.hasPrefix("stripe-"), let n = Int(label.dropFirst(7)), (9...15).contains(n) {
                return .stripe(n)
            }
            return .unknown
        }
    }
}
