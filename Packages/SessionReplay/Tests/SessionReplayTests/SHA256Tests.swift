import Foundation
import Testing
@testable import SessionReplay

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionReplayTests-\(name)-\(UInt64.random(in: 0...UInt64.max))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SHA256 — bundle integrity hashes")
struct SHA256Tests {
    // FIPS 180-4 / NIST vectors.
    private let vectors: [(String, String)] = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    ]

    @Test func pureImplementationMatchesTheVectors() {
        for (message, digest) in vectors {
            #expect(PureSHA256.hexDigest(of: Data(message.utf8)) == digest)
        }
        // One million 'a' (the classic long-message vector) exercises the
        // multi-block path with an odd tail.
        let million = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(PureSHA256.hexDigest(of: million)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func publicDigestAgreesWithThePureImplementation() {
        for (message, digest) in vectors {
            #expect(SHA256.hexDigest(of: Data(message.utf8)) == digest)
        }
        let data = Data((0..<70_000).map { UInt8($0 % 251) })
        #expect(SHA256.hexDigest(of: data) == PureSHA256.hexDigest(of: data))
    }

    @Test func incrementalUpdatesMatchOneShot() {
        var hasher = PureSHA256()
        let data = Data((0..<10_007).map { UInt8($0 % 13) })
        var offset = 0
        for size in [1, 63, 64, 65, 1000, 8000, 879] {
            let end = min(data.count, offset + size)
            hasher.update(data[offset..<end])
            offset = end
        }
        hasher.update(data[offset...])
        #expect(hasher.finalizeHex() == PureSHA256.hexDigest(of: data))
    }

    @Test func fileAndDirectoryDigestsAreStableAndPathIndependent() throws {
        let a = try temporaryDirectory("digest-a")
        let b = try temporaryDirectory("digest-b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        for root in [a, b] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("weights"),
                                                    withIntermediateDirectories: true)
            try Data("model".utf8).write(to: root.appendingPathComponent("model.bin"))
            try Data("w".utf8).write(to: root.appendingPathComponent("weights/weight.bin"))
        }
        #expect(try SHA256.hexDigest(ofFileAt: a.appendingPathComponent("model.bin"))
                == SHA256.hexDigest(of: Data("model".utf8)))
        let digestA = try SHA256.hexDigest(ofDirectoryAt: a)
        #expect(digestA == (try SHA256.hexDigest(ofDirectoryAt: b)),
                "same tree in two locations hashes the same")
        try Data("w2".utf8).write(to: b.appendingPathComponent("weights/weight.bin"))
        #expect(digestA != (try SHA256.hexDigest(ofDirectoryAt: b)))
    }
}
