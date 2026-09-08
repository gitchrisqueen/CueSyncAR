//
//  SHA256.swift
//  SessionReplay
//
//  Content hashes for bundle integrity: manifest.json names the sha256 of
//  every other file in the bundle, so a pull over Wi-Fi (Scripts/
//  pull-session.sh) and a later fixture commit can both prove the bytes
//  are the ones the device wrote. Linux has no CryptoKit and this package
//  takes no dependencies, so the digest is implemented here (FIPS 180-4,
//  ~80 lines); on Apple platforms CryptoKit is used for speed and the
//  pure implementation is kept as the cross-check in the tests.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum SHA256 {
    /// Lower-case hex digest of `data`.
    public static func hexDigest(of data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { Self.hex($0) }.joined()
        #else
        return PureSHA256.hexDigest(of: data)
        #endif
    }

    /// Digest of a file, read in 1 MiB chunks so a 200 MB video never sits
    /// in memory whole.
    public static func hexDigest(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { Self.hex($0) }.joined()
        #else
        var hasher = PureSHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
        #endif
    }

    /// Digest of a directory tree (a compiled Core ML model is one): the
    /// sha256 of the concatenation, over files sorted by relative path,
    /// of `relativePath + NUL + sha256(contents)`. Stable across hosts and
    /// independent of the directory's absolute location.
    public static func hexDigest(ofDirectoryAt directory: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory,
                                                  includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var entries: [(path: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            entries.append((relative, url))
        }
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        var manifest = Data()
        for entry in entries {
            manifest.append(Data(entry.path.utf8))
            manifest.append(0)
            manifest.append(Data(try hexDigest(ofFileAt: entry.url).utf8))
        }
        return hexDigest(of: manifest)
    }

    static func hex(_ byte: UInt8) -> String {
        let table = Array("0123456789abcdef")
        return String([table[Int(byte >> 4)], table[Int(byte & 0x0F)]])
    }
}

/// Dependency-free SHA-256 (FIPS 180-4). The tests compare it against
/// CryptoKit on Apple platforms; on Linux it is the only implementation.
struct PureSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var messageLength: UInt64 = 0

    init() {}

    static func hexDigest(of data: Data) -> String {
        var hasher = PureSHA256()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    mutating func update(_ data: Data) {
        messageLength += UInt64(data.count)
        buffer.append(contentsOf: data)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(Array(buffer[offset..<offset + 64]))
            offset += 64
        }
        buffer.removeFirst(offset)
    }

    mutating func finalizeHex() -> String {
        var padding: [UInt8] = [0x80]
        let remainder = (buffer.count + 1) % 64
        let zeros = remainder <= 56 ? 56 - remainder : 120 - remainder
        padding.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        let bits = messageLength &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
        buffer.append(contentsOf: padding)
        var offset = 0
        while offset < buffer.count {
            compress(Array(buffer[offset..<offset + 64]))
            offset += 64
        }
        buffer.removeAll()
        return state.map { word in
            (0..<4).map { SHA256.hex(UInt8((word >> UInt32(24 - $0 * 8)) & 0xFF)) }.joined()
        }.joined()
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16
                | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = Self.rotr(w[i - 15], 7) ^ Self.rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = Self.rotr(w[i - 2], 17) ^ Self.rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
