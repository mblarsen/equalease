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
    var activeWebsite: BrowserPageIdentity? = nil
    var presets: [EQPreset]
    var devicePresetIDs: [String: String]
    var appPresetIDs: [String: String]
    var websitePresetIDs: [String: String] = [:]
    var lockedPresetID: String? = nil
    var foregroundActivationGeneration: Int = 0
    var websiteGeneration: Int = 0
}

struct ActivePresetContext: Equatable {
    var preset: EQPreset
    var source: PresetResolutionSource
    var selectedDefaultPresetID: String
    var appLearningPrompt: AppPresetSuggestion?

    var sourceSummary: String {
        switch source {
        case .lockedPreset:
            String(
                localized: "\(preset.name) · paused",
                comment: "Compact preset status. Interpolation is a preset name; 'paused' means app/website preset switching is paused."
            )
        case let .activeWebsite(_, displayName):
            String(
                localized: "\(preset.name) for \(displayName)",
                comment: "Compact preset status. First interpolation is a preset name; second is an app name or website display name/host."
            )
        case let .activeApp(_, displayName):
            String(
                localized: "\(preset.name) for \(displayName)",
                comment: "Compact preset status. First interpolation is a preset name; second is an app name or website display name/host."
            )
        case .selectedPreset:
            preset.name
        }
    }

    var sourceExplanation: String {
        switch source {
        case .lockedPreset:
            String(
                localized: "Preset rules are paused. EqualEase stays on \(preset.name) until preset switching resumes.",
                comment: "Preset resolution explanation. Interpolation is a preset name."
            )
        case let .activeWebsite(siteKey, displayName):
            String(
                localized: "Active website \(displayName) (\(siteKey)) remembers \(preset.name).",
                comment: "Preset resolution explanation. Interpolations are website display name, website host/key, and preset name."
            )
        case let .activeApp(bundleIdentifier, displayName):
            String(
                localized: "Active app \(displayName) (\(bundleIdentifier)) remembers \(preset.name).",
                comment: "Preset resolution explanation. Interpolations are app name, bundle identifier, and preset name."
            )
        case .selectedPreset:
            String(
                localized: "Using the selected default preset \(preset.name).",
                comment: "Preset resolution explanation. Interpolation is a preset name."
            )
        }
    }
}

@MainActor
final class ActiveContextPresetResolver: ObservableObject {
    @Published private(set) var context: ActivePresetContext?

    private var dismissedPromptTargetKeys: Set<String> = []
    private var appLearningPrompt: AppPresetSuggestion?
    private var manualPresetOverride: AppPresetSuggestion?
    private var manualPresetOverrideContextKey: String?

    @discardableResult
    func resolve(input: ActiveContextPresetInput) -> ActivePresetContext? {
        clearPromptIfActiveTargetChanged(input: input)

        let resolvedPreset: EQPreset
        let resolvedSource: PresetResolutionSource

        if input.lockedPresetID != nil {
            appLearningPrompt = nil
            clearManualOverride()
        }

        if input.lockedPresetID == nil, let override = validManualOverride(input: input) {
            resolvedPreset = override.preset
            resolvedSource = .selectedPreset
        } else {
            guard let resolution = PresetResolutionService.resolve(
                selectedPresetID: input.selectedPresetID,
                outputDeviceUID: input.outputDeviceUID,
                activeApp: input.foregroundApp,
                activeWebsite: input.activeWebsite,
                presets: input.presets,
                devicePresetIDs: input.devicePresetIDs,
                appPresetIDs: input.appPresetIDs,
                websitePresetIDs: input.websitePresetIDs,
                lockedPresetID: input.lockedPresetID
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
        appLearningPrompt = input.lockedPresetID == nil ? promptCandidate(forManualPreset: preset, input: input) : nil
        manualPresetOverride = input.lockedPresetID == nil ? manualOverride(forManualPreset: preset, input: input) : nil
        manualPresetOverrideContextKey = manualPresetOverride == nil ? nil : activeTargetContextKey(input: input)
        return resolve(input: input)
    }

    func acceptPrompt() -> AppPresetSuggestion? {
        let suggestion = appLearningPrompt
        appLearningPrompt = nil
        updateContextPrompt()
        return suggestion
    }

    func dismissPrompt() {
        if let targetKey = appLearningPrompt?.target.storageKey {
            dismissedPromptTargetKeys.insert(targetKey)
        }
        appLearningPrompt = nil
        updateContextPrompt()
    }

    func resetPromptSession() {
        dismissedPromptTargetKeys.removeAll()
    }

    private func manualOverride(
        forManualPreset preset: EQPreset,
        input: ActiveContextPresetInput
    ) -> AppPresetSuggestion? {
        guard let target = learningTarget(for: input) else { return nil }
        guard targetPresetID(for: target, input: input) != preset.id else { return nil }
        return AppPresetSuggestion(target: target, preset: preset)
    }

    private func validManualOverride(input: ActiveContextPresetInput) -> AppPresetSuggestion? {
        guard let manualPresetOverride else { return nil }
        guard manualPresetOverride.target == learningTarget(for: input) else {
            clearManualOverride()
            return nil
        }
        guard manualPresetOverrideContextKey == activeTargetContextKey(input: input) else {
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
        guard let target = learningTarget(for: input) else { return nil }
        guard targetPresetID(for: target, input: input) != preset.id else { return nil }
        guard !dismissedPromptTargetKeys.contains(target.storageKey) else { return nil }
        return AppPresetSuggestion(target: target, preset: preset)
    }

    private func learningTarget(for input: ActiveContextPresetInput) -> PresetLearningTarget? {
        if let activeWebsite = input.activeWebsite {
            return .website(activeWebsite)
        }
        if let foregroundApp = input.foregroundApp {
            return .app(foregroundApp)
        }
        return nil
    }

    private func targetPresetID(for target: PresetLearningTarget, input: ActiveContextPresetInput) -> String? {
        switch target {
        case let .app(app):
            input.appPresetIDs[app.bundleIdentifier]
        case let .website(page):
            input.websitePresetIDs[page.siteKey]
        }
    }

    private func activeTargetContextKey(input: ActiveContextPresetInput) -> String? {
        guard let target = learningTarget(for: input) else { return nil }
        switch target {
        case let .app(app):
            return "app:\(app.bundleIdentifier):\(input.foregroundActivationGeneration)"
        case let .website(page):
            return "website:\(page.siteKey):\(input.websiteGeneration)"
        }
    }

    private func clearPromptIfActiveTargetChanged(input: ActiveContextPresetInput) {
        let activeTarget = learningTarget(for: input)

        if let manualPresetOverride,
           manualPresetOverride.target != activeTarget {
            clearManualOverride()
        }

        guard let appLearningPrompt else { return }
        guard appLearningPrompt.target == activeTarget else {
            self.appLearningPrompt = nil
            updateContextPrompt()
            return
        }
    }

    private func clearManualOverride() {
        manualPresetOverride = nil
        manualPresetOverrideContextKey = nil
    }

    private func updateContextPrompt() {
        guard var context else { return }
        context.appLearningPrompt = appLearningPrompt
        self.context = context
    }
}
