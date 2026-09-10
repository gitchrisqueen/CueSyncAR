//
//  SavedTablesTests.swift
//  CueSync AR
//
//  The property that matters is negative: nothing a user did not ask to
//  delete ever disappears.
//

import CueSyncCore
import Foundation
import Testing
@testable import TableSpace

@Suite("Saved tables")
struct SavedTablesTests {

    private func calibration(size: TableSize = .eightFoot,
                             yaw: Double = 0) -> AnchoredCalibration {
        let up = Vec3(0, 1, 0)
        let xAxis = Vec3(cos(yaw), 0, sin(yaw)).normalized
        let table = TableCalibration(origin: Vec3(0, -0.5, -2),
                                     xAxis: xAxis, yAxis: up.cross(xAxis).normalized,
                                     size: size)
        return AnchoredCalibration(calibration: table, anchorTransform: .identity)
    }

    @Test("A second venue does not destroy the first")
    func secondTableDoesNotOverwrite() {
        // The whole bug, as one test.
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        let home = index.mostRecentlyUsed
        index.save(calibration(size: .nineFoot), activeID: nil, name: "League")

        #expect(index.tables.count == 2)
        #expect(index.table(id: home!.id) != nil, "the home table was silently replaced")
        #expect(index.tables.map(\.size).contains(.nineFoot))
    }

    @Test("Re-locking the table you are already on updates it instead of duplicating")
    func relockUpdatesTheActiveTable() {
        var index = SavedTableIndex()
        guard case let .added(first) = index.save(calibration(), activeID: nil,
                                                  name: "Home") else {
            Issue.record("first save did not add"); return
        }
        let outcome = index.save(calibration(yaw: 0.4), activeID: first.id, name: "Home")
        guard case let .updated(updated) = outcome else {
            Issue.record("re-lock did not update, got \(outcome)"); return
        }
        #expect(index.tables.count == 1)
        #expect(updated.id == first.id)
        #expect(updated.calibration != first.calibration, "the update kept the old geometry")
    }

    @Test("Every table gets its own world-map file")
    func worldMapFilenamesAreDistinct() {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        index.save(calibration(), activeID: nil, name: "League")
        let names = Set(index.tables.map(\.worldMapFilename))
        #expect(names.count == 2, "two tables shared a world-map path")
    }

    @Test("A full store refuses rather than evicting the oldest")
    func fullStoreRefuses() {
        // Evicting the least recently used would be the same silent
        // deletion in a new costume.
        var index = SavedTableIndex()
        for number in 0..<SavedTableIndex.capacity {
            index.save(calibration(), activeID: nil, name: "Table \(number)")
        }
        #expect(index.isFull)
        let outcome = index.save(calibration(), activeID: nil, name: "One too many")
        #expect(outcome == .full)
        #expect(index.tables.count == SavedTableIndex.capacity)
    }

    @Test("A full store can still update a table you are working on")
    func fullStoreStillUpdates() {
        var index = SavedTableIndex()
        for number in 0..<SavedTableIndex.capacity {
            index.save(calibration(), activeID: nil, name: "Table \(number)")
        }
        let existing = index.mostRecentlyUsed!
        let outcome = index.save(calibration(yaw: 0.2), activeID: existing.id, name: "x")
        guard case .updated = outcome else {
            Issue.record("a full store refused to re-lock an existing table"); return
        }
    }

    @Test("Two tables never share a name a person cannot tell apart")
    func namesAreMadeUnique() {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        index.save(calibration(), activeID: nil, name: "Home")
        index.save(calibration(), activeID: nil, name: "Home")
        #expect(Set(index.tables.map(\.name)) == ["Home", "Home 2", "Home 3"])
    }

    @Test("An empty name becomes something rather than nothing")
    func blankNamesAreReplaced() {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "   ")
        #expect(index.tables.first?.name == "Table")
    }

    @Test("Renaming to blank is refused, not stored")
    func blankRenameIsRefused() {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        let id = index.tables[0].id
        // Hoisted: #expect cannot take a mutating call.
        let blankRefused = index.rename(id: id, to: "  ")
        #expect(!blankRefused)
        #expect(index.tables[0].name == "Home")
        let renamed = index.rename(id: id, to: "Garage")
        #expect(renamed)
        #expect(index.tables[0].name == "Garage")
    }

    @Test("Removing hands back the record so its world map can go too")
    func removeReturnsTheRecord() {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        let id = index.tables[0].id
        let removed = index.remove(id: id)
        #expect(removed?.worldMapFilename.contains(id.uuidString) == true)
        #expect(index.tables.isEmpty)
        let removedAgain = index.remove(id: id)
        #expect(removedAgain == nil, "removing twice invented a record")
    }

    @Test("The list is ordered by when each table was last used")
    func orderedByRecency() {
        var index = SavedTableIndex()
        let start = Date(timeIntervalSince1970: 1_000_000)
        index.save(calibration(), activeID: nil, name: "Old", now: start)
        index.save(calibration(), activeID: nil, name: "New", now: start + 100)
        #expect(index.byMostRecentlyUsed.map(\.name) == ["New", "Old"])

        let oldID = index.tables.first { $0.name == "Old" }!.id
        index.touch(id: oldID, now: start + 200)
        #expect(index.byMostRecentlyUsed.map(\.name) == ["Old", "New"])
    }

    @Test("An existing single-table calibration survives the upgrade")
    func migrationKeepsTheOnlyTable() {
        // Anyone who already calibrated must not lose it — that is the
        // same harm arriving from the other direction.
        let existing = calibration(size: .sevenFoot)
        let index = SavedTableIndex.migrating(single: existing)
        #expect(index.tables.count == 1)
        #expect(index.tables[0].calibration == existing)
        #expect(!index.tables[0].name.isEmpty)
    }

    @Test("The index round-trips through JSON")
    func codableRoundTrip() throws {
        var index = SavedTableIndex()
        index.save(calibration(), activeID: nil, name: "Home")
        index.save(calibration(size: .nineFoot), activeID: nil, name: "League")
        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(SavedTableIndex.self, from: data)
        #expect(decoded == index)
    }
}
