//
//  RootView.swift
//  CueSync AR
//
//  Live camera + AR scene with the minimal M0 HUD. The real calibration
//  flow and overlay renderer land in M3 (see docs/roadmap/06-MILESTONES.md).
//

import CueSyncUI
import SwiftUI

struct RootView: View {
    @Environment(SessionModel.self) private var model

    var body: some View {
        ZStack {
            arSurface
                .ignoresSafeArea()
            VStack {
                statusCapsule
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var arSurface: some View {
        #if targetEnvironment(simulator)
        SimulatorPlaceholderView()
        #else
        ARTableContainerView()
        #endif
    }

    private var statusCapsule: some View {
        StatusCapsule(status: hudStatus)
    }

    private var hudStatus: HUDStatus {
        switch model.phase {
        case .launching: .launching
        case .findingTable: .findingTable
        case .ready: .tracking(ballCount: 0)
        }
    }
}

/// Shown on the Simulator, where ARKit cannot run.
struct SimulatorPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(red: Theme.feltGreen.red,
                  green: Theme.feltGreen.green,
                  blue: Theme.feltGreen.blue)
                .opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "arkit")
                    .font(.system(size: 44))
                Text("AR requires a physical device")
                    .font(.headline)
                Text("Run on an iPhone to see the table.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if canImport(ARKit) && !targetEnvironment(simulator)
import ARKit
import RealityKit

/// Minimal AR surface: world tracking with horizontal plane detection and
/// the system coaching overlay. M3 replaces this with the calibration flow
/// and overlay renderer from ARExperience.
struct ARTableContainerView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        arView.session.run(configuration)

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coaching.frame = arView.bounds
        arView.addSubview(coaching)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif

#Preview {
    RootView()
        .environment(SessionModel())
}
