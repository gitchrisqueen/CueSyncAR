import Testing
@testable import CueSyncUI

@Suite("Build identity")
struct BuildIdentityTests {
    /// A clean tagged build on a named branch — the everyday case.
    private static let clean = BuildIdentity(commit: "4f3a91c",
                                             branch: "main",
                                             isDirty: false,
                                             buildDate: "2026-09-07T18:04:11Z",
                                             marketingVersion: "1.0",
                                             buildNumber: "12")

    @Test func allValuesPresentRenderCompactly() {
        let identity = Self.clean
        #expect(identity.versionLabel == "1.0 (12)")
        #expect(identity.commitLabel == "4f3a91c")
        #expect(identity.compactLabel == "1.0 (12) · 4f3a91c")
        #expect(identity.branchLabel == "main")
        #expect(identity.isDetachedHead == false)
        #expect(identity.gitShowCommand == "git show 4f3a91c")
    }

    @Test func dirtyBuildsCarryAMarkerEverywhere() {
        let identity = BuildIdentity(commit: "4f3a91c",
                                     branch: "claude/build-identity",
                                     isDirty: true,
                                     buildDate: "2026-09-07T18:04:11Z",
                                     marketingVersion: "1.0",
                                     buildNumber: "12")
        #expect(identity.commitLabel == "4f3a91c-dirty")
        #expect(identity.compactLabel == "1.0 (12) · 4f3a91c*")
        #expect(identity.jsonFields["dirty"] == "yes")
        #expect(identity.logLine.contains("dirty=yes"))
        // A dirty build is still a real commit — the SHA stays pasteable.
        #expect(identity.gitShowCommand == "git show 4f3a91c")
    }

    @Test func cleanBuildsCarryNoMarker() {
        #expect(Self.clean.commitLabel.contains("dirty") == false)
        #expect(Self.clean.compactLabel.contains("*") == false)
        #expect(Self.clean.jsonFields["dirty"] == "no")
        #expect(Self.clean.logLine.contains("dirty=no"))
    }

    /// How CI checks out a pull request: HEAD is not on a branch.
    @Test func detachedHeadReadsAsDetached() {
        let identity = BuildIdentity(commit: "0a1b2c3",
                                     branch: "HEAD",
                                     isDirty: false,
                                     buildDate: "2026-09-07T18:04:11Z",
                                     marketingVersion: "1.0",
                                     buildNumber: "12")
        #expect(identity.isDetachedHead)
        #expect(identity.branchLabel == "detached")
        // The raw git value survives into the machine-readable surfaces.
        #expect(identity.jsonFields["branch"] == "HEAD")
        #expect(identity.compactLabel == "1.0 (12) · 0a1b2c3")
    }

    /// No git at all (shallow checkout, exported tarball, git missing):
    /// every field degrades to "unknown" and nothing pretends otherwise.
    @Test func allValuesMissingDegradeToUnknown() {
        let identity = BuildIdentity(commit: nil,
                                     branch: nil,
                                     isDirty: false,
                                     buildDate: nil,
                                     marketingVersion: nil,
                                     buildNumber: nil)
        #expect(identity.commit == BuildIdentity.unknown)
        #expect(identity.branch == BuildIdentity.unknown)
        #expect(identity.buildDate == BuildIdentity.unknown)
        #expect(identity.commitLabel == BuildIdentity.unknown)
        #expect(identity.compactLabel == "unknown (unknown) · unknown")
        #expect(identity.isCommitKnown == false)
        #expect(identity.gitShowCommand == nil)
        #expect(identity.isDetachedHead == false)
    }

    /// Empty and whitespace-only plist values are as absent as missing ones.
    @Test func blankValuesNormalizeToUnknown() {
        let identity = BuildIdentity(commit: "   ",
                                     branch: "",
                                     isDirty: true,
                                     buildDate: "\n",
                                     marketingVersion: " 1.1 ",
                                     buildNumber: "3")
        #expect(identity.commit == BuildIdentity.unknown)
        #expect(identity.branch == BuildIdentity.unknown)
        #expect(identity.buildDate == BuildIdentity.unknown)
        #expect(identity.marketingVersion == "1.1")
        // Nothing to mark dirty when there is no SHA to mark.
        #expect(identity.commitLabel == BuildIdentity.unknown)
        #expect(identity.compactLabel == "1.1 (3) · unknown")
    }

    @Test func infoDictionaryIsRead() {
        let identity = BuildIdentity(infoDictionary: [
            BuildIdentity.InfoKey.commit: "abcdef1",
            BuildIdentity.InfoKey.branch: "main",
            BuildIdentity.InfoKey.dirty: "YES",
            BuildIdentity.InfoKey.buildDate: "2026-09-07T18:04:11Z",
            BuildIdentity.InfoKey.marketingVersion: "2.3",
            BuildIdentity.InfoKey.buildNumber: "44"
        ])
        #expect(identity.compactLabel == "2.3 (44) · abcdef1*")
        #expect(identity.isDirty)
        #expect(identity.branchLabel == "main")
    }

    /// A build made before this build phase existed has none of the keys.
    @Test func infoDictionaryWithoutBuildPhaseKeysStillWorks() {
        let identity = BuildIdentity(infoDictionary: [
            BuildIdentity.InfoKey.marketingVersion: "1.0",
            BuildIdentity.InfoKey.buildNumber: "1"
        ])
        #expect(identity.compactLabel == "1.0 (1) · unknown")
        #expect(identity.isDirty == false)
    }

    @Test func nilInfoDictionaryIsSafe() {
        let identity = BuildIdentity(infoDictionary: nil)
        #expect(identity.compactLabel == "unknown (unknown) · unknown")
    }

    @Test(arguments: [("YES", true), ("yes", true), ("true", true), ("1", true),
                      ("NO", false), ("no", false), ("0", false), ("", false)])
    func dirtyFlagParsing(raw: String, expected: Bool) {
        #expect(BuildIdentity.parseDirty(raw) == expected)
    }

    @Test func dirtyFlagParsingHandlesNil() {
        #expect(BuildIdentity.parseDirty(nil) == false)
    }

    @Test func fieldsAreLabelledInReadingOrder() {
        #expect(Self.clean.fields.map(\.label) == ["Version", "Commit", "Branch", "Built"])
        #expect(Self.clean.fields.map(\.value)
            == ["1.0 (12)", "4f3a91c", "main", "2026-09-07T18:04:11Z"])
        // Identifiable ids must be unique or SwiftUI's ForEach misbehaves.
        #expect(Set(Self.clean.fields.map(\.id)).count == Self.clean.fields.count)
    }

    @Test func jsonFieldsCarryTheWholeIdentity() {
        let json = Self.clean.jsonFields
        #expect(json["version"] == "1.0")
        #expect(json["buildNumber"] == "12")
        #expect(json["commit"] == "4f3a91c")
        #expect(json["branch"] == "main")
        #expect(json["built"] == "2026-09-07T18:04:11Z")
        #expect(json["summary"] == "1.0 (12) · 4f3a91c")
    }

    @Test func logLineNamesEveryField() {
        let line = Self.clean.logLine
        for fragment in ["version=1.0 (12)", "commit=4f3a91c", "dirty=no",
                         "branch=main", "built=2026-09-07T18:04:11Z"] {
            #expect(line.contains(fragment), "log line missing \(fragment): \(line)")
        }
    }
}
