//
//  MirrorLogReader.swift
//  CueSync AR
//
//  Backs `GET /logs` on the debug mirror: the app's own recent os.Logger
//  lines (subsystem com.cuesync.ar) as plain text, so a Mac or an agent can
//  read what the device logged over the same Wi-Fi/Tailscale link as
//  `/state.json`, with no Xcode console and no copy-paste.
//
//  Query (all optional):  n=<max lines, default 300>  since=<seconds back,
//  default 900>  category=<session|pipeline|mirror|...>  level=<debug|info|
//  notice|error|fault, minimum>
//
//  Only this process's entries are readable (OSLogStore .currentProcessIdentifier
//  needs no entitlement). The mirror's access policy gates the route like every
//  other path. Values logged without `privacy: .public` may read `<private>`.
//

import Foundation
import OSLog

enum MirrorLogReader {
    static let subsystem = "com.cuesync.ar"

    /// One formatted line: `2026-11-09T16:42:07.123Z notice session message`.
    static func line(date: Date, level: String, category: String, message: String) -> String {
        "\(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))) \(level) \(category) \(message)"
    }

    /// Rank used for the `level=` minimum filter.
    static func rank(_ level: String) -> Int {
        switch level {
        case "debug": 0
        case "info": 1
        case "notice": 2
        case "error": 3
        case "fault": 4
        default: 0
        }
    }

    private static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }

    /// Newest `limit` lines no older than `sinceSeconds`, oldest first.
    static func read(limit: Int, sinceSeconds: Double, category: String?,
                     minimumLevel: String?) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-max(1, sinceSeconds)))
            let entries = try store.getEntries(
                at: start,
                matching: NSPredicate(format: "subsystem == %@", subsystem))
            let floor = rank(minimumLevel ?? "debug")
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                if let category, entry.category != category { continue }
                let level = name(entry.level)
                if rank(level) < floor { continue }
                lines.append(line(date: entry.date, level: level,
                                  category: entry.category, message: entry.composedMessage))
            }
            return lines.suffix(max(1, limit)).joined(separator: "\n") + "\n"
        } catch {
            return "log read failed: \(error)\n"
        }
    }
}
