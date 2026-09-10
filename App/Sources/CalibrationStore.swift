//
//  CalibrationStore.swift
//  CueSync AR
//
//  Per-venue persistence for the table calibration (M3-02): the anchored
//  calibration (JSON in UserDefaults) plus the serialized ARWorldMap on
//  disk. On the next visit ARKit relocalizes the saved map, the table
//  anchor comes back, and AnchoredCalibration rebuilds the calibration in
//  the new session's world coordinates — no re-calibration needed.
//
//  It used to keep exactly ONE of each, so calibrating a second venue
//  destroyed the first with no warning and no way back. It now keeps a
//  list (TableSpace.SavedTableIndex holds the rules); the single-table
//  keys are read once and migrated so nobody loses the table they already
//  had. `load()` and friends still answer for the most recently used
//  table, which is what every existing caller means by "the" calibration.
//

import Foundation
import TableSpace

import CueSyncCore

enum CalibrationStore {
    private static let calibrationKey = "savedAnchoredCalibration"
    private static let tableSpecKey = "savedTableSpec"
    private static let indexKey = "savedTableIndex"
    private static let activeKey = "activeSavedTableID"

    private static var supportDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    /// Where the single-table world map used to live. Still read, so an
    /// existing venue survives the upgrade; never written again.
    private static var legacyWorldMapURL: URL {
        supportDirectory.appendingPathComponent("cuesync-venue-worldmap.dat")
    }

    // MARK: The list

    /// Every remembered table, migrating the single-table keys the first
    /// time it is asked.
    static func tables() -> SavedTableIndex {
        if let data = UserDefaults.standard.data(forKey: indexKey),
           let index = try? JSONDecoder().decode(SavedTableIndex.self, from: data) {
            return index
        }
        guard let legacy = legacyCalibration() else { return SavedTableIndex() }
        // Adopt the old record, and move its world map to the new
        // per-table name so the venue still relocalizes.
        let migrated = SavedTableIndex.migrating(single: legacy)
        if let table = migrated.tables.first,
           FileManager.default.fileExists(atPath: legacyWorldMapURL.path) {
            try? FileManager.default.moveItem(at: legacyWorldMapURL,
                                              to: worldMapURL(for: table))
        }
        write(migrated)
        return migrated
    }

    static func write(_ index: SavedTableIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
    }

    /// The table the session is working on, if any. Nil means a lock
    /// creates a new record rather than overwriting somebody's venue.
    static var activeTableID: UUID? {
        get { UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeKey)
            }
        }
    }

    static func worldMapURL(for table: SavedTable) -> URL {
        supportDirectory.appendingPathComponent(table.worldMapFilename)
    }

    /// Forget one table, and its world map with it. The only thing in here
    /// that deletes anything.
    static func remove(id: UUID) {
        var index = tables()
        guard let removed = index.remove(id: id) else { return }
        try? FileManager.default.removeItem(at: worldMapURL(for: removed))
        if activeTableID == id { activeTableID = nil }
        write(index)
    }

    static func rename(id: UUID, to name: String) {
        var index = tables()
        guard index.rename(id: id, to: name) else { return }
        write(index)
    }

    // MARK: The current table, which is what every existing caller means

    /// The calibration in play: the active table, else the most recently
    /// used one.
    static func currentTable() -> SavedTable? {
        let index = tables()
        if let activeTableID, let table = index.table(id: activeTableID) { return table }
        return index.mostRecentlyUsed
    }

    /// Location of the serialized ARWorldMap for the table in play.
    ///
    /// Falls back to a fresh id when nothing is saved yet, so the first
    /// lock of a brand-new install has somewhere to write before its
    /// record exists.
    static var worldMapURL: URL {
        guard let table = currentTable() else {
            return supportDirectory.appendingPathComponent("cuesync-worldmap-pending.dat")
        }
        return worldMapURL(for: table)
    }

    static var hasWorldMap: Bool {
        FileManager.default.fileExists(atPath: worldMapURL.path)
    }

    static func load() -> AnchoredCalibration? {
        // Migrate venues locked under the old symmetric snap rule: an 8 ft
        // label over a field measured 9 cm smaller draws every pocket
        // outside the real one. Correcting on load means an existing table
        // is fixed at next launch rather than needing a re-tap.
        currentTable()?.calibration.correctingUndersizedSnap()
    }

    private static func legacyCalibration() -> AnchoredCalibration? {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AnchoredCalibration.self, from: data)
    }

    /// Save a lock. Updates the table being worked on, or remembers a new
    /// one; never replaces a table the session was not already on.
    @discardableResult
    static func save(_ anchored: AnchoredCalibration) -> SavedTableIndex.SaveOutcome {
        var index = tables()
        let pending = worldMapURL
        // The name is computed first: `save` takes it as an autoclosure,
        // and evaluating it inside would be a second access to `index`
        // while `save` holds it exclusively.
        let name = defaultName(for: index)
        let outcome = index.save(anchored, activeID: activeTableID, name: name)
        switch outcome {
        case .added(let table):
            activeTableID = table.id
            // The world map may already have been written to the pending
            // path before this record existed; move it under the record's
            // own name so the venue relocalizes next time.
            let destination = worldMapURL(for: table)
            if pending != destination,
               FileManager.default.fileExists(atPath: pending.path) {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: pending, to: destination)
            }
        case .updated(let table):
            activeTableID = table.id
        case .full:
            break
        }
        write(index)
        return outcome
    }

    /// What to call a table nobody has named. Numbered rather than blank,
    /// because a list of identical rows is not a list.
    private static func defaultName(for index: SavedTableIndex) -> String {
        index.tables.isEmpty ? "My table" : "Table \(index.tables.count + 1)"
    }

    /// Forget the table in play — its anchor and world map are stale.
    ///
    /// Deliberately narrow: it clears ONE table, the one being worked on,
    /// and leaves every other venue alone.
    static func clear() {
        if let table = currentTable() {
            remove(id: table.id)
        }
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        try? FileManager.default.removeItem(at: legacyWorldMapURL)
        // The table SPEC deliberately survives: clearing a venue means "the
        // anchor/world map is stale", not "the table changed size".
    }

    // MARK: Table spec ("my table is this size", venue-independent)

    /// The user's known table size from the last lock. Re-pins that measure
    /// within tolerance of it snap back to it, so repeat calibrations of
    /// the same table can't wander between size classes.
    static func loadTableSpec() -> TableSize? {
        guard let data = UserDefaults.standard.data(forKey: tableSpecKey) else {
            return nil
        }
        return try? JSONDecoder().decode(TableSize.self, from: data)
    }

    static func saveTableSpec(_ size: TableSize) {
        guard let data = try? JSONEncoder().encode(size) else { return }
        UserDefaults.standard.set(data, forKey: tableSpecKey)
    }
}
