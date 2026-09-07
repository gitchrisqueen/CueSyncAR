//
//  SettingsModel.swift
//  CoachKit
//
//  M4-04: every knob the Settings sheet exposes, as one pure value with
//  its own validation and persistence. The SwiftUI screen is a thin shell
//  over this type — nothing about a setting's range, its default, its
//  storage key, or what a corrupt store should do lives in the app target.
//
//  Storage keys are load-bearing: `debugMirrorEnabled` and `practiceMode`
//  are the keys the HUD antenna button and the mode menu already write, so
//  an existing install keeps its choices and there is exactly one source
//  of truth per setting.
//

import CueSyncCore
import Foundation

/// Table-size behavior at calibration time.
public enum TableSizeSetting: Sendable, Equatable, Hashable {
    /// No override: calibration uses what it measures (snapping to the
    /// user's remembered table spec when there is one).
    case useMeasured
    /// Force this size regardless of the measured rectangle.
    case standard(TableSize)

    /// The sizes offered by the picker, in display order.
    public static let selectable: [TableSizeSetting] =
        [.useMeasured] + TableSize.standardSizes.map(TableSizeSetting.standard)

    /// The size calibration must snap to, or nil when the user has not
    /// overridden it.
    public var override: TableSize? {
        switch self {
        case .useMeasured: nil
        case .standard(let size): size
        }
    }

    /// Picker label.
    public var title: String {
        switch self {
        case .useMeasured: "Use measured"
        case .standard(.sevenFoot): "7-ft"
        case .standard(.eightFoot): "8-ft"
        case .standard(.nineFoot): "9-ft"
        case .standard(.custom(let width, let height)):
            String(format: "%.2f × %.2f m", width, height)
        }
    }

    /// Stable persisted spelling — renaming one resets a user's choice.
    public var storageValue: String {
        switch self {
        case .useMeasured: "measured"
        case .standard(.sevenFoot): "sevenFoot"
        case .standard(.eightFoot): "eightFoot"
        case .standard(.nineFoot): "nineFoot"
        case .standard(.custom(let width, let height)):
            "custom:\(width):\(height)"
        }
    }

    /// Parse a persisted spelling; nil for anything unrecognized so the
    /// caller can fall back to the default rather than guess.
    public init?(storageValue: String) {
        switch storageValue {
        case "measured": self = .useMeasured
        case "sevenFoot": self = .standard(.sevenFoot)
        case "eightFoot": self = .standard(.eightFoot)
        case "nineFoot": self = .standard(.nineFoot)
        default:
            let parts = storageValue.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "custom",
                  let width = Double(parts[1]), let height = Double(parts[2]),
                  width.isFinite, height.isFinite, width > 0, height > 0 else {
                return nil
            }
            self = .standard(.custom(width: width, height: height))
        }
    }
}

/// Which detector feeds live tracking.
public enum DetectionProviderSetting: String, Sendable, Equatable, CaseIterable, Codable {
    /// The bundled Core ML model — offline, the MVP default.
    case onDevice
    /// The hosted Roboflow adapter; only usable with an API key present.
    case hosted

    /// Picker label.
    public var title: String {
        switch self {
        case .onDevice: "On-device (bundled)"
        case .hosted: "Hosted (Roboflow)"
        }
    }
}

/// Persisted settings keys. Public so the app and its tests can name the
/// same strings the model writes.
public enum SettingsKey {
    public static let tableSize = "tableSizeOverride"
    public static let detectionProvider = "detectionProvider"
    public static let guideSpeed = "guideSpeed"
    /// Pre-existing key, written by the HUD antenna button since M3.
    public static let debugMirrorEnabled = "debugMirrorEnabled"
    /// Pre-existing key, written by the HUD mode menu since M6-01.
    public static let practiceMode = "practiceMode"
    public static let visibleMissGrace = "visibleMissGrace"
}

/// Everything the owner can change without a rebuild.
///
/// Values validate on assignment: out-of-range and non-finite numbers
/// clamp to the supported range rather than being rejected, so neither a
/// dragged slider nor a hand-written remote command can put the app into a
/// state it cannot render.
public struct SettingsModel: Sendable, Equatable {
    /// Guide speed the solver launches shots at (m/s). Below ~1 m/s the
    /// predicted path dies mid-table; above ~8 m/s the 8-event budget is
    /// spent on ricochets before anything useful is shown.
    public static let guideSpeedRange: ClosedRange<Double> = 1.0...8.0
    /// Seconds a visible-but-undetected track survives before retirement.
    public static let visibleMissGraceRange: ClosedRange<Double> = 0.1...5.0
    public static let defaultGuideSpeed = 3.5
    public static let defaultVisibleMissGrace = 0.75

    /// Table size override; `.useMeasured` by default.
    public var tableSize: TableSizeSetting = .useMeasured
    /// Detector for live tracking. Selecting `.hosted` without a
    /// configured API key is honored by the model but the app falls back
    /// to the bundled detector rather than tracking nothing.
    public var detectionProvider: DetectionProviderSetting = .onDevice
    /// Solver launch speed (m/s), clamped to `guideSpeedRange`.
    public var guideSpeed: Double = SettingsModel.defaultGuideSpeed {
        didSet { guideSpeed = Self.clamped(guideSpeed, to: Self.guideSpeedRange,
                                           fallback: Self.defaultGuideSpeed) }
    }
    /// Whether the LAN debug mirror starts with the app. On by default —
    /// the device usually sits at the table out of arm's reach.
    public var debugMirrorEnabled = true
    /// Selected practice mode (M6-01).
    public var practiceMode: PracticeMode = .freePlay
    /// Tracker tuning: how long a ball that is in view but undetected
    /// keeps its track. Clamped to `visibleMissGraceRange`.
    public var visibleMissGrace: Double = SettingsModel.defaultVisibleMissGrace {
        didSet { visibleMissGrace = Self.clamped(visibleMissGrace, to: Self.visibleMissGraceRange,
                                                 fallback: Self.defaultVisibleMissGrace) }
    }

    /// The defaults — what a fresh install runs on.
    public init() {}

    /// Load from persistence. Any key that is missing, of the wrong type,
    /// unparseable, or out of range falls back to that setting's default;
    /// a half-written store therefore yields a usable model, never a throw
    /// and never a wholesale reset of the settings that ARE valid.
    public init(loading store: some SettingsStore) {
        self.init()
        if let raw = store.string(forKey: SettingsKey.tableSize),
           let value = TableSizeSetting(storageValue: raw) {
            tableSize = value
        }
        if let raw = store.string(forKey: SettingsKey.detectionProvider),
           let value = DetectionProviderSetting(rawValue: raw) {
            detectionProvider = value
        }
        // Explicit clamping: property observers do NOT run for
        // assignments made inside an initializer, so `didSet` cannot be
        // the only validation gate on a loaded value.
        if let raw = store.double(forKey: SettingsKey.guideSpeed) {
            guideSpeed = Self.clamped(raw, to: Self.guideSpeedRange,
                                      fallback: Self.defaultGuideSpeed)
        }
        if let raw = store.bool(forKey: SettingsKey.debugMirrorEnabled) {
            debugMirrorEnabled = raw
        }
        if let raw = store.string(forKey: SettingsKey.practiceMode),
           let value = PracticeMode(rawValue: raw) {
            practiceMode = value
        }
        if let raw = store.double(forKey: SettingsKey.visibleMissGrace) {
            visibleMissGrace = Self.clamped(raw, to: Self.visibleMissGraceRange,
                                            fallback: Self.defaultVisibleMissGrace)
        }
    }

    /// Write every setting. Writing all of them (rather than only what
    /// changed) is what makes a partially-written store self-heal on the
    /// next save.
    public func persist(to store: some SettingsStore) {
        for (key, value) in snapshot {
            store.write(value, forKey: key)
        }
    }

    /// Key/value view of the live settings — persisted as-is, and served
    /// by the debug mirror so a browser at the table can confirm a setting
    /// took effect.
    public var snapshot: [String: SettingsValue] {
        [
            SettingsKey.tableSize: .string(tableSize.storageValue),
            SettingsKey.detectionProvider: .string(detectionProvider.rawValue),
            SettingsKey.guideSpeed: .double(guideSpeed),
            SettingsKey.debugMirrorEnabled: .bool(debugMirrorEnabled),
            SettingsKey.practiceMode: .string(practiceMode.rawValue),
            SettingsKey.visibleMissGrace: .double(visibleMissGrace)
        ]
    }

    /// True when a change between `self` and `other` requires the
    /// perception pipeline to be rebuilt (detector swap or tracker tuning)
    /// rather than just re-read.
    public func requiresPipelineRestart(comparedTo other: SettingsModel) -> Bool {
        detectionProvider != other.detectionProvider
            || visibleMissGrace != other.visibleMissGrace
    }

    /// Clamp into range, substituting `fallback` for NaN/∞ (which compare
    /// false against every bound and would otherwise survive clamping).
    static func clamped(_ value: Double, to range: ClosedRange<Double>,
                        fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }
}
