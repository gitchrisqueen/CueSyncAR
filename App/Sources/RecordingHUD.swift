//
//  RecordingHUD.swift
//  CueSync AR
//
//  The record button in the HUD bar and the live badge above the status
//  capsule. The button never does nothing: when a recording cannot start
//  the model says why on the HUD (and logs it); when it can, the size
//  cost is stated before anything is written.
//

import SwiftUI

struct RecordButton: View {
    @Environment(SessionModel.self) private var model
    @State private var confirming = false

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
            Label(model.isRecording ? "Stop recording" : "Record session",
                  systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(model.isRecording ? Color.red : Color.primary)
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

/// "● REC 0:42 · 210 frames · ~32 MB" while a recording runs — the
/// proof, at the table, that frames are actually landing on disk.
struct RecordingBadge: View {
    let status: RecordingStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
            Text("REC \(status.clock)")
                .monospacedDigit()
            Text("· \(status.frames) frames · ~\(Int(status.estimatedMegabytes)) MB")
                .monospacedDigit()
            if status.videoDropped > 0 {
                Text("· \(status.videoDropped) video dropped")
                    .foregroundStyle(.orange)
            }
            if let error = status.lastError {
                Text("· \(error)")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Recording, \(status.clock), \(status.frames) frames")
    }
}
