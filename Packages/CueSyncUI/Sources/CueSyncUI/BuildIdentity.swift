//
//  BuildIdentity.swift
//  CueSyncUI
//
//  "Is the thing in my hand the thing I just read about?" — the pure model
//  behind the HUD build badge, the debug-mirror page and the startup log
//  line. Values are injected by the app's Embed Build Identity build phase
//  (see Scripts/embed-build-identity.sh); every one of them is optional and
//  degrades to "unknown" so a shallow/detached CI checkout still builds and
//  still reports honestly.
//

import Foundation

/// Identity of the binary actually running: where it came from in git, and
/// what the bundle calls itself.
///
/// Deliberately dependency-free and string-in/string-out so the formatting
/// rules (dirty marker, detached HEAD, missing values) are unit-testable on
/// Linux without a Bundle, a device, or Xcode.
public struct BuildIdentity: Sendable, Equatable {
    /// Placeholder substituted for any value the build phase could not
    /// determine. Shown verbatim — an honest "unknown" beats a plausible lie.
    public static let unknown = "unknown"

    /// Value git reports for `--abbrev-ref HEAD` when HEAD is not on a branch.
    public static let detachedHeadMarker = "HEAD"

    /// Info.plist keys written by the Embed Build Identity build phase.
    public enum InfoKey {
        public static let commit = "CueSyncGitCommit"
        public static let branch = "CueSyncGitBranch"
        public static let dirty = "CueSyncGitDirty"
        public static let buildDate = "CueSyncBuildDate"
        public static let marketingVersion = "CFBundleShortVersionString"
        public static let buildNumber = "CFBundleVersion"
    }

    /// One labelled row of the expanded badge / mirror table.
    public struct Field: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Short git SHA the build came from, or `unknown`.
    public let commit: String
    /// Branch name, `HEAD` for a detached build, or `unknown`.
    public let branch: String
    /// Whether the working tree had uncommitted changes at build time.
    public let isDirty: Bool
    /// ISO-8601 UTC build timestamp, or `unknown`.
    public let buildDate: String
    /// `CFBundleShortVersionString`.
    public let marketingVersion: String
    /// `CFBundleVersion`.
    public let buildNumber: String

    public init(commit: String?,
                branch: String?,
                isDirty: Bool,
                buildDate: String?,
                marketingVersion: String?,
                buildNumber: String?) {
        self.commit = Self.normalize(commit)
        self.branch = Self.normalize(branch)
        self.isDirty = isDirty
        self.buildDate = Self.normalize(buildDate)
        self.marketingVersion = Self.normalize(marketingVersion)
        self.buildNumber = Self.normalize(buildNumber)
    }

    /// Builds the identity from a bundle's info dictionary
    /// (`Bundle.main.infoDictionary`). A `nil` dictionary — or one missing
    /// every key, as in a build made before the build phase existed —
    /// yields an all-`unknown` identity rather than a crash.
    public init(infoDictionary: [String: Any]?) {
        func string(_ key: String) -> String? { infoDictionary?[key] as? String }
        self.init(commit: string(InfoKey.commit),
                  branch: string(InfoKey.branch),
                  isDirty: Self.parseDirty(string(InfoKey.dirty)),
                  buildDate: string(InfoKey.buildDate),
                  marketingVersion: string(InfoKey.marketingVersion),
                  buildNumber: string(InfoKey.buildNumber))
    }

    /// Trims whitespace and maps empty/absent values onto `unknown`.
    private static func normalize(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknown : trimmed
    }

    /// The build phase writes `YES`/`NO`; be liberal in what we accept so a
    /// hand-edited plist or a future writer still reads correctly.
    public static func parseDirty(_ raw: String?) -> Bool {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "y", "true", "1", "dirty": true
        default: false
        }
    }

    // MARK: Derived display values

    /// True when the build came from a commit that is not on any branch —
    /// how CI checks out a pull request.
    public var isDetachedHead: Bool { branch == Self.detachedHeadMarker }

    /// True when nothing about the source revision could be determined.
    public var isCommitKnown: Bool { commit != Self.unknown }

    /// Branch as a human reads it: `detached` rather than the raw `HEAD`.
    public var branchLabel: String {
        isDetachedHead ? "detached" : branch
    }

    /// SHA plus the dirty marker: `4f3a91c` / `4f3a91c-dirty`.
    /// An unknown SHA never gains a marker — there is nothing to be dirty.
    public var commitLabel: String {
        guard isCommitKnown else { return Self.unknown }
        return isDirty ? "\(commit)-dirty" : commit
    }

    /// `1.0 (12)` — marketing version with the build number.
    public var versionLabel: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    /// The collapsed badge: everything he needs at a glance, one short line.
    /// `1.0 (12) · 4f3a91c*` — the asterisk is the dirty marker, kept
    /// narrow so the badge never crowds the AR view.
    public var compactLabel: String {
        let sha = isCommitKnown && isDirty ? "\(commit)*" : commit
        return "\(versionLabel) · \(sha)"
    }

    /// The command to paste into a terminal to see exactly this build's
    /// source. `nil` when the SHA is unknown and the command would lie.
    public var gitShowCommand: String? {
        isCommitKnown ? "git show \(commit)" : nil
    }

    /// Rows for the expanded badge and the mirror page, in reading order.
    public var fields: [Field] {
        [Field(label: "Version", value: versionLabel),
         Field(label: "Commit", value: commitLabel),
         Field(label: "Branch", value: branchLabel),
         Field(label: "Built", value: buildDate)]
    }

    /// One line for `os.Logger` at startup, so a console capture answers
    /// "which build was this?" without any UI.
    public var logLine: String {
        "build identity: version=\(versionLabel) commit=\(commit) "
            + "dirty=\(isDirty ? "yes" : "no") branch=\(branch) built=\(buildDate)"
    }

    /// Flat, JSON-safe payload for the debug mirror's `/state.json`.
    public var jsonFields: [String: String] {
        ["version": marketingVersion,
         "buildNumber": buildNumber,
         "commit": commit,
         "dirty": isDirty ? "yes" : "no",
         "branch": branch,
         "built": buildDate,
         "summary": compactLabel]
    }
}
