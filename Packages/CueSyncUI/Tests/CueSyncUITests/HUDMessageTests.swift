import Testing
@testable import CueSyncUI

/// The top of the HUD is one status capsule and one toast. These tests are
/// the argument for which line wins the toast, so the answer lives here and
/// not in a view builder where nobody can assert on it.
@Suite("HUD message priority")
struct HUDMessagePriorityTests {
    @Test("A denied camera outranks everything else")
    func cameraDeniedWins() {
        let message = HUDMessage.resolve(cameraDenied: true,
                                         calibrationError: "Corners don't form a rectangle",
                                         tapFeedback: "Pocket called",
                                         modeHint: "Tap a pocket to call it")
        #expect(message == HUDMessage.cameraDenied)
        #expect(message?.tone == .critical)
    }

    @Test("A failed action outranks a successful one")
    func calibrationErrorBeatsTapFeedback() {
        let message = HUDMessage.resolve(cameraDenied: false,
                                         calibrationError: "Place all four corners first",
                                         tapFeedback: "Pocket called")
        #expect(message?.kind == .calibrationError)
        #expect(message?.text == "Place all four corners first")
    }

    @Test("What just happened outranks standing advice")
    func tapFeedbackBeatsModeHint() {
        let message = HUDMessage.resolve(cameraDenied: false,
                                         tapFeedback: "Cue ball marked",
                                         modeHint: "Tap a pocket to call it")
        #expect(message?.kind == .tapFeedback)
        #expect(message?.tone == .neutral)
    }

    @Test("The hint speaks only when nothing else does")
    func modeHintIsLast() {
        let message = HUDMessage.resolve(cameraDenied: false,
                                         modeHint: "Tap a pocket to call it")
        #expect(message?.kind == .modeHint)
        #expect(message?.tone == .advisory)
    }

    @Test("Silence is a valid answer")
    func nothingToSay() {
        #expect(HUDMessage.resolve(cameraDenied: false) == nil)
    }

    /// A nil field and an empty one mean the same thing to a player, and a
    /// blank capsule reads as a rendering bug.
    @Test("Blank text is no message at all")
    func blankIsNotAMessage() {
        #expect(HUDMessage.resolve(cameraDenied: false, tapFeedback: "") == nil)
        #expect(HUDMessage.resolve(cameraDenied: false, modeHint: "   \n") == nil)
        let message = HUDMessage.resolve(cameraDenied: false,
                                         tapFeedback: "  ",
                                         modeHint: "Tap a pocket to call it")
        #expect(message?.kind == .modeHint)
    }

    @Test("Only ever one message reaches the screen")
    func resolutionIsSingular() {
        let all: [HUDMessage?] = [
            .cameraDenied,
            HUDMessage(kind: .calibrationError, text: "e"),
            HUDMessage(kind: .tapFeedback, text: "t"),
            HUDMessage(kind: .modeHint, text: "h")
        ]
        #expect(HUDMessage.highestPriority(among: all) == HUDMessage.cameraDenied)
        #expect(HUDMessage.highestPriority(among: all.reversed()) == HUDMessage.cameraDenied)
        #expect(HUDMessage.highestPriority(among: [nil, nil]) == nil)
        #expect(HUDMessage.highestPriority(among: []) == nil)
    }

    /// Order-independence is the property that keeps the caller honest: no
    /// re-ordering of arguments in RootView can change what a player reads.
    @Test("Argument order cannot change the answer")
    func orderIndependent() {
        let candidates: [HUDMessage] = HUDMessage.Kind.allCases.map {
            HUDMessage(kind: $0, text: "\($0)")
        }
        for rotation in 0..<candidates.count {
            let rotated = Array(candidates[rotation...] + candidates[..<rotation])
            #expect(HUDMessage.highestPriority(among: rotated)?.kind == .cameraDenied)
        }
    }
}

@Suite("HUD message copy and tone")
struct HUDMessageCopyTests {
    /// The camera-denied line is the app's terminal state; it must say what
    /// to do about it, not merely that something is wrong.
    @Test func cameraDeniedSaysWhereToFixIt() {
        #expect(HUDMessage.cameraDenied.text.contains("Settings"))
        #expect(HUDMessage.cameraDenied.kind == .cameraDenied)
    }

    @Test("Every kind has a tone, and failures read as failures")
    func tonesAreAssigned() {
        for kind in HUDMessage.Kind.allCases {
            let tone = HUDMessage(kind: kind, text: "x").tone
            switch kind {
            case .cameraDenied, .calibrationError: #expect(tone == .critical)
            case .tapFeedback: #expect(tone == .neutral)
            case .modeHint: #expect(tone == .advisory)
            }
        }
    }

    @Test("Priority is the declaration order, highest first")
    func kindOrder() {
        #expect(HUDMessage.Kind.allCases == [.cameraDenied, .calibrationError, .tapFeedback, .modeHint])
        #expect(HUDMessage.Kind.cameraDenied < HUDMessage.Kind.calibrationError)
        #expect(HUDMessage.Kind.tapFeedback < HUDMessage.Kind.modeHint)
    }
}
