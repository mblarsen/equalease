//
//  ActiveContextPresetResolver.swift
//  EqualEase
//

import Combine
import Foundation

struct ActiveContextPresetInput {
    var selectedPresetID: String
    var outputDeviceUID: String?
    var foregroundApp: ForegroundAppIdentity?
    var presets: [EQPreset]
    var devicePresetIDs: [String: String]
    var appPresetIDs: [String: String]
    var foregroundActivationGeneration: Int = 0
}

struct ActivePresetContext: Equatable {
    var preset: EQPreset
    var source: PresetResolutionSource
    var selectedDefaultPresetID: String
    var appLearningPrompt: AppPresetSuggestion?

    var sourceSummary: String {
        switch source {
        case let .activeApp(_, displayName):
            "\(preset.name) for \(displayName)"
        case .selectedPreset:
            preset.name
        }
    }

    var sourceExplanation: String {
        switch source {
        case let .activeApp(bundleIdentifier, displayName):
            "Active app \(displayName) (\(bundleIdentifier)) remembers \(preset.name)."
        case .selectedPreset:
            "Using the selected default preset \(preset.name)."
        }
    }
}

@MainActor
final class ActiveContextPresetResolver: ObservableObject {
    @Published private(set) var context: ActivePresetContext?

    private var dismissedPromptBundleIdentifiers: Set<String> = []
    private var appLearningPrompt: AppPresetSuggestion?
    private var manualPresetOverride: AppPresetSuggestion?
    private var manualPresetOverrideActivationGeneration: Int?

    @discardableResult
    func resolve(input: ActiveContextPresetInput) -> ActivePresetContext? {
        clearPromptIfForegroundAppChanged(to: input.foregroundApp)

        let resolvedPreset: EQPreset
        let resolvedSource: PresetResolutionSource

        if let override = validManualOverride(input: input) {
            resolvedPreset = override.preset
            resolvedSource = .selectedPreset
        } else {
            guard let resolution = PresetResolutionService.resolve(
                selectedPresetID: input.selectedPresetID,
                outputDeviceUID: input.outputDeviceUID,
                activeApp: input.foregroundApp,
                presets: input.presets,
                devicePresetIDs: input.devicePresetIDs,
                appPresetIDs: input.appPresetIDs
            ) else {
                context = nil
                return nil
            }
            resolvedPreset = resolution.preset
            resolvedSource = resolution.source
        }

        let nextContext = ActivePresetContext(
            preset: resolvedPreset,
            source: resolvedSource,
            selectedDefaultPresetID: input.selectedPresetID,
            appLearningPrompt: appLearningPrompt
        )
        context = nextContext
        return nextContext
    }

    @discardableResult
    func recordManualPresetSelection(
        _ preset: EQPreset,
        input: ActiveContextPresetInput
    ) -> ActivePresetContext? {
        appLearningPrompt = promptCandidate(forManualPreset: preset, input: input)
        manualPresetOverride = manualOverride(forManualPreset: preset, input: input)
        manualPresetOverrideActivationGeneration = input.foregroundActivationGeneration
        return resolve(input: input)
    }

    func acceptPrompt() -> AppPresetSuggestion? {
        let suggestion = appLearningPrompt
        appLearningPrompt = nil
        updateContextPrompt()
        return suggestion
    }

    func dismissPrompt() {
        if let bundleIdentifier = appLearningPrompt?.app.bundleIdentifier {
            dismissedPromptBundleIdentifiers.insert(bundleIdentifier)
        }
        appLearningPrompt = nil
        updateContextPrompt()
    }

    func resetPromptSession() {
        dismissedPromptBundleIdentifiers.removeAll()
    }

    private func manualOverride(
        forManualPreset preset: EQPreset,
        input: ActiveContextPresetInput
    ) -> AppPresetSuggestion? {
        guard let foregroundApp = input.foregroundApp else { return nil }
        guard input.appPresetIDs[foregroundApp.bundleIdentifier] != preset.id else { return nil }
        return AppPresetSuggestion(app: foregroundApp, preset: preset)
    }

    private func validManualOverride(input: ActiveContextPresetInput) -> AppPresetSuggestion? {
        guard let manualPresetOverride else { return nil }
        guard manualPresetOverride.app.bundleIdentifier == input.foregroundApp?.bundleIdentifier else {
            clearManualOverride()
            return nil
        }
        guard manualPresetOverrideActivationGeneration == input.foregroundActivationGeneration else {
            clearManualOverride()
            return nil
        }
        guard manualPresetOverride.preset.id == input.selectedPresetID else {
            clearManualOverride()
            return nil
        }
        guard input.presets.contains(where: { $0.id == manualPresetOverride.preset.id }) else {
            clearManualOverride()
            return nil
        }
        return manualPresetOverride
    }

    private func promptCandidate(
        forManualPreset preset: EQPreset,
        input: ActiveContextPresetInput
    ) -> AppPresetSuggestion? {
        guard let foregroundApp = input.foregroundApp else { return nil }
        guard input.appPresetIDs[foregroundApp.bundleIdentifier] != preset.id else { return nil }
        guard !dismissedPromptBundleIdentifiers.contains(foregroundApp.bundleIdentifier) else { return nil }
        return AppPresetSuggestion(app: foregroundApp, preset: preset)
    }

    private func clearPromptIfForegroundAppChanged(to foregroundApp: ForegroundAppIdentity?) {
        if let manualPresetOverride,
           manualPresetOverride.app.bundleIdentifier != foregroundApp?.bundleIdentifier {
            clearManualOverride()
        }

        guard let appLearningPrompt else { return }
        guard appLearningPrompt.app.bundleIdentifier == foregroundApp?.bundleIdentifier else {
            self.appLearningPrompt = nil
            updateContextPrompt()
            return
        }
    }

    private func clearManualOverride() {
        manualPresetOverride = nil
        manualPresetOverrideActivationGeneration = nil
    }

    private func updateContextPrompt() {
        guard var context else { return }
        context.appLearningPrompt = appLearningPrompt
        self.context = context
    }
}
