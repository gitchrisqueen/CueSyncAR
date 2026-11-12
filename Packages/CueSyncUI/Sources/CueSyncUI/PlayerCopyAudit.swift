//
//  PlayerCopyAudit.swift
//  CueSync AR
//
//  What a string is not allowed to say to a player.
//
//  This exists because the same class of leak kept reappearing: a raw enum
//  case rendered as a Settings value ("Running on: onDevice"), a shell
//  script named in a toast, `/cmd` syntax offered as advice, an ARKit
//  tracking-state name shown as a status. Each was fixed by hand and each
//  came back somewhere else, because nothing checked.
//
//  So the rule is a value, and a test runs it over the copy this package
//  owns. It is a lint for one specific mistake — jargon escaping into the
//  player's world — not a style guide.
//

import Foundation

/// A rule about player-visible copy, and what breaks it.
public enum PlayerCopyAudit {

    /// One thing wrong with one string.
    public struct Violation: Sendable, Equatable, CustomStringConvertible {
        public let text: String
        public let offender: String
        public let reason: String

        public var description: String {
            "\"\(text)\" contains \"\(offender)\" — \(reason)"
        }
    }

    /// Words that look like camelCase identifiers but are just how these
    /// things are spelled. Without this, "iPhone" and "AirPlay" would be
    /// reported forever and the rule would get switched off.
    static let allowedMixedCase: Set<String> = [
        "iPhone", "iPad", "iOS", "iPadOS", "AirPlay", "CueSync", "mAP", "FPS",
    ]

    /// Substrings that never belong in front of a player, with the reason
    /// spelled out so a failure explains itself.
    static let bannedSubstrings: [(String, String)] = [
        ("(remote)", "a developer marker for mirror-driven actions"),
        ("Scripts/", "a path in the source tree"),
        (".sh", "a shell script"),
        (".swift", "a source file"),
        (".json", "a file format the player never sees"),
        ("/cmd", "the debug mirror's command endpoint"),
        ("&v=", "query-string syntax"),
        ("x0:y0", "a coordinate format from the mirror API"),
        ("ARKit", "the framework's name, not the player's problem"),
        ("RealityKit", "the framework's name, not the player's problem"),
        ("raycast", "implementation vocabulary"),
        ("intrinsics", "implementation vocabulary"),
        ("nil", "a programming value"),
        ("TableState", "a type name"),
    ]

    /// Check one player-visible string.
    public static func violations(in text: String) -> [Violation] {
        var found: [Violation] = []
        for (needle, reason) in bannedSubstrings
        where text.range(of: needle, options: .caseInsensitive) != nil {
            found.append(Violation(text: text, offender: needle, reason: reason))
        }
        for word in identifierLikeWords(in: text) {
            found.append(Violation(text: text, offender: word,
                                   reason: "looks like a raw identifier, not a word"))
        }
        return found
    }

    /// Words that start lowercase and then capitalise — `onDevice`,
    /// `insufficientFeatures`, `guidedDrill`. That shape is how a raw enum
    /// case reads when someone prints `.rawValue` by mistake, which is
    /// exactly the bug this catches.
    static func identifierLikeWords(in text: String) -> [String] {
        var offenders: [String] = []
        for rawWord in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let word = rawWord.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard word.count > 2, !allowedMixedCase.contains(word) else { continue }
            guard let first = word.first, first.isLowercase, first.isLetter else { continue }
            let hasInnerCapital = word.dropFirst().contains { $0.isUppercase }
            let isAllLetters = word.allSatisfy { $0.isLetter }
            if hasInnerCapital && isAllLetters { offenders.append(word) }
        }
        return offenders
    }
}

// MARK: - Developer strings

extension PlayerCopyAudit {

    /// Terms that belong to a developer surface only. With developer mode
    /// off, the More and Settings sheets show none of them. Whole words,
    /// case-insensitive, except "MB" (case-sensitive: "mb" is inside words).
    static let developerWords: [(pattern: String, caseSensitive: Bool, reason: String)] = [
        ("debug", false, "a developer surface"),
        ("mirror", false, "the debug mirror"),
        ("address", false, "a network address"),
        ("detector", false, "the detection model, not the player's concern"),
        ("xcconfig", false, "a build-config file"),
        ("probe", false, "the Neural Engine probe"),
        ("frames?", false, "a recording internal"),
        ("MB", true, "a file size from the recorder"),
        // A commit hash: 7 to 40 hex digits with at least one digit in it.
        ("(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}", false, "a commit hash"),
    ]

    /// Check one string a player can see in the More or Settings sheet
    /// with developer mode off, for developer vocabulary. A separate rule
    /// from `violations(in:)`: "Mirror it to a TV over AirPlay" is fine
    /// elsewhere, but the debug mirror must not show up in a sheet.
    public static func developerViolations(in text: String) -> [Violation] {
        var found: [Violation] = []
        for rule in developerWords {
            let options: NSRegularExpression.Options = rule.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: "\\b\(rule.pattern)\\b",
                                                       options: options) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let swiftRange = Range(match.range, in: text) {
                found.append(Violation(text: text, offender: String(text[swiftRange]),
                                       reason: rule.reason))
            }
        }
        return found
    }

    /// Whether `text` writes a count of one with a plural noun: "1 balls".
    /// The nouns are the ones the HUD counts.
    public static func hasWrongPlural(in text: String) -> Bool {
        text.range(of: "\\b1 (balls|objects|shots|corners|pockets|tables)\\b",
                   options: .regularExpression) != nil
    }
}
