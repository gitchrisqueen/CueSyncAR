//
//  DebugMirrorServer+Sessions.swift
//  CueSync AR
//
//  Serves recorded session bundles over the LAN so Scripts/pull-session.sh
//  can fetch them without a cable:
//    GET /sessions                       JSON listing (ids, files, sizes)
//    GET /sessions/<id>/<file>           the file; honours `Range: bytes=`
//                                        so an interrupted pull resumes
//  Files stream in 1 MiB chunks — a 200 MB video never sits in memory.
//  Names are validated to one path segment each; nothing outside
//  Documents/Sessions is reachable. The listing carries ids and file
//  names only — no paths, no device identity.
//

import Foundation
import Network

extension DebugMirrorServer {
    private static let chunkSize = 1 << 20

    /// Called for every request whose path starts with `/sessions`.
    /// Owns the connection from here on.
    func serveSessions(path: String, requestHead: String, connection: NWConnection) {
        let components = path.split(separator: "/").map(String.init)
        // ["sessions"] | ["sessions", id, file]
        switch components.count {
        case 1:
            send(Self.httpResponse(body: listingJSON(), contentType: "application/json"),
                 over: connection)
        case 3:
            guard let root = sessionsRoot, Self.isSafeName(components[1]),
                  Self.isSafeName(components[2]) else {
                send(Self.httpResponse(status: "404 Not Found"), over: connection)
                return
            }
            let url = root.appendingPathComponent(components[1]).appendingPathComponent(components[2])
            serveFile(url, range: Self.rangeStart(in: requestHead), connection: connection)
        default:
            send(Self.httpResponse(status: "404 Not Found"), over: connection)
        }
    }

    /// One path segment: ASCII letters/digits/`._-`, not starting with a
    /// dot (so `..` and hidden files are out), at most 128 characters.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, let first = name.utf8.first,
              Self.isAlphanumeric(first) else { return false }
        return name.utf8.allSatisfy { Self.isAlphanumeric($0) || $0 == UInt8(ascii: ".")
            || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    /// `Range: bytes=N-` → N (only the open-ended form curl -C - sends).
    static func rangeStart(in requestHead: String) -> Int? {
        for line in requestHead.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" }) {
            let lower = line.lowercased()
            guard lower.hasPrefix("range:") else { continue }
            let value = lower.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("bytes=") else { return nil }
            let spec = value.dropFirst("bytes=".count)
            guard let dash = spec.firstIndex(of: "-"), let start = Int(spec[..<dash]) else { return nil }
            return start
        }
        return nil
    }

    private func listingJSON() -> Data {
        var sessions: [[String: Any]] = []
        if let root = sessionsRoot,
           let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for id in ids.sorted(by: >) where Self.isSafeName(id) {
                let directory = root.appendingPathComponent(id)
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
                    continue
                }
                var files: [[String: Any]] = []
                var total = 0
                for name in names.sorted() where Self.isSafeName(name) {
                    let attributes = try? FileManager.default.attributesOfItem(
                        atPath: directory.appendingPathComponent(name).path)
                    let bytes = (attributes?[.size] as? Int) ?? 0
                    total += bytes
                    files.append(["name": name, "bytes": bytes])
                }
                sessions.append(["id": id, "active": id == activeSessionID,
                                 "bytes": total, "files": files,
                                 "complete": names.contains("manifest.json")])
            }
        }
        var payload: [String: Any] = ["sessions": sessions]
        if sessionsRoot == nil {
            // An empty list and a withheld list look identical, and a
            // caller staring at `{"sessions":[]}` should not have to guess
            // which one it is holding.
            payload["note"] = "Recordings are not served until a recording "
                + "has been started on the device this launch."
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data("{\"sessions\":[]}".utf8)
    }

    private func serveFile(_ url: URL, range start: Int?, connection: NWConnection) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = attributes[.size] as? Int,
              let handle = try? FileHandle(forReadingFrom: url) else {
            send(Self.httpResponse(status: "404 Not Found"), over: connection)
            return
        }
        if let start, start >= total, total > 0 {
            // Nothing left to send (a resume of a complete file): say so
            // the standard way rather than inventing an empty range.
            try? handle.close()
            send(Self.httpResponse(status: "416 Range Not Satisfiable"), over: connection)
            return
        }
        let offset = min(max(start ?? 0, 0), total)
        var head = start == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Type: \(Self.contentType(for: url.pathExtension))\r\n"
        head += "Content-Length: \(total - offset)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if start != nil {
            head += "Content-Range: bytes \(offset)-\(max(total - 1, 0))/\(total)\r\n"
        }
        head += "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        try? handle.seek(toOffset: UInt64(offset))
        let cursor = FileCursor(handle: handle, remaining: total - offset)
        connection.send(content: Data(head.utf8), contentContext: .defaultMessage,
                        isComplete: cursor.remaining == 0,
                        completion: .contentProcessed { [weak self] error in
            guard error == nil, cursor.remaining > 0 else {
                cursor.close()
                connection.cancel()
                return
            }
            self?.sendNextChunk(cursor, over: connection)
        })
    }

    private func sendNextChunk(_ cursor: FileCursor, over connection: NWConnection) {
        let chunk = cursor.read(upTo: Self.chunkSize)
        let last = cursor.remaining == 0 || chunk.isEmpty
        connection.send(content: chunk, contentContext: .defaultMessage, isComplete: last,
                        completion: .contentProcessed { [weak self] error in
            if error != nil || last {
                cursor.close()
                connection.cancel()
                return
            }
            self?.sendNextChunk(cursor, over: connection)
        })
    }

    private func send(_ response: Data, over connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension {
        case "json": "application/json"
        case "jsonl": "application/x-ndjson"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }
}

/// A file being streamed to one connection; the send callbacks run
/// serially on the connection's queue.
private final class FileCursor: @unchecked Sendable {
    private let handle: FileHandle
    private(set) var remaining: Int

    init(handle: FileHandle, remaining: Int) {
        self.handle = handle
        self.remaining = remaining
    }

    func read(upTo size: Int) -> Data {
        let data = (try? handle.read(upToCount: min(size, remaining))) ?? Data()
        remaining -= data.count
        if data.isEmpty { remaining = 0 }
        return data
    }

    func close() {
        try? handle.close()
    }
}
