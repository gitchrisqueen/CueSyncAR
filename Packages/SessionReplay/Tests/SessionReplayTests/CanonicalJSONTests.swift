import Foundation
import Testing
@testable import SessionReplay

@Suite("CanonicalJSON")
struct CanonicalJSONTests {
    @Test(arguments: [
        (0.0, "0.000000"),
        (-0.0, "0.000000"),
        (1.0, "1.000000"),
        (0.635, "0.635000"),
        (-0.6985, "-0.698500"),
        (100.3, "100.300000"),
        (0.0000004, "0.000000"),
        (0.0000005, "0.000000"),      // ties to even at the grid
        (0.0000015, "0.000002"),
        (-0.0000004, "0.000000"),     // rounds to zero: no "-0.000000"
        (123456.7891234, "123456.789123"),
        (0.028575, "0.028575")
    ])
    func fixedFormatting(value: Double, expected: String) {
        #expect(CanonicalJSON.formatFixed(value) == expected)
    }

    @Test func textRoundTripIsIdempotent() throws {
        // value → text → Double → text must reproduce the text exactly:
        // that is what makes a re-read bundle re-serialize byte-equal.
        var rng = SplitMix64(seed: 7)
        for _ in 0..<2000 {
            let value = rng.uniform(-3...3)
            let text = CanonicalJSON.formatFixed(value)
            let parsed = try #require(Double(text))
            #expect(CanonicalJSON.formatFixed(parsed) == text)
            #expect(abs(parsed - value) <= 0.5e-6)
        }
    }

    @Test func objectsSortKeysByByteOrderAndUseNoWhitespace() {
        let value: JSONValue = .object([
            "zeta": .int(1),
            "Alpha": .bool(true),
            "beta": .null,
            "a": .array([.double(1), .string("x")]),
            "_under": .double(-2.5)
        ])
        #expect(CanonicalJSON.serialize(value)
                == #"{"Alpha":true,"_under":-2.500000,"a":[1.000000,"x"],"beta":null,"zeta":1}"#)
    }

    @Test func stringsEscapeOnlyWhatJSONRequires() {
        let text = "quote\" back\\slash\nnew\ttab \u{01} ünïcode / slash"
        let serialized = CanonicalJSON.serialize(.string(text))
        #expect(serialized == #""quote\" back\\slash\nnew\ttab \u0001 ünïcode / slash""#)
        // And Foundation reads it back verbatim.
        let decoded = try? JSONDecoder().decode([String].self, from: Data("[\(serialized)]".utf8))
        #expect(decoded == [text])
    }

    @Test func linesAreNewlineTerminated() {
        let text = CanonicalJSON.serializeLines([.int(1), .object(["k": .int(2)])])
        #expect(text == "1\n{\"k\":2}\n")
    }

    @Test func intsAndDoublesAreDistinctOnTheWire() {
        #expect(CanonicalJSON.serialize(.array([.int(3), .double(3)])) == "[3,3.000000]")
    }

    @Test func everyValueIsParseableByFoundation() throws {
        let value: JSONValue = .object([
            "frame": .int(12), "t": .double(100.3), "ok": .bool(false),
            "list": .array([.double(-0.5), .null, .string("s")])
        ])
        let data = Data(CanonicalJSON.serialize(value).utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["frame"] as? Int == 12)
        #expect(object?["t"] as? Double == 100.3)
    }
}
