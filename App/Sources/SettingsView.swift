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

    var body: some View {
        NavigationStack {
            Form {
                tableSection
                detectionSection
                computeSection
                guidesSection
                trackingSection
                practiceSection
                voiceSection
                developerSection
            }
            .task { refreshComputeSnapshot() }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings-done-button")
                }
            }
        }
    }

    // MARK: Sections

    private var tableSection: some View {
        Section {
            Picker("Table size", selection: binding(\.tableSize)) {
                ForEach(TableSizeSetting.selectable, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .accessibilityIdentifier("settings-table-size")
        } header: {
            Text("Table")
        } footer: {
            Text("""
                “Use measured” keeps whatever calibration measures (snapped \
                to your remembered table when there is one). Pick a size to \
                force it — takes effect the next time you calibrate.
                """)
        }
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
            Text("Detection")
        } footer: {
            Text(model.canUseHostedDetection
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
            Text("Detector compute")
        } footer: {
            Text("""
                The bundled model asks for the Neural Engine unless the last \
                run crashed inside it (then it stays on the CPU until you \
                retry) or you pin the CPU here. Both take effect on the next \
                launch. The debug mirror shows the same under detectorCompute.
                """)
        }
    }

    private var guidesSection: some View {
        Section {
            Toggle("Device is parked", isOn: binding(\.deviceParked))
                .accessibilityIdentifier("settings-device-parked")
            slider(binding(\.guideSpeed),
                   range: SettingsModel.guideSpeedRange,
                   step: 0.1,
                   label: "Guide speed",
                   value: String(format: "%.1f m/s", model.settings.guideSpeed))
                .accessibilityIdentifier("settings-guide-speed")
        } header: {
            Text("Guides")
        } footer: {
            Text("""
                Turn "device is parked" on whenever the phone or iPad is on \
                a tripod or propped on a rail. Held in the hand, the app can \
                aim from where the camera looks; parked, that becomes a \
                fixed line to wherever the mount happens to face, so it \
                aims from the cue only and tells you when it cannot see one.

                Guide speed is how hard the predicted shot is struck. Slower \
                lines die mid-table; faster ones spend the path budget on \
                ricochets.
                """)
        }
    }

    private var trackingSection: some View {
        Section {
            slider(binding(\.visibleMissGrace),
                   range: SettingsModel.visibleMissGraceRange,
                   step: 0.05,
                   label: "Visible-miss grace",
                   value: String(format: "%.2f s", model.settings.visibleMissGrace))
                .accessibilityIdentifier("settings-visible-miss-grace")
        } header: {
            Text("Tracking")
        } footer: {
            Text("""
                How long a ball that is in view but undetected keeps its \
                track — a ball hidden behind your bridge hand while you \
                aim, for instance. Longer survives that; shorter clears \
                stray balls sooner. A ball that vanishes while another \
                appears is treated as struck and always gives up its ring \
                quickly, whatever this is set to.
                """)
        }
    }

    private var practiceSection: some View {
        Section("Practice") {
            Picker("Mode", selection: binding(\.practiceMode)) {
                ForEach(PracticeMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("settings-practice-mode")
            // The HUD chip only appears while a rack is being tracked, so
            // this is the group's permanent home — and it makes true what
            // `cycleBallGroup`'s comment has always claimed, that the eight
            // is reachable "from Settings" and never by a stray tap.
            Picker("Ball group", selection: binding(\.ballGroup)) {
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
            Picker("Spoken guidance", selection: Binding(
                get: { model.settings.speechVerbosity },
                set: { model.setSpeechVerbosity($0) })) {
                    ForEach(SpeechVerbosity.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .accessibilityIdentifier("settings-speech-verbosity")
            if model.settings.speechVerbosity.isOn {
                Button("Say something now") {
                    model.narrator.say(
                        "Voice check. Best shot, 62 percent into the top-left corner.")
                }
                .accessibilityIdentifier("settings-speech-test")
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("""
                \(model.settings.speechVerbosity.detail)

                Off unless you turn it on. The voice is the one already on \
                this device — nothing is sent anywhere and it works with no \
                signal. Music in the room dips for a prompt rather than \
                stopping; like a navigation app, it speaks even when the \
                ring switch is set to silent.
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
    private var developerSection: some View {
        Section {
            Toggle("Debug mirror", isOn: binding(\.debugMirrorEnabled))
                .accessibilityIdentifier("settings-debug-mirror")
            if let url = model.debugMirrorURL {
                LabeledContent("Address", value: url)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
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
            Text("Developer")
        } footer: {
            Text("""
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
