//
//  MirrorAccessPolicyTests.swift
//  CueSync AR
//

import Testing
@testable import CoachKit

@Suite("Mirror access")
struct MirrorAccessPolicyTests {

    @Test("Open mode answers anything, including with no token at all")
    func openModeIsOpen() {
        let policy = MirrorAccessPolicy(mode: .open)
        #expect(policy.decide(token: nil) == .allow)
        #expect(policy.decide(token: "") == .allow)
        #expect(policy.decide(token: "anything") == .allow)
    }

    @Test("A request with no token is refused differently from a wrong one")
    func missingAndBadAreDistinct() {
        let policy = MirrorAccessPolicy(mode: .tokenRequired("cafe"))
        // The two need opposite fixes and the operator cannot see the
        // device, so they must not collapse into one refusal.
        #expect(policy.decide(token: nil) == .missingToken)
        #expect(policy.decide(token: "") == .missingToken)
        #expect(policy.decide(token: "beef") == .badToken)
        #expect(policy.decide(token: "cafe") == .allow)
    }

    @Test("A near-miss token is refused")
    func nearMissIsRefused() {
        let policy = MirrorAccessPolicy(mode: .tokenRequired("abc123"))
        for wrong in ["abc12", "abc1234", "abc124", "ABC123", " abc123"] {
            let detail = "expected \(wrong) to be refused"
            #expect(policy.decide(token: wrong) == .badToken, "\(detail)")
        }
    }

    @Test("Tokens are fresh every time and long enough to be hopeless to guess")
    func tokensAreFreshAndLong() {
        let tokens = (0..<50).map { _ in MirrorAccessPolicy.freshToken() }
        #expect(Set(tokens).count == 50)
        for token in tokens {
            #expect(token.count == 32)
            #expect(token.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("The token is read out of the query string, wherever it sits")
    func tokenParsing() {
        #expect(MirrorAccessPolicy.token(fromRawPath: "/state.json?t=abc") == "abc")
        #expect(MirrorAccessPolicy.token(fromRawPath: "/cmd?action=reset&t=abc") == "abc")
        #expect(MirrorAccessPolicy.token(fromRawPath: "/frame.jpg?t=abc&x=1") == "abc")
        // No token offered is not the same as an empty one.
        #expect(MirrorAccessPolicy.token(fromRawPath: "/state.json") == nil)
        #expect(MirrorAccessPolicy.token(fromRawPath: "/state.json?x=1") == nil)
        // A parameter that merely starts with "t" is not the token.
        #expect(MirrorAccessPolicy.token(fromRawPath: "/state.json?token=abc") == nil)
        #expect(MirrorAccessPolicy.token(fromRawPath: "/state.json?tt=abc") == nil)
    }

    @Test("The viewer URL carries the token only when one is required")
    func viewerURL() {
        let open = MirrorAccessPolicy(mode: .open)
        #expect(open.viewerURL(host: "10.0.0.4", port: 8787) == "http://10.0.0.4:8787")
        let gated = MirrorAccessPolicy(mode: .tokenRequired("abc"))
        #expect(gated.viewerURL(host: "10.0.0.4", port: 8787) == "http://10.0.0.4:8787/?t=abc")
    }

    @Test("Constant-time comparison still answers correctly")
    func constantTimeCompare() {
        #expect(MirrorAccessPolicy.constantTimeEquals("", ""))
        #expect(MirrorAccessPolicy.constantTimeEquals("abc", "abc"))
        #expect(!MirrorAccessPolicy.constantTimeEquals("abc", "abd"))
        #expect(!MirrorAccessPolicy.constantTimeEquals("abc", "ab"))
        #expect(!MirrorAccessPolicy.constantTimeEquals("ab", "abc"))
    }
}

@Suite("Mirror preference default")
struct MirrorDefaultTests {

    @Test("The mirror default is injected, so the package stays configuration-free")
    func defaultIsInjected() {
        #expect(SettingsModel(debugMirrorEnabledByDefault: true).debugMirrorEnabled)
        #expect(!SettingsModel(debugMirrorEnabledByDefault: false).debugMirrorEnabled)
    }

    @Test("A persisted value always wins over the injected default")
    func persistedValueWins() {
        // The consequence worth pinning: flipping the shipped default does
        // NOT change a device that has already written the old one down.
        let store = InMemorySettingsStore(storage: [SettingsKey.debugMirrorEnabled: .bool(true)])
        let loaded = SettingsModel(loading: store, debugMirrorEnabledByDefault: false)
        #expect(loaded.debugMirrorEnabled)
    }

    @Test("With nothing persisted, the injected default is what you get")
    func emptyStoreUsesTheDefault() {
        let store = InMemorySettingsStore()
        #expect(!SettingsModel(loading: store, debugMirrorEnabledByDefault: false).debugMirrorEnabled)
        #expect(SettingsModel(loading: store, debugMirrorEnabledByDefault: true).debugMirrorEnabled)
    }
}
