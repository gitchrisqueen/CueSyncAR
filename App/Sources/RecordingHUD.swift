//
//  RecordingHUD.swift
//  CueSync AR
//
//  The record button in the HUD bar and the live badge above the status
//  capsule. The button never does nothing: when a recording cannot start
//  the model says why on the HUD (and logs it); when it can, the size
//  cost is stated before anything is written.
//

import CueSyncUI
import SwiftUI

struct RecordButton: View {
    @Environment(SessionModel.self) private var model
    @State private var confirming = false
    /// True in the HUD bar, where the button carries its word ("Record" /
    /// "Stop"); the More sheet has its own row label and shows the icon.
    var labelled = false

    var body: some View {
        Button {
            if model.isRecording {
                Task { await model.stopRecording(reason: .user) }
            } else if let blocker = model.recordingBlocker {
                SessionModel.log.info("record button: \(blocker, privacy: .public)")
                model.showTapFeedback("Can't record: \(blocker)")
            } else {
                confirming = true
            }
        } label: {
            Label(labelled ? (model.isRecording ? "Stop" : "Record")
                           : (model.isRecording ? "Stop recording" : "Record session"),
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                .labelStyle(LabelledOrIconStyle(showsTitle: labelled))
                .foregroundStyle(model.isRecording ? Theme.hardText.color : Color.primary)
        }
        .accessibilityLabel(model.isRecording ? "Stop recording the session"
                            : "Record this session for replay")
        .accessibilityIdentifier("record-button")
        .confirmationDialog("Record this session?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Start recording (\(model.recordingCapMinutes) min max)") {
                Task { await model.startRecording() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.recordingSizeSummary)
        }
    }
}

/// Icon and word when `showsTitle`, else the icon alone.
private struct LabelledOrIconStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            HStack(spacing: 6) {
                configuration.icon
                configuration.title
            }
        } else {
            configuration.icon
        }
    }
}

/// "● REC 0:42 · 210 frames · ~32 MB" while a recording runs — the
/// proof, at the table, that frames are actually landing on disk.
struct RecordingBadge: View {
    let status: RecordingStatus
    @State private var developerMode = DeveloperMode.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(Theme.hardText.color)
            Text("REC \(status.clock)")
                .monospacedDigit()
            // Frame and megabyte counts are the proof for whoever is
            // debugging a recording, and noise to a player.
            if developerMode.isUnlocked {
                Text("· \(status.frames) frames · ~\(Int(status.estimatedMegabytes)) MB")
                    .monospacedDigit()
            }
            if status.videoDropped > 0 {
                Text("· \(status.videoDropped) video dropped")
                    .foregroundStyle(Theme.fairText.color)
            }
            if let error = status.lastError {
                Text("· \(error)")
                    .foregroundStyle(Theme.hardText.color)
                    .lineLimit(1)
            }
        }
        .hudFont(.caption, weight: .semibold)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .hudPlate(Capsule())
        .accessibilityLabel("Recording, \(status.clock)")
    }
}
