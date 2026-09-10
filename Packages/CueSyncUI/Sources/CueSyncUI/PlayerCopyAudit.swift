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
