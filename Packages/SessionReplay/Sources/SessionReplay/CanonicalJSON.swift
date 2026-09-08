//
//  CanonicalJSON.swift
//  SessionReplay
//
//  A canonical JSON serializer: the ONE way every bundle file is written,
//  so "byte-equal outputs" is a property of the data and not of whichever
//  JSON library happened to format it.
//
//  Why not JSONEncoder: its number formatting is an implementation detail
//  (Darwin Foundation, swift-corelibs-foundation and swift-foundation have
//  each printed doubles differently over the years: `1` vs `1.0`, shortest
//  round-trip vs 17 significant digits) and `.sortedKeys` ordering follows
//  String comparison rules that are not byte order. A golden compared
//  across macOS (where fixtures are authored) and Linux (where CI judges
//  them) cannot rest on that.
//
//  Rules (the wire contract for every *.json / *.jsonl in a bundle):
//  - Object keys sorted by UTF-8 byte order; keys are ASCII by convention.
//  - No whitespace. One record per line in .jsonl, "\n" terminated.
//  - Doubles are FIXED-POINT with exactly six decimals ("0.635000"):
//    a micrometer grid for meters, a microsecond grid for seconds. That
//    absorbs last-ulp platform differences in libm-dependent values (only a
//    value within 1e-16 of a rounding boundary can print differently) and
//    makes the text round-trip through any JSON parser to the same Double
//    the writer would print again. Values must be finite and below 1e12.
//  - Negative zero prints as "0.000000".
//  - Integers print as integers; the record builders decide which fields
//    are integral (ids, frame indices, counts) — never the value.
//  - Strings escape `"`, `\` and control characters only; everything else
//    is emitted as UTF-8.
//

import Foundation

/// A JSON value with an explicit int/double distinction so record builders
/// control the wire format.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum CanonicalJSON {
    /// Decimal places every double is printed with.
    public static let decimals = 6
    private static let scale = 1_000_000.0
    /// Largest magnitude representable with six fixed decimals in Int64
    /// without overflow (with headroom).
    private static let maximumMagnitude = 1e12

    /// Serialize `value` canonically (no trailing newline).
    public static func serialize(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    /// One JSONL line per record, each "\n"-terminated.
    public static func serializeLines(_ records: [JSONValue]) -> String {
        var out = ""
        for record in records {
            write(record, into: &out)
            out.append("\n")
        }
        return out
    }

    /// Fixed six-decimal rendering of a finite double (see file header).
    /// The Double→text mapping is a pure function of the IEEE value:
    /// `value * 1e6` is one correctly-rounded multiply, `.rounded` is exact,
    /// and the rest is integer arithmetic — no locale, no printf.
    public static func formatFixed(_ value: Double) -> String {
        precondition(value.isFinite, "canonical JSON cannot encode \(value)")
        precondition(abs(value) < maximumMagnitude,
                     "canonical JSON magnitude limit exceeded: \(value)")
        var scaled = (value * scale).rounded(.toNearestOrEven)
        if scaled == 0 { scaled = 0 } // folds -0.0 into +0.0
        let negative = scaled < 0
        let magnitude = Int64(negative ? -scaled : scaled)
        let integer = magnitude / 1_000_000
        let fraction = magnitude % 1_000_000
        var fractionText = String(fraction)
        while fractionText.count < decimals {
            fractionText = "0" + fractionText
        }
        return (negative ? "-" : "") + String(integer) + "." + fractionText
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out.append("null")
        case .bool(let flag):
            out.append(flag ? "true" : "false")
        case .int(let number):
            out.append(String(number))
        case .double(let number):
            out.append(formatFixed(number))
        case .string(let text):
            writeString(text, into: &out)
        case .array(let items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                write(item, into: &out)
            }
            out.append("]")
        case .object(let members):
            out.append("{")
            let keys = members.keys.sorted { a, b in
                a.utf8.lexicographicallyPrecedes(b.utf8)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(",") }
                writeString(key, into: &out)
                out.append(":")
                write(members[key]!, into: &out)
            }
            out.append("}")
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16, uppercase: false)
                    out.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}

// MARK: - Builder conveniences

extension JSONValue {
    /// A 2-vector as `[x, y]`.
    static func vec2(_ v: SIMD2<Double>) -> JSONValue {
        .array([.double(v.x), .double(v.y)])
    }

    /// A 3-vector as `[x, y, z]`.
    static func vec3(_ v: SIMD3<Double>) -> JSONValue {
        .array([.double(v.x), .double(v.y), .double(v.z)])
    }

    static func doubles(_ values: [Double]) -> JSONValue {
        .array(values.map(JSONValue.double))
    }

    static func optional(_ value: JSONValue?) -> JSONValue {
        value ?? .null
    }
}
