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

enum CalibrationStore {
    private static let calibrationKey = "savedAnchoredCalibration"

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
        return try? JSONDecoder().decode(AnchoredCalibration.self, from: data)
    }

    static func save(_ anchored: AnchoredCalibration) {
        guard let data = try? JSONEncoder().encode(anchored) else { return }
        UserDefaults.standard.set(data, forKey: calibrationKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: calibrationKey)
        try? FileManager.default.removeItem(at: worldMapURL)
    }
}
