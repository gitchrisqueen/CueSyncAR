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
        // This one VVV working
        RoboflowModelRef(slug: "pool-ball-agzev", version: 1,
                         label: "xhujustin — Pool Ball"),
        // leonardo's "pool-ball-detecion" is removed: the Universe project
        // (leonardo-wijaya-bdcih) has 3 dataset versions but NO deployed
        // trained model at any of them — the hosted API can never serve it.
        // Its 1.67k-image dataset remains a training-data lead for M2-01.
        // Replacement candidate, verified deployed on Universe: 81.2%
        // mAP@50, classifies each ball 0–15 individually (identity!).
        RoboflowModelRef(slug: "pool-balls-detection-srlqi", version: 8,
                         label: "mark — Pool Balls (numbered)"),
        // This one VVV working
        RoboflowModelRef(slug: "pool-ball-detection-v8huq", version: 1,
                         label: "kwinten — Ball Detection"),
        // Table detection: not needed for MVP calibration (ARKit plane +
        // corners does that) — included to observe whether it could later
        // auto-propose rail corners (M3-02 enhancement).
        //RoboflowModelRef(slug: "pool-table-detection", version: 6,
        //                 label: "leonardo — TABLE detection")
    ]
}
