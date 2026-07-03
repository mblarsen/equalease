//
//  PresetSettingsView.swift
//  EqualEase
//

import SwiftUI

struct PresetSettingsView: View {
    @ObservedObject var router: CoreAudioRouter
    @ObservedObject var presetStore: PresetStore
    var applyPreset: (EQPreset) -> Void

    @State private var selectedBandIndex: Int?
    @State private var isShowingSaveAsSheet = false
    @State private var isShowingRenameSheet = false
    @State private var isShowingDeleteConfirmation = false
    @State private var saveAsDraft = ""
    @State private var renameDraft = ""

    private let sidePanelGraphAlignmentOffset: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                GroupBox {
                    EQGraphEditorView(router: router, selectedBandIndex: $selectedBandIndex)
                        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 290)
                } label: {
                    Label("10-band EQ", systemImage: "waveform.path.ecg")
                }
                .frame(maxWidth: .infinity)

                sidePanel
                    .frame(width: 210)
                    .padding(.top, sidePanelGraphAlignmentOffset)
            }

            actionRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isShowingSaveAsSheet) {
            PresetNameSheet(
                title: String(localized: "Save Preset As", comment: "Title for the sheet that saves the current preset as a new custom preset."),
                message: saveAsSheetMessage,
                actionTitle: String(localized: "Save", comment: "Button title for saving a preset name sheet."),
                name: $saveAsDraft,
                onCancel: { isShowingSaveAsSheet = false },
                onSave: saveCurrentAsCustomPreset
            )
            .frame(width: 360)
        }
        .sheet(isPresented: $isShowingRenameSheet) {
            PresetNameSheet(
                title: String(localized: "Rename Preset", comment: "Title for the sheet that renames a custom preset."),
                message: renameSheetMessage,
                actionTitle: String(localized: "Save", comment: "Button title for saving a preset name sheet."),
                name: $renameDraft,
                onCancel: { isShowingRenameSheet = false },
                onSave: renameSelectedCustomPreset
            )
            .frame(width: 360)
        }
        .alert("Delete Preset?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedCustomPreset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(selectedPreset?.name ?? "this preset")\"? This cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Presets")
                    .font(.title2.bold())
                Text(editorDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Picker("Current preset", selection: selectedPresetBinding) {
                Section("Speech") {
                    presetMenuItems(for: presets(withIDs: ["built-in-voice-boost", "built-in-podcast"]))
                }

                Section("Music") {
                    presetMenuItems(for: presets(withIDs: ["built-in-bass-boost", "built-in-treble-boost", "built-in-warm", "built-in-loudness"]))
                }

                Section("Utility") {
                    presetMenuItems(for: presets(withIDs: ["built-in-flat", "built-in-de-mud", "built-in-night-mode", "built-in-small-speakers", "built-in-reduce-rumble", "built-in-muffled"]))
                }

                if !presetStore.customPresets.isEmpty {
                    Section("Custom") {
                        presetMenuItems(for: presetStore.customPresets)
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 180)
            .accessibilityLabel("Current preset")
            .help("Choose the preset to hear and edit in this workbench.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func presetMenuItems(for presets: [EQPreset]) -> some View {
        ForEach(presets) { preset in
            Text(preset.name).tag(preset.id)
        }
    }

    private func presets(withIDs ids: [String]) -> [EQPreset] {
        ids.compactMap { id in
            presetStore.builtInPresets.first { $0.id == id }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            preampGainCard

            if selectedBandIndex != nil {
                selectedBandCard
            }
        }
    }

    private var preampGainCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preamp / Gain")
                    .font(.headline)
                PreampGainSlider(value: Binding(
                    get: { router.outputGain },
                    set: { router.outputGain = min(max($0, 0), 2) }
                ))
                HStack {
                    Text("Saved with presets")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(router.outputGain * 100))%")
                        .monospacedDigit()
                        .accessibilityLabel("Preamp \(Int(router.outputGain * 100)) percent")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedBandCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Selected Band")
                    .font(.headline)
                LabeledContent("Band", value: selectedBandLabel)
                LabeledContent("Gain") {
                    Text("\(selectedBandGain, specifier: "%.1f") dB")
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if isSelectedPresetCustom {
                saveButton
            }

            saveAsButton

            if isSelectedPresetCustom {
                Button("Rename") {
                    renameDraft = selectedPreset?.name ?? ""
                    isShowingRenameSheet = true
                }

                Button("Delete", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
            }

            revertButton

            Spacer()
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        if hasUnsavedLiveChanges {
            saveActionButton
                .buttonStyle(.borderedProminent)
        } else {
            saveActionButton
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }

    private var saveActionButton: some View {
        Button("Save") {
            guard let preset = presetStore.updateCustomPreset(
                id: presetStore.selectedPresetID,
                bandGains: router.bandGains,
                outputGain: router.outputGain
            ) else { return }
            applyPreset(preset)
        }
        .help("Save the live EQ and gain into this custom preset.")
    }

    @ViewBuilder
    private var saveAsButton: some View {
        if shouldHighlightSaveAs {
            saveAsActionButton
                .buttonStyle(.borderedProminent)
        } else {
            saveAsActionButton
                .buttonStyle(.bordered)
                .disabled(selectedPreset == nil)
        }
    }

    private var saveAsActionButton: some View {
        Button("Save As…") {
            saveAsDraft = presetStore.suggestedCopyName(for: selectedPreset?.name ?? "Preset")
            isShowingSaveAsSheet = true
        }
        .help("Create a new custom preset from the current live EQ and gain settings.")
    }

    private var revertButton: some View {
        revertActionButton
            .buttonStyle(.bordered)
            .disabled(!hasUnsavedLiveChanges)
    }

    private var revertActionButton: some View {
        Button("Revert") {
            guard let preset = selectedPreset else { return }
            applyPreset(preset)
        }
        .help("Restore the live EQ and gain to the selected preset's saved values.")
    }

    private var selectedPresetBinding: Binding<String> {
        Binding(
            get: { presetStore.selectedPresetID },
            set: { presetID in
                guard let preset = presetStore.selectPreset(id: presetID) else { return }
                applyPreset(preset)
            }
        )
    }

    private var selectedBandLabel: String {
        guard let selectedBandIndex, equaleaseEQBandLabels.indices.contains(selectedBandIndex) else { return "—" }
        return "\(equaleaseEQBandLabels[selectedBandIndex]) Hz"
    }

    private var selectedBandGain: Double {
        guard let selectedBandIndex, router.bandGains.indices.contains(selectedBandIndex) else { return 0 }
        return router.bandGains[selectedBandIndex]
    }

    private var selectedPreset: EQPreset? {
        presetStore.preset(id: presetStore.selectedPresetID)
    }

    private var isSelectedPresetCustom: Bool {
        presetStore.isCustomPreset(id: presetStore.selectedPresetID)
    }

    private var shouldHighlightSaveAs: Bool {
        hasUnsavedLiveChanges && !isSelectedPresetCustom
    }

    private var editorDescription: String {
        guard let selectedPreset else { return String(localized: "Choose a preset to edit EQ values.", comment: "Description under Presets settings when no preset is selected.") }
        if selectedPreset.source == .builtIn {
            return String(localized: "Built-ins are read-only templates. EQ and gain changes are live until you save them as a new preset.", comment: "Description under Presets settings when a built-in preset is selected.")
        }
        return String(localized: "Changes are live for listening. Save the custom preset when you want to keep them.", comment: "Description under Presets settings when a custom preset is selected.")
    }

    private var saveAsSheetMessage: String {
        let presetName = selectedPreset?.name ?? String(localized: "this preset", comment: "Fallback preset name in the Save Preset As sheet.")
        let format = String(localized: "Choose a name for a custom copy of \"%@\".", comment: "Message in the Save Preset As sheet. Placeholder is the source preset name.")
        return String(format: format, presetName)
    }

    private var renameSheetMessage: String {
        let presetName = selectedPreset?.name ?? String(localized: "Preset", comment: "Fallback preset name in the Rename Preset sheet.")
        let format = String(localized: "Choose a new name for \"%@\".", comment: "Message in the Rename Preset sheet. Placeholder is the current custom preset name.")
        return String(format: format, presetName)
    }

    private var hasUnsavedLiveChanges: Bool {
        guard let selectedPreset else { return false }
        if abs(router.outputGain - selectedPreset.outputGain) > 0.0001 {
            return true
        }
        return zip(normalizedBandGains(router.bandGains), normalizedBandGains(selectedPreset.bandGains))
            .contains { abs($0 - $1) > 0.0001 }
    }

    private func normalizedBandGains(_ gains: [Double]) -> [Double] {
        let paddedGains = gains + Array(repeating: 0, count: max(0, equaleaseEQBandLabels.count - gains.count))
        return Array(paddedGains.prefix(equaleaseEQBandLabels.count))
    }

    private func saveCurrentAsCustomPreset() {
        let preset = presetStore.saveCurrentPreset(
            name: saveAsDraft,
            bandGains: router.bandGains,
            outputGain: router.outputGain
        )
        isShowingSaveAsSheet = false
        applyPreset(preset)
    }

    private func renameSelectedCustomPreset() {
        presetStore.renameCustomPreset(id: presetStore.selectedPresetID, name: renameDraft)
        isShowingRenameSheet = false
    }

    private func deleteSelectedCustomPreset() {
        if let fallbackPreset = presetStore.deleteSelectedCustomPreset() {
            applyPreset(fallbackPreset)
        }
    }
}

private struct PreampGainSlider: View {
    @Binding var value: Double
    @Environment(\.colorScheme) private var colorScheme

    private let range: ClosedRange<Double> = 0...2
    private let step = 0.05
    private let trackHeight: CGFloat = 5
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = CGFloat((clampedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbOffset = min(max(0, progress * width - thumbSize / 2), max(0, width - thumbSize))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(fillColor)
                    .frame(width: max(trackHeight, progress * width), height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.16), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 2, x: 0, y: 1)
                    .offset(x: thumbOffset)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        updateValue(forX: drag.location.x, width: width)
                    }
            )
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Preamp")
        .accessibilityValue("\(Int(clampedValue * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = stepped(clampedValue + step)
            case .decrement:
                value = stepped(clampedValue - step)
            @unknown default:
                break
            }
        }
    }

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var fillColor: Color {
        Color(red: 0.96, green: 0.36, blue: 0.06)
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.14)
    }

    private func updateValue(forX x: CGFloat, width: CGFloat) {
        let progress = min(max(Double(x / width), 0), 1)
        let rawValue = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        value = stepped(rawValue)
    }

    private func stepped(_ rawValue: Double) -> Double {
        let steppedValue = (rawValue / step).rounded() * step
        return min(max(steppedValue, range.lowerBound), range.upperBound)
    }
}

private struct PresetNameSheet: View {
    var title: String
    var message: String
    var actionTitle: String
    @Binding var name: String
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

#Preview {
    PresetSettingsView(
        router: CoreAudioRouter(),
        presetStore: PresetStore(),
        applyPreset: { _ in }
    )
    .padding()
}
