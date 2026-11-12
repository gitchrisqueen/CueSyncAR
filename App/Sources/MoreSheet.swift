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
    /// The mirror switch, its address and the build string are developer
    /// tooling: a player does not see them. The mirror itself keeps
    /// running in debug builds either way; only the controls are gated.
    @State private var developerMode = DeveloperMode.shared
    /// Hands presentation back to RootView: two sheets cannot be up at
    /// once, so this one closes and RootView opens Settings.
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                atTheTableSection
                ScoreboardSection()
                settingsSection
                if developerMode.isUnlocked { buildSection }
            }
            .navigationTitle(SheetCopy.More.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SheetCopy.More.done) { dismiss() }
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
                Text(model.isRecording ? SheetCopy.More.stopRecording : SheetCopy.More.record)
            }
            .accessibilityIdentifier("more-record")
            if developerMode.isUnlocked {
                Toggle("Debug mirror", isOn: Binding(
                    get: { model.settings.debugMirrorEnabled },
                    set: { on in model.updateSettings { $0.debugMirrorEnabled = on } }))
                    .accessibilityIdentifier("more-debug-mirror")
                if let url = model.debugMirrorURL {
                    LabeledContent("Address", value: url)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(SheetCopy.More.tableHeader)
        } footer: {
            Text(developerMode.isUnlocked
                 ? """
                   The mirror serves the live screen and tracking state to any \
                   browser on this Wi-Fi. The recorder writes a replayable \
                   session bundle — pull it from the Files app, or over the debug mirror.
                   """
                 : SheetCopy.More.recordFooter)
        }
    }

    private var settingsSection: some View {
        Section {
            Button {
                dismiss()
                onOpenSettings()
            } label: {
                Label(SheetCopy.More.settings, systemImage: "gearshape")
            }
            .accessibilityIdentifier("more-settings")
        } footer: {
            Text(SheetCopy.More.settingsFooter)
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
