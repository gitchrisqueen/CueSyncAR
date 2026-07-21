//
//  Providers.swift
//  CueSyncCore
//
//  The plug-in seams. Every replaceable capability — detection model,
//  trajectory solver, LLM coach, display output — is a small protocol here.
//  Adapters live in their own packages and register with ProviderRegistry.
//

import Foundation

// MARK: - Frames & detection

/// Platform-erased handle to the frame's image data. On Apple platforms the
/// concrete type wraps a CVPixelBuffer; tests use fixture implementations.
public protocol ImageBufferProviding: Sendable {
    var width: Int { get }
    var height: Int { get }
}

/// Pinhole camera intrinsics for the captured image, in pixels of that
/// image's native orientation. Lets consumers unproject image points into
/// world rays without touching ARKit (pure math, any thread).
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    public var focalX: Double
    public var focalY: Double
    public var principalX: Double
    public var principalY: Double
    public var imageWidth: Double
    public var imageHeight: Double

    public init(focalX: Double, focalY: Double,
                principalX: Double, principalY: Double,
                imageWidth: Double, imageHeight: Double) {
        self.focalX = focalX
        self.focalY = focalY
        self.principalX = principalX
        self.principalY = principalY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

/// One camera frame plus the pose metadata needed to project detections.
public struct CapturedFrame: Sendable {
    public var timestamp: TimeInterval
    /// Camera-to-world transform at capture time.
    public var cameraTransform: Transform3D
    public var image: (any ImageBufferProviding)?
    /// Present when the capture source knows its intrinsics (ARKit does);
    /// nil for sources that don't (fixtures, plain AVCapture).
    public var intrinsics: CameraIntrinsics?

    public init(timestamp: TimeInterval,
                cameraTransform: Transform3D,
                image: (any ImageBufferProviding)? = nil,
                intrinsics: CameraIntrinsics? = nil) {
        self.timestamp = timestamp
        self.cameraTransform = cameraTransform
        self.image = image
        self.intrinsics = intrinsics
    }
}

/// A single detector output in normalized image space.
public struct Detection2D: Sendable, Equatable, Codable {
    public var classLabel: String
    public var boundingBox: NormalizedRect
    public var confidence: Double

    public init(classLabel: String, boundingBox: NormalizedRect, confidence: Double) {
        self.classLabel = classLabel
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    public var ballKind: Ball.Kind { Ball.Kind(classLabel: classLabel) }

    /// Whether this detection is a cue STICK, not a ball. The bundled MVP
    /// dataset (pool-ball-agzev) labels the stick "cue" and the cue ball
    /// "white-ball" — stick detections must never enter ball tracking, and
    /// they're the future input for stick-based aiming.
    public var isCueStick: Bool {
        switch classLabel.lowercased() {
        case "cue", "stick", "cue-stick", "cuestick", "cue_stick": true
        default: false
        }
    }
}

/// Any object detector: bundled Core ML, Roboflow SDK, remote, or fixture.
public protocol DetectionProviding: Sendable {
    /// One-time setup (model load/compile). Must be safe to call twice.
    func prepare() async throws
    /// Detections in normalized image space for the given frame.
    func detect(in frame: CapturedFrame) async throws -> [Detection2D]
}

// MARK: - Trajectory solving

public struct SolverOptions: Sendable, Equatable, Codable {
    /// Assumed cue-ball launch speed, m/s.
    public var initialSpeed: Double
    /// Hard cap on simulated events (collisions/bounces) per shot.
    public var maxEvents: Int

    public init(initialSpeed: Double = 2.0, maxEvents: Int = 8) {
        self.initialSpeed = initialSpeed
        self.maxEvents = maxEvents
    }

    public static let `default` = SolverOptions()
}

/// Any trajectory solver. Must be a pure function of its inputs.
public protocol TrajectorySolving: Sendable {
    func predict(state: TableState, aim: AimRay, options: SolverOptions) -> ShotPrediction
}

// MARK: - Coaching (post-MVP; seam defined now so architecture stays stable)

public enum SkillLevel: String, Sendable, Codable, CaseIterable {
    case beginner, intermediate, advanced
}

public struct CoachAdvice: Sendable, Equatable, Codable {
    public var headline: String
    public var explanation: String
    /// 0 (trivial) ... 1 (very hard) difficulty of the recommended shot.
    public var difficulty: Double

    public init(headline: String, explanation: String, difficulty: Double) {
        self.headline = headline
        self.explanation = explanation
        self.difficulty = difficulty
    }
}

/// Any coaching backend: on-device Foundation Models, Claude, or a mock.
/// Input is structured state only — never raw camera imagery.
public protocol CoachProviding: Sendable {
    func advise(state: TableState, prediction: ShotPrediction,
                skill: SkillLevel) async throws -> CoachAdvice
}

// MARK: - Display outputs

public enum DisplayOutputKind: String, Sendable, Codable, CaseIterable {
    /// System screen mirroring — no dedicated content.
    case mirror
    /// Dedicated top-down broadcast-style table scene.
    case tableView
}

/// Marker protocol for external display outputs. Scene attachment is
/// platform-specific and lives in DisplayKit; core only routes by kind.
public protocol DisplayOutput: Sendable {
    var kind: DisplayOutputKind { get }
}

// MARK: - Secrets

/// Read-only access to configuration secrets (API keys). Production reads
/// from the app's Info.plist (fed by untracked xcconfig); tests inject fakes.
/// No MVP feature may *require* a secret.
public protocol SecretsProviding: Sendable {
    /// Returns the secret for `key`, or nil when not configured.
    func secret(for key: SecretKey) -> String?
}

public struct SecretKey: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let roboflowAPIKey = SecretKey(rawValue: "ROBOFLOW_API_KEY")
    public static let anthropicAPIKey = SecretKey(rawValue: "ANTHROPIC_API_KEY")
}

/// Secrets from the process environment — CI and development default.
public struct EnvironmentSecrets: SecretsProviding {
    public init() {}
    public func secret(for key: SecretKey) -> String? {
        let value = ProcessInfo.processInfo.environment[key.rawValue]
        return (value?.isEmpty ?? true) ? nil : value
    }
}

/// Secrets from an in-memory dictionary — test/fixture default.
public struct StaticSecrets: SecretsProviding {
    private let values: [SecretKey: String]
    public init(_ values: [SecretKey: String]) { self.values = values }
    public func secret(for key: SecretKey) -> String? { values[key] }
}
