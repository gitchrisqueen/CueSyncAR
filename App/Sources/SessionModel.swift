//
//  SessionModel.swift
//  CueSync AR
//
//  The app's single source of truth and composition root: registers the
//  default provider implementations (see docs/roadmap/02-ARCHITECTURE.md)
//  and exposes session state to SwiftUI.
//

import BilliardsPhysics
import CueSyncCore
import Observation

@MainActor
@Observable
final class SessionModel {
    enum Phase {
        case launching
        case findingTable
        case ready
    }

    let registry = ProviderRegistry()
    private(set) var phase: Phase = .launching

    /// Registers default providers. Fixture mode (UI tests / previews)
    /// swaps these before views appear.
    func bootstrap() async {
        await registry.register(AnalyticSolver() as any TrajectorySolving)
        await registry.register(AppSecrets() as any SecretsProviding)
        phase = .findingTable
    }
}
