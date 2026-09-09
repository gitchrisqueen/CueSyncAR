//
//  MoreSheet.swift
//  CueSync AR
//
//  Everything that is not "where is the table" or "how am I practising".
//
//  Two things live here rather than in Settings, and both for the same
//  reason: they are used at the table, under time pressure, by someone who
//  cannot be scrolling a form. The debug mirror is the only way to see an
//  iPad that is parked at the far rail, and the recorder is how a session
//  that just went wrong gets captured before it stops being reproducible.
//  Both are the same single switch as their Settings rows — one preference,
//  two places to reach it — and both keep their /cmd route on the mirror.
//

import CueSyncUI
import SwiftUI

struct MoreSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Hands presentation back to RootView: two sheets cannot be up at
    /// once, so this one closes and RootView opens Settings.
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                atTheTableSection
                settingsSection
                buildSection
            }
            .navigationTitle("More")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("more-done-button")
                }
            }
        }
    }

    private var atTheTableSection: some View {
        Section {
            // The HUD's own record button, verbatim — same blockers, same
            // size-cost confirmation — with the label it never had room
            // for in a row of nine icons.
            LabeledContent {
                RecordButton()
            } label: {
                Text(model.isRecording ? "Stop recording" : "Record session")
            }
            .accessibilityIdentifier("more-record")
            Toggle("Debug mirror", isOn: Binding(
                get: { model.settings.debugMirrorEnabled },
                set: { on in model.updateSettings { $0.debugMirrorEnabled = on } }))
                .accessibilityIdentifier("more-debug-mirror")
            if let url = model.debugMirrorURL {
                LabeledContent("Address", value: url)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("At the table")
        } footer: {
            Text("""
                The mirror serves the live screen and tracking state to any \
                browser on this Wi-Fi. The recorder writes a replayable \
                session bundle — pull it with Scripts/pull-session.sh.
                """)
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                dismiss()
                onOpenSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("more-settings")
        } footer: {
            Text("""
                Table size, guides, tracking and practice mode — plus the \
                Developer section, which is where the detector picker, the \
                front-camera preview, the latency readout and the box-rotation \
                trim moved to.
                """)
        }
    }

    private var buildSection: some View {
        Section {
            Text(AppBuild.identity.compactLabel)
                .font(.footnote.weight(.semibold).monospaced())
                .foregroundStyle(AppBuild.identity.isDirty ? .orange : .secondary)
                .textSelection(.enabled)
        } footer: {
            Text("The build this app was made from. The same string is on the HUD badge and in the mirror's header.")
        }
    }
}
