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

import Foundation
import TableSpace

import CueSyncCore

enum CalibrationStore {
    private static let calibrationKey = "savedAnchoredCalibration"
    private static let tableSpecKey = "savedTableSpec"

    /// Location of the serialized ARWorldMap for the saved venue.
    static var worldMapURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent("cuesync-venue-worldmap.dat")
    }

    static var hasWorldMap: Bool {
        FileManager.default.fileExists(atPath: worldMapURL.path)
    }

    static func load() -> AnchoredCalibration? {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey) else {
            return nil
        }
        // Migrate venues locked under the old symmetric snap rule: an 8 ft
        // label over a field measured 9 cm smaller draws every pocket
        // outside the real one. Correcting on load means an existing table
        // is fixed at next launch rather than needing a re-tap.
        return (try? JSONDecoder().decode(AnchoredCalibration.self, from: data))?
            .correctingUndersizedSnap()
    }

    static func save(_ anchored: AnchoredCalibration) {
        guard let data = try? JSONEncoder().encode(anchored) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        try? FileManager.default.removeItem(at: worldMapURL)
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
