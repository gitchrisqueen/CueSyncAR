//
//  ExternalTableView.swift
//  DisplayKit
//
//  The broadcast Table View scene content (M4-02 styling pass pending):
//  full-bleed TableSceneView on a dark stage, sized for 10-foot viewing.
//  The hosting UIWindowScene wiring lives in the app target (it owns the
//  scene lifecycle); this package supplies the content and the router.
//

#if canImport(SwiftUI)
import CueSyncCore
import CueSyncUI
import SwiftUI

public struct ExternalTableView: View {
    public let state: TableState
    public let prediction: ShotPrediction?

    public init(state: TableState, prediction: ShotPrediction?) {
        self.state = state
        self.prediction = prediction
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TableSceneView(state: state, prediction: prediction)
                .padding(48)
        }
        .accessibilityIdentifier("external-table-view")
    }
}
#endif
