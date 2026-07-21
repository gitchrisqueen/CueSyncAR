//
//  DetectionModelCatalog.swift
//  CueSync AR
//
//  Candidate hosted models for A/B evaluation (M2-01 selection). EDIT THIS
//  LIST to add/remove candidates or fix version numbers — the version is the
//  number shown on each Roboflow Universe project's Model page (the trained
//  version, e.g. ".../model/3" → version: 3).
//

import DetectionRoboflow

enum DetectionModelCatalog {
    static let candidates: [RoboflowModelRef] = [
        RoboflowModelRef(slug: "pool-ball-agzev", version: 1,
                         label: "xhujustin — Pool Ball"),
        RoboflowModelRef(slug: "pool-ball-detecion", version: 1,
                         label: "leonardo — Ball Detection"),
        RoboflowModelRef(slug: "pool-ball-detection-v8huq", version: 1,
                         label: "kwinten — Ball Detection"),
        // Table detection: not needed for MVP calibration (ARKit plane +
        // corners does that) — included to observe whether it could later
        // auto-propose rail corners (M3-02 enhancement).
        RoboflowModelRef(slug: "pool-table-detection", version: 1,
                         label: "leonardo — TABLE detection")
    ]
}
