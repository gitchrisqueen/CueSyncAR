//
//  ExternalDisplayRouter.swift
//  DisplayKit
//
//  Task M4-01 (logic): the external-display state machine from
//  05-UX-DESIGN. Pure value type; the UIKit scene layer feeds it
//  connect/disconnect events and renders its state. Hot-plug rules:
//  disconnection never tears down the AR session, and the user's last
//  choice is remembered for the next connection.
//

import CueSyncCore
import Foundation

public struct ExternalDisplayRouter: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// No external display attached.
        case disconnected
        /// Display attached; asking the user Mirror vs Table View.
        case prompting
        /// System mirroring (no dedicated scene content).
        case mirroring
        /// Dedicated top-down Table View scene is live.
        case tableView
    }

    public enum Event: Sendable, Equatable {
        case displayConnected
        case displayDisconnected
        case userChose(DisplayOutputKind)
    }

    public private(set) var state: State = .disconnected
    /// Remembered across reconnects: skip the prompt after the first choice.
    public private(set) var preferredOutput: DisplayOutputKind?

    public init(preferredOutput: DisplayOutputKind? = nil) {
        self.preferredOutput = preferredOutput
    }

    /// Whether the dedicated external scene should currently render.
    public var isTableViewActive: Bool { state == .tableView }

    @discardableResult
    public mutating func handle(_ event: Event) -> State {
        switch (state, event) {
        case (.disconnected, .displayConnected):
            // A remembered preference skips the prompt (05-UX-DESIGN:
            // "Table View (default after first use)").
            switch preferredOutput {
            case .tableView: state = .tableView
            case .mirror: state = .mirroring
            case nil: state = .prompting
            }

        case (.prompting, .userChose(let kind)):
            preferredOutput = kind
            state = kind == .tableView ? .tableView : .mirroring

        case (.mirroring, .userChose(let kind)), (.tableView, .userChose(let kind)):
            // Switching modes while connected is allowed from the HUD.
            preferredOutput = kind
            state = kind == .tableView ? .tableView : .mirroring

        case (_, .displayDisconnected):
            state = .disconnected

        default:
            break
        }
        return state
    }
}
