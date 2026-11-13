//
//  SettingsView.swift
//  CueSync AR
//
//  M4-04: the Settings sheet — every knob the owner can turn at the table
//  without a rebuild. Presented as a sheet from the HUD gear button, per
//  05-UX-DESIGN ("No nav stacks in the live view. Settings is a sheet.").
//
//  This is deliberately a thin shell: ranges, defaults, validation and
//  persistence all live in CoachKit's `SettingsModel` (tested on Linux).
//  Every control writes through `SessionModel.updateSettings`, so a change
//  is stored and applied to the running session in one step.
//

import CoachKit
import CueSyncCore
import CueSyncUI
import Foundation
import SwiftUI
import TableSpace

struct SettingsView: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Snapshot of the probe line; refreshed when the sheet opens and
    /// after a reset (the probe is not an observable model).
    @State private var computeSummary = DetectorCompute.current?.summary ?? "Detector: not loaded"
    /// Whether the probe currently pins the CPU — gates the retry button.
    /// Snapshotted like `computeSummary` for the same reason: the probe is
    /// a static behind a Mutex, invisible to Observation.
    @State private var computePinnedToCPU = DetectorCompute.current?.record.pinnedToCPU == true
    /// Manual trim ON TOP of the orientation-derived rotation of the 2D
    /// detection-preview boxes. Same key RootView reads, so the nudge means
    /// the same thing wherever it is pressed.
    @AppStorage("previewBoxRotationTrim") private var rotationTrimRaw = NormalizedRotation.none.rawValue
    /// Whether the record button is pinned in the HUD (see HUDPins).
    @AppStorage(HUDPins.recordButtonKey) private var showRecordButton = HUDPins.recordButtonDefault

    @State private var developerMode = DeveloperMode.shared

    /// Snapshotted rather than computed: reading the store migrates on
    /// first call, and a Form body re-evaluates constantly.
    @State private var savedTables: [SavedTable] = []
    @State private var activeTableID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                tableSection
                savedTablesSection
                // Detector choice, the API-key note and the Neural Engine
                // probe are instruments, not settings: a player never sees
                // a build-config file name or a vendor key.
                if developerMode.isUnlocked {
                    detectionSection
                    computeSection
                }
                guidesSection
                practiceSection
                FeedbackSettingsSection()
                voiceSection
                aboutSection
                if developerMode.isUnlocked { developerSection }
            }
            .task {
                refreshComputeSnapshot()
                reloadSavedTables()
            }
            .navigationTitle(SheetCopy.Settings.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SheetCopy.Settings.done) { dismiss() }
                        .accessibilityIdentifier("settings-done-button")
                }
            }
        }
    }

    // MARK: Sections

    private var tableSection: some View {
        Section {
            Picker(SheetCopy.Settings.tableSize, selection: binding(\.tableSize)) {
                ForEach(TableSizeSetting.selectable, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .accessibilityIdentifier("settings-table-size")
        } header: {
            SheetHeader(SheetCopy.Settings.tableHeader)
        } footer: {
            SheetFootnote(SheetCopy.Settings.tableFooter)
        }
    }

    /// The tables the app remembers, so a second venue is visible rather
    /// than a thing that happened to the first one.
    ///
    /// Read once into state: `CalibrationStore.tables()` migrates on its
    /// first call, and a computed property in a Form body would run it on
    /// every layout pass.
    @ViewBuilder
    private var savedTablesSection: some View {
        if !savedTables.isEmpty {
            Section {
                ForEach(savedTables) { table in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(table.name)
                            Text(Self.describe(table))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if table.id == activeTableID {
                            Text(SheetCopy.Settings.savedInUse)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("saved-table-row")
                }
                .onDelete { offsets in
                    for index in offsets { CalibrationStore.remove(id: savedTables[index].id) }
                    reloadSavedTables()
                }
            } header: {
                SheetHeader(SheetCopy.Settings.savedHeader)
            } footer: {
                SheetFootnote(savedTables.count >= SavedTableIndex.capacity
                     ? SheetCopy.Settings.savedFooterFull
                     : SheetCopy.Settings.savedFooter)
            }
        }
    }

    private static func describe(_ table: SavedTable) -> String {
        let field = table.size.playField
        return String(format: "%.2f × %.2f m · last used %@",
                      field.width, field.height,
                      table.lastUsed.formatted(date: .abbreviated, time: .omitted))
    }

    private func reloadSavedTables() {
        savedTables = CalibrationStore.tables().byMostRecentlyUsed
        activeTableID = CalibrationStore.activeTableID
    }

    private var detectionSection: some View {
        Section {
            Picker("Detector", selection: binding(\.detectionProvider)) {
                ForEach(DetectionProviderSetting.allCases, id: \.self) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .accessibilityIdentifier("settings-detection-provider")
            LabeledContent("Running on", value: model.effectiveDetectionProviderTitle)
        } header: {
            SheetHeader("Detection")
        } footer: {
            SheetFootnote(model.canUseHostedDetection
                 ? "The hosted detector also needs a model picked under Developer; without one the bundled model keeps running."
                 : "The hosted detector needs a Roboflow API key in Secrets.xcconfig. Without one the bundled model is used.")
        }
    }

    /// Re-read the probe into view state. The probe lives behind a static
    /// Mutex (SessionModel+Providers), so nothing invalidates a body when
    /// it changes — the sheet pulls it on open and after a reset.
    private func refreshComputeSnapshot() {
        computeSummary = DetectorCompute.current?.summary ?? "Detector: not loaded"
        computePinnedToCPU = DetectorCompute.current?.record.pinnedToCPU == true
    }

    /// T1.3: the Neural Engine probe, readable and resettable at the table.
    private var computeSection: some View {
        Section {
            Text(computeSummary)
                .font(.footnote.monospaced())
                .accessibilityIdentifier("settings-detector-compute-summary")
            Toggle("Pin detector to CPU", isOn: binding(\.detectorPinnedToCPU))
                .accessibilityIdentifier("settings-detector-pin-cpu")
            Button("Retry Neural Engine on next launch") {
                model.resetDetectorComputeProbe()
                refreshComputeSnapshot()
            }
            // `computeSummary` is @State, refreshed by this sheet's own
            // task; `DetectorCompute.current` is a static outside
            // Observation, so reading it in a body meant this button's
            // enabled state froze at whatever it was when the sheet last
            // rendered for another reason.
            .disabled(!computePinnedToCPU)
            .accessibilityIdentifier("settings-detector-compute-reset")
        } header: {
            SheetHeader("Detector compute")
        } footer: {
            SheetFootnote("""
                The bundled model asks for the Neural Engine unless the last \
                run crashed inside it (then it stays on the CPU until you \
                retry) or you pin the CPU here. Both take effect on the next \
                launch. The debug mirror shows the same under detectorCompute.
                """)
        }
    }

    private var guidesSection: some View {
        Section {
            Toggle(SheetCopy.Settings.deviceParked, isOn: binding(\.deviceParked))
                .accessibilityIdentifier("settings-device-parked")
            slider(binding(\.guideSpeed),
                   range: SettingsModel.guideSpeedRange,
                   step: 0.1,
                   label: SheetCopy.Settings.shotStrength,
                   value: HUDCopy.shotStrengthWord(speed: model.settings.guideSpeed,
                                                   range: SettingsModel.guideSpeedRange))
                .accessibilityIdentifier("settings-guide-speed")
        } header: {
            SheetHeader(SheetCopy.Settings.guidesHeader)
        } footer: {
            SheetFootnote(SheetCopy.Settings.guidesFooter)
        }
    }

    private var practiceSection: some View {
        Section {
            Picker(SheetCopy.Settings.practiceMode, selection: binding(\.practiceMode)) {
                ForEach(PracticeMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("settings-practice-mode")
            // The HUD chip only appears while a rack is being tracked, so
            // this is the group's permanent home — and it makes true what
            // `cycleBallGroup`'s comment has always claimed, that the eight
            // is reachable "from Settings" and never by a stray tap.
            Picker(SheetCopy.Settings.ballGroup, selection: binding(\.ballGroup)) {
                ForEach(BallGroup.allCases, id: \.self) { group in
                    Text(group.label).tag(group)
                }
            }
            .accessibilityIdentifier("settings-ball-group")
            if let hint = model.practiceMode.pendingHint(
                hasCalledPocket: model.calledPocket != nil) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SheetHeader(SheetCopy.Settings.practiceHeader)
        }
    }

    /// Spoken guidance (SessionModel+Speech / CoachKit.SpokenGuidance).
    ///
    /// Bound through `setSpeechVerbosity` rather than the generic
    /// `binding(_:)` so that switching it on says so out loud: turning a
    /// voice on and hearing nothing until the next shot is
    /// indistinguishable from a broken build.
    private var voiceSection: some View {
        Section {
            Picker(SheetCopy.Settings.spokenGuidance, selection: Binding(
                get: { model.settings.speechVerbosity },
                set: { model.setSpeechVerbosity($0) })) {
                    ForEach(SpeechVerbosity.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .accessibilityIdentifier("settings-speech-verbosity")
            if model.settings.speechVerbosity.isOn {
                Button(SheetCopy.Settings.sayNow) {
                    model.narrator.say(SheetCopy.Settings.voiceCheck)
                }
                .accessibilityIdentifier("settings-speech-test")
            }
        } header: {
            SheetHeader(SheetCopy.Settings.voiceHeader)
        } footer: {
            SheetFootnote("""
                \(model.settings.speechVerbosity.detail)

                \(SheetCopy.Settings.voiceFooterTail)
                """)
        }
    }

    /// Everything that serves development rather than play, in one place
    /// that admits what it is.
    ///
    /// Nothing here is new and nothing was deleted: these are the controls
    /// that used to sit in the HUD bar as unlabelled icons — the antenna,
    /// the camera flip, the model picker, the millisecond readout and the
    /// rotate button — next to the mirror switch that was already here.
    /// Every one of them still has its `/cmd` route on the debug mirror.
    /// Always visible, and the way in. The version is legitimately useful
    /// to a player reporting a problem; the seven-tap gesture on it is the
    /// idiom iOS itself taught everyone.
    private var aboutSection: some View {
        Section {
            LabeledContent(SheetCopy.Settings.version, value: AppBuild.identity.versionLabel)
                .contentShape(Rectangle())
                .onTapGesture { developerMode.noteVersionTap() }
                .accessibilityIdentifier("settings-version")
            if let hint = developerMode.hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            if developerMode.isUnlocked {
                Button("Hide developer options") { developerMode.lock() }
                    .accessibilityIdentifier("settings-lock-developer")
            }
        } header: {
            SheetHeader(SheetCopy.Settings.aboutHeader)
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("Debug mirror", isOn: binding(\.debugMirrorEnabled))
                .accessibilityIdentifier("settings-debug-mirror")
            if let url = model.debugMirrorURL {
                LabeledContent("Address", value: url)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            slider(binding(\.visibleMissGrace),
                   range: SettingsModel.visibleMissGraceRange,
                   step: 0.05,
                   label: "Visible-miss grace",
                   value: String(format: "%.2f s", model.settings.visibleMissGrace))
                .accessibilityIdentifier("settings-visible-miss-grace")
            Toggle("Show record button in HUD", isOn: $showRecordButton)
                .accessibilityIdentifier("settings-pin-record-button")
            Toggle("Front camera preview", isOn: Binding(
                get: { model.usingFrontCamera },
                set: { model.setUsingFrontCamera($0) }))
                .accessibilityIdentifier("settings-front-camera")
            modelPicker
            if model.selectedModel != nil {
                LabeledContent("Detector latency",
                               value: "\(model.previewStats.latencyMilliseconds) ms")
                    .font(.footnote.monospacedDigit())
                Button("Nudge detection box rotation") {
                    rotationTrimRaw = (NormalizedRotation(rawValue: rotationTrimRaw) ?? .none)
                        .next.rawValue
                }
                .accessibilityIdentifier("settings-box-rotation")
            }
            if let error = model.previewStats.lastError {
                LabeledContent("Last detector error", value: error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings-detector-error")
            }
            ForEach(AppBuild.identity.fields) { field in
                LabeledContent(field.label, value: field.value)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            SheetHeader("Developer")
        } footer: {
            SheetFootnote("""
                The mirror serves the live screen and tracking state to any \
                browser on this Wi-Fi; it is also on the More sheet, one tap \
                from the HUD, because it is how a parked iPad is watched.

                The front camera is a detection preview only — it suspends \
                the AR session, so calibration and tracking stop while it is \
                on. The hosted model picker is A/B evaluation tooling and \
                needs a Roboflow key; the latency, box-rotation trim and \
                detector error all belong to that preview path.
                """)
        }
    }

    /// Hosted-model A/B picker (M2-01 evaluation tooling). Moved here from
    /// the HUD, where it sat beside controls a player needs.
    private var modelPicker: some View {
        Picker("Detection model", selection: Binding(
            get: { model.selectedModel?.id },
            set: { id in
                model.selectModel(DetectionModelCatalog.candidates.first { $0.id == id })
            })) {
            Text("Preview off").tag(String?.none)
            ForEach(DetectionModelCatalog.candidates) { candidate in
                Text(candidate.label).tag(String?.some(candidate.id))
            }
        }
        .accessibilityIdentifier("model-picker")
        .disabled(!model.hasRoboflowKey && model.selectedModel == nil)
    }

    // MARK: Building blocks

    /// A two-way binding onto one setting, routed through
    /// `updateSettings` so the write persists and is applied.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<SettingsModel, Value>
    ) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { newValue in
                    model.updateSettings { $0[keyPath: keyPath] = newValue }
                })
    }

    /// Labeled slider with a monospaced live readout, so a value dragged
    /// at the table can be read back and repeated.
    private func slider(_ value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        label: String,
                        value readout: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(readout)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue(readout)
        }
    }
}
