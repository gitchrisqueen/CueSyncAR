//
//  SessionReplay.swift
//  SessionReplay
//
//  Deterministic, table-free replay of a recorded (or scripted) session
//  bundle through the real perception → aim → solver midsection, on any
//  platform Swift runs on. Task B2. This is what turns "stand at the
//  table at night" into "run the suite": every future perception, tracking
//  or physics change is judged against a fixed eval set of bundles whose
//  replay must be BYTE-EQUAL (the golden) and must clear the accuracy
//  thresholds (AccuracyReport).
//
//  Bundle layout (a directory; every text file is canonical JSON, see
//  CanonicalJSON.swift — video is optional and absent for scripted bundles):
//
//      manifest.json      SessionManifest
//      calibration.json   RecordedCalibration (the locked TableCalibration)
//      frames.jsonl       RecordedFrameMeta, one per frame, index-ordered
//      detections.jsonl   RecordedDetectionFrame, one per detected frame
//      events.jsonl       RecordedEvent (taps: designate, call pocket, reset)
//      truth.json         SessionTruth (ground-truth ball layout)
//      outputs.jsonl      OutputRecord — the replay's golden (frozen)
//

import Foundation

public enum SessionBundleSchema {
    /// Bumped on any incompatible change to the file formats above.
    public static let version = 1
}
