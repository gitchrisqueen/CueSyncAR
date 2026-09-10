//
//  SavedTables.swift
//  CueSync AR
//
//  More than one table, without one of them quietly eating the other.
//
//  The store held exactly one calibration key and one world-map file, so
//  calibrating anywhere but home destroyed home: no warning, no list, no
//  way back. Nobody would notice until the second venue, which is also
//  the first time the app is ever shown to anyone.
//
//  The fix is not "key it by the table", because NOTHING THE APP HAS CAN
//  IDENTIFY A TABLE. Two eight-foot tables are the same numbers; the only
//  thing that distinguishes venues is whether ARKit relocalizes a saved
//  world map, and that answer arrives seconds later, from the AR session,
//  long after the save has to be decided. Any scheme that guesses identity
//  at save time is guessing, and a wrong guess is the same silent
//  overwrite in a new costume.
//
//  So the rule here is the conservative one: A LOCK NEVER OVERWRITES A
//  TABLE IT WAS NOT ALREADY WORKING ON. Re-locking while a saved table is
//  active updates that table — the user is plainly re-doing that one.
//  Locking with nothing active adds a record. Deleting is the only thing
//  that removes data, and a person has to ask for it.
//
//  There is a cap, because a world map is megabytes and an unbounded list
//  would fill the device. Reaching it is reported, not resolved by
//  evicting the oldest: quietly deleting the least recently used table is
//  precisely the bug this file exists to remove, and "you have twelve
//  tables, delete one" is a sentence a person can act on.
//

import CueSyncCore
import Foundation

/// One remembered table: the calibration, what it is called, and when it
/// was last used.
public struct SavedTable: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// What the user calls it. Never empty — an unnamed table cannot be
    /// told from another unnamed table in a list, which is the whole
    /// point of having a list.
    public var name: String
    public var calibration: AnchoredCalibration
    public var lastUsed: Date

    public init(id: UUID = UUID(), name: String,
                calibration: AnchoredCalibration, lastUsed: Date = Date()) {
        self.id = id
        self.name = name
        self.calibration = calibration
        self.lastUsed = lastUsed
    }

    /// The table's size, from the calibration rather than stored twice.
    public var size: TableSize { calibration.size }

    /// Where this table's ARWorldMap lives, relative to the app's support
    /// directory. Derived from the id so two tables can never collide, and
    /// so a stale file is identifiable by the id in its name.
    public var worldMapFilename: String { "cuesync-worldmap-\(id.uuidString).dat" }
}

/// Everything the app remembers about tables, and the rules for changing
/// it.
public struct SavedTableIndex: Sendable, Equatable, Codable {

    /// The most tables that may be kept at once.
    ///
    /// Each carries an ARWorldMap of a few megabytes. Twelve is past any
    /// plausible number of venues one player visits and still bounded.
    public static let capacity = 12

    public private(set) var tables: [SavedTable]

    public init(tables: [SavedTable] = []) {
        self.tables = tables
    }

    /// Newest first — the order a list should show them in.
    public var byMostRecentlyUsed: [SavedTable] {
        tables.sorted { $0.lastUsed > $1.lastUsed }
    }

    public var mostRecentlyUsed: SavedTable? { byMostRecentlyUsed.first }

    public var isFull: Bool { tables.count >= Self.capacity }

    public func table(id: UUID) -> SavedTable? { tables.first { $0.id == id } }

    /// What happened when a lock was saved, so the caller can say so.
    public enum SaveOutcome: Sendable, Equatable {
        /// A table the user was already working on was brought up to date.
        case updated(SavedTable)
        /// A new table was remembered.
        case added(SavedTable)
        /// Nothing was saved, because saving would have meant deleting
        /// something the user never asked to delete.
        case full
    }

    /// Record a lock.
    ///
    /// `activeID` is the table the session was already working on — a
    /// relocalized one, or one just saved. Passing it is what makes a
    /// re-lock an update instead of a duplicate; passing nil is what makes
    /// a new venue a new record instead of an overwrite.
    @discardableResult
    public mutating func save(_ calibration: AnchoredCalibration,
                              activeID: UUID?,
                              name: @autoclosure () -> String,
                              now: Date = Date()) -> SaveOutcome {
        if let activeID, let index = tables.firstIndex(where: { $0.id == activeID }) {
            tables[index].calibration = calibration
            tables[index].lastUsed = now
            return .updated(tables[index])
        }
        guard !isFull else { return .full }
        let table = SavedTable(name: Self.uniqueName(name(), among: tables),
                               calibration: calibration, lastUsed: now)
        tables.append(table)
        return .added(table)
    }

    /// Note that a table was used, so the list stays in a useful order.
    public mutating func touch(id: UUID, now: Date = Date()) {
        guard let index = tables.firstIndex(where: { $0.id == id }) else { return }
        tables[index].lastUsed = now
    }

    /// Rename. Refuses a blank name rather than storing one.
    @discardableResult
    public mutating func rename(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = tables.firstIndex(where: { $0.id == id }) else {
            return false
        }
        tables[index].name = Self.uniqueName(trimmed,
                                             among: tables.filter { $0.id != id })
        return true
    }

    /// Forget a table. Returns it so the caller can delete its world map —
    /// the file is the caller's business, but the filename is not
    /// recoverable once the record is gone.
    @discardableResult
    public mutating func remove(id: UUID) -> SavedTable? {
        guard let index = tables.firstIndex(where: { $0.id == id }) else { return nil }
        return tables.remove(at: index)
    }

    /// Make `name` unique by appending a number, so a list never shows two
    /// rows a person cannot tell apart.
    static func uniqueName(_ name: String, among others: [SavedTable]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Table" : trimmed
        let taken = Set(others.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Adopt a calibration saved by the single-table store.
    ///
    /// The old layout had one unnamed calibration and one world map at a
    /// fixed path. Migration keeps both — the record and the file it
    /// points at — because the alternative is that everyone who already
    /// calibrated their table loses it on upgrade, which is the same harm
    /// arriving from the other direction.
    public static func migrating(single calibration: AnchoredCalibration,
                                 named name: String = "My table",
                                 id: UUID = UUID(),
                                 now: Date = Date()) -> SavedTableIndex {
        SavedTableIndex(tables: [SavedTable(id: id, name: name,
                                            calibration: calibration, lastUsed: now)])
    }
}
