//
//  MirrorAccessPolicy.swift
//  CueSync AR
//
//  Who may talk to the debug mirror, and on what terms.
//
//  The mirror is a plain HTTP server on the LAN that serves the live
//  camera, the tracking state, any recorded session bundle, and a `/cmd`
//  endpoint that can do everything a finger on the screen could. That is
//  exactly right for a developer with the device propped at a table, and
//  exactly wrong on a pool-hall or hotel network.
//
//  So the decision is split in two, and neither half is a judgement call
//  made at the call site:
//
//  * WHETHER the server runs at all — a setting, defaulted per build
//    configuration by the app target (see `SettingsModel.init`).
//  * WHETHER a given request is answered — this type.
//
//  Pure and Linux-testable on purpose: this is the piece that must not be
//  wrong, and it should be provable without a device, a network, or a
//  running app.
//

import Foundation

/// Gate for one debug-mirror request.
public struct MirrorAccessPolicy: Sendable, Equatable {

    /// How much proof a caller must offer.
    public enum Mode: Sendable, Equatable {
        /// Everything answered, no token. The development posture: the
        /// agent-driven table loop pastes `/cmd` URLs into a shell and must
        /// not need a secret to do it.
        case open
        /// Every request must carry `?t=<token>`.
        case tokenRequired(String)
    }

    /// Why a request was refused. Distinct cases because the two need
    /// opposite fixes and the operator cannot see the device.
    public enum Decision: Sendable, Equatable {
        case allow
        case missingToken
        case badToken
    }

    public var mode: Mode

    public init(mode: Mode) { self.mode = mode }

    /// A fresh per-launch token. Not a credential and not stored anywhere:
    /// it dies with the process, so a token seen once cannot be replayed
    /// against a later session.
    ///
    /// 128 bits of `SystemRandomNumberGenerator`. The threat here is a
    /// stranger on the same Wi-Fi, not an offline attacker with the
    /// binary — length is chosen so guessing is hopeless over a LAN, not
    /// to resist cryptanalysis.
    public static func freshToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = UInt64.random(in: .min ... .max, using: &generator)
        let low = UInt64.random(in: .min ... .max, using: &generator)
        return String(format: "%016llx%016llx", high, low)
    }

    /// Decide one request.
    ///
    /// EVERY path is gated, not just the mutating ones. `/frame.jpg` is a
    /// live picture of the room the device is standing in — it is the most
    /// sensitive thing here, not the least, and an earlier design that
    /// protected only `/cmd` would have left it open. `/sessions` matters
    /// for the same reason and is routed before `/cmd`, so a
    /// mutation-only gate would have missed it entirely.
    public func decide(token: String?) -> Decision {
        switch mode {
        case .open:
            return .allow
        case .tokenRequired(let expected):
            guard let token, !token.isEmpty else { return .missingToken }
            return Self.constantTimeEquals(token, expected) ? .allow : .badToken
        }
    }

    /// Length-independent comparison, so a wrong guess reveals nothing
    /// through timing. Overkill for a LAN debug tool; it costs four lines
    /// and removes the need to think about it again.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// The `t` value from a raw request path (`/state.json?t=abc&x=1`).
    /// Returns nil when absent, so `decide` can tell "no token offered"
    /// from "wrong token offered".
    public static func token(fromRawPath rawPath: String) -> String? {
        guard let queryStart = rawPath.firstIndex(of: "?") else { return nil }
        let query = rawPath[rawPath.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "t" else { continue }
            return String(parts[1])
        }
        return nil
    }

    /// The URL to hand a human. The token rides in the query string so the
    /// viewer page can read it back out of `location.search` and attach it
    /// to its own fetches — no templating, and nothing to leak into the
    /// page body where a screenshot would carry it.
    public func viewerURL(host: String, port: UInt16) -> String {
        switch mode {
        case .open:
            return "http://\(host):\(port)"
        case .tokenRequired(let token):
            return "http://\(host):\(port)/?t=\(token)"
        }
    }
}
