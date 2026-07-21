//
//  CalibrationController.swift
//  ARExperience
//
//  Task M3-02 (logic): the calibration flow state machine from
//  05-UX-DESIGN — find plane → confirm rails via corner handles → lock.
//  Pure value type; the SwiftUI/ARKit layer feeds it events and renders its
//  state. World-anchor persistence attaches at the app layer.
//

import CueSyncCore
import Foundation
import TableSpace

public struct CalibrationController: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Waiting for ARKit plane detection.
        case searchingPlane
        /// Plane found; waiting for a rail-rectangle proposal (auto-detect
        /// or user placement).
        case planeFound
        /// Corners proposed/being adjusted. Order: c0→c1 and c3→c2 are
        /// opposite edges (TableCalibration.fromCorners contract).
        case adjusting(corners: [Vec3])
        /// Calibration locked and usable.
        case locked(TableCalibration)
    }

    public enum Event: Sendable {
        case planeDetected
        case planeLost
        case cornersProposed([Vec3])
        case cornerMoved(index: Int, to: Vec3)
        case lockRequested
        case resetRequested
        /// A persisted calibration came back from world-anchor
        /// relocalization — jump straight to locked (05-UX-DESIGN: a
        /// returning user at a saved venue skips to Ready).
        case restored(TableCalibration)
    }

    public private(set) var state: State = .searchingPlane
    /// Set when the last lock attempt failed (cleared by any other event).
    public private(set) var lastError: CalibrationError?

    public init() {}

    public var isLocked: Bool {
        if case .locked = state { return true }
        return false
    }

    public var calibration: TableCalibration? {
        if case let .locked(calibration) = state { return calibration }
        return nil
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> State {
        lastError = nil
        switch (state, event) {
        case (.searchingPlane, .planeDetected):
            state = .planeFound

        case (.planeFound, .cornersProposed(let corners)) where corners.count == 4:
            state = .adjusting(corners: corners)

        case (.adjusting(var corners), .cornerMoved(let index, let position))
            where corners.indices.contains(index):
            corners[index] = position
            state = .adjusting(corners: corners)

        case (.adjusting(let corners), .lockRequested):
            do {
                state = .locked(try TableCalibration.fromCorners(corners))
            } catch let error as CalibrationError {
                lastError = error // stay in .adjusting; UI shows the reason
            } catch {
                lastError = .degenerateCorners
            }

        case (_, .planeLost) where !isLocked:
            // Losing the plane mid-flow restarts the search; a locked
            // calibration survives (relocalization handles transient loss).
            state = .searchingPlane

        case (_, .resetRequested):
            state = .searchingPlane

        case (_, .restored(let calibration)) where !isLocked:
            // Relocalization wins over any in-progress manual flow, but
            // never silently replaces a calibration the user already locked
            // this session.
            state = .locked(calibration)

        default:
            break // ignore events that don't apply to the current state
        }
        return state
    }
}
