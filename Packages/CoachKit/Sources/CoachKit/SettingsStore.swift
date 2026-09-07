//
//  SettingsStore.swift
//  CoachKit
//
//  The persistence seam behind `SettingsModel` (M4-04). Settings are a
//  handful of primitives, so the store speaks a tiny typed value rather
//  than `Any`: that keeps the whole read/write path Sendable, testable on
//  Linux, and unable to smuggle a wrong type past the loader.
//
//  Reads are type-directed on purpose. `UserDefaults` bridges everything
//  through `NSNumber`, so a "what did you store?" API would happily read a
//  guide speed of 1.0 back as `true`; asking for the type the setting
//  actually has cannot make that mistake.
//

import Foundation

/// One persisted settings primitive.
public enum SettingsValue: Sendable, Equatable {
    case bool(Bool)
    case double(Double)
    case string(String)
}

/// Key/value persistence for settings. Implementations must be safe to
/// share; the app uses `UserDefaultsSettingsStore`, tests use
/// `InMemorySettingsStore`.
public protocol SettingsStore: Sendable {
    /// The stored flag, or nil when nothing (or something of another type)
    /// is stored under `key`.
    func bool(forKey key: String) -> Bool?
    /// The stored number, or nil when nothing — or a non-finite value, or
    /// something of another type — is stored under `key`.
    func double(forKey key: String) -> Double?
    /// The stored string, or nil when nothing (or something of another
    /// type) is stored under `key`.
    func string(forKey key: String) -> String?
    /// Store `value` under `key`; nil removes the entry.
    func write(_ value: SettingsValue?, forKey key: String)
}

/// A store that keeps everything in memory — the test double, and a safe
/// fallback anywhere `UserDefaults` is unavailable.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var storage: [String: SettingsValue]
    private let lock = NSLock()

    /// - Parameter storage: pre-seeded contents, so a test can simulate a
    ///   partially-written or corrupt store.
    public init(storage: [String: SettingsValue] = [:]) {
        self.storage = storage
    }

    /// Everything written so far.
    public var contents: [String: SettingsValue] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func value(forKey key: String) -> SettingsValue? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func bool(forKey key: String) -> Bool? {
        if case .bool(let value) = value(forKey: key) { return value }
        return nil
    }

    public func double(forKey key: String) -> Double? {
        if case .double(let value) = value(forKey: key), value.isFinite { return value }
        return nil
    }

    public func string(forKey key: String) -> String? {
        if case .string(let value) = value(forKey: key) { return value }
        return nil
    }

    public func write(_ value: SettingsValue?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

/// The production store. `UserDefaults` is documented thread-safe, hence
/// the unchecked conformance.
public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool? {
        // `object(forKey:)` first: the typed accessors return false/0 for a
        // missing key, which would mask "nothing stored" as a real value.
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    public func double(forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value.isFinite ? value : nil
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func write(_ value: SettingsValue?, forKey key: String) {
        switch value {
        case .none: defaults.removeObject(forKey: key)
        case .bool(let bool): defaults.set(bool, forKey: key)
        case .double(let double): defaults.set(double, forKey: key)
        case .string(let string): defaults.set(string, forKey: key)
        }
    }
}
