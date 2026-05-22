//
//  QuickPanelModel.swift
//  EqualEase
//

import AppKit
import Combine
import Foundation

@MainActor
final class QuickPanelPresentationState: ObservableObject {
    @Published var showsPointer = true
}

@MainActor
struct QuickPanelActions {
    var applyEffectivePreset: () -> Void
    var selectPreset: (String) -> Void
    var setPresetLock: (Bool) -> Void
    var acceptAppPresetSuggestion: () -> Void
    var dismissAppPresetSuggestion: () -> Void
    var resetAppPresetSuggestionDismissals: () -> Void
    var openSettingsWindow: () -> Void
    var openPresetsSettings: () -> Void
    var showAboutPanel: () -> Void
    var quit: () -> Void

    static var noOp: QuickPanelActions {
        QuickPanelActions(
            applyEffectivePreset: {},
            selectPreset: { _ in },
            setPresetLock: { _ in },
            acceptAppPresetSuggestion: {},
            dismissAppPresetSuggestion: {},
            resetAppPresetSuggestionDismissals: {},
            openSettingsWindow: {},
            openPresetsSettings: {},
            showAboutPanel: {},
            quit: {}
        )
    }
}

@MainActor
final class QuickPanelModel<Router: AudioRoutingBackend>: ObservableObject {
    static var panelWidth: CGFloat { 360 }
    static var maximumPanelHeight: CGFloat { 526 }

    let router: Router
    let inputDeviceController: InputDeviceController
    let presetStore: PresetStore
    let foregroundAppObserver: ForegroundAppObserver
    let activeContextResolver: ActiveContextPresetResolver
    let presentationState: QuickPanelPresentationState

    private let actions: QuickPanelActions
    private var cancellables: Set<AnyCancellable> = []

    init(
        router: Router,
        inputDeviceController: InputDeviceController,
        presetStore: PresetStore,
        foregroundAppObserver: ForegroundAppObserver,
        activeContextResolver: ActiveContextPresetResolver,
        presentationState: QuickPanelPresentationState,
        actions: QuickPanelActions
    ) {
        self.router = router
        self.inputDeviceController = inputDeviceController
        self.presetStore = presetStore
        self.foregroundAppObserver = foregroundAppObserver
        self.activeContextResolver = activeContextResolver
        self.presentationState = presentationState
        self.actions = actions

        relayChanges(from: router)
        relayChanges(from: inputDeviceController)
        relayChanges(from: presetStore)
        relayChanges(from: foregroundAppObserver)
        relayChanges(from: activeContextResolver)
        relayChanges(from: presentationState)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func onAppear() {
        actions.resetAppPresetSuggestionDismissals()
        foregroundAppObserver.refresh()
        inputDeviceController.refreshInputDevice()
        actions.applyEffectivePreset()
    }

    func selectPreset(id presetID: String) {
        actions.selectPreset(presetID)
    }

    func setPresetLock(_ isLocked: Bool) {
        actions.setPresetLock(isLocked)
        objectWillChange.send()
    }

    func acceptAppPresetSuggestion() {
        actions.acceptAppPresetSuggestion()
    }

    func dismissAppPresetSuggestion() {
        actions.dismissAppPresetSuggestion()
    }

    func hideInputVolumeControls() {
        EqualEaseSettings.showsQuickPanelInputVolume = false
        objectWillChange.send()
    }

    func hideRoutingControls() {
        EqualEaseSettings.showsQuickPanelRouting = false
        objectWillChange.send()
    }

    func openSettingsWindow() {
        actions.openSettingsWindow()
    }

    func openPresetsSettings() {
        actions.openPresetsSettings()
    }

    func showAboutPanel() {
        actions.showAboutPanel()
    }

    func quit() {
        actions.quit()
    }

    func setActive(_ isActive: Bool) {
        if isActive {
            EqualEaseSettings.hasCompletedRoutingOnboarding = true
            router.start()
        } else {
            router.stop()
        }
    }

    func startRoutingFromOnboarding(restoreAtLaunch: Bool) {
        EqualEaseSettings.hasCompletedRoutingOnboarding = true
        EqualEaseSettings.startAudioRoutingAtLaunch = restoreAtLaunch
        router.start()
        objectWillChange.send()
    }

    func dismissRoutingOnboarding() {
        EqualEaseSettings.hasCompletedRoutingOnboarding = true
        EqualEaseSettings.startAudioRoutingAtLaunch = false
        objectWillChange.send()
    }

    var selectedPresetName: String {
        activeContextResolver.context?.preset.name
            ?? presetStore.presets.first { $0.id == presetStore.selectedPresetID }?.name
            ?? "Preset"
    }

    var isPresetLocked: Bool {
        EqualEaseSettings.isPresetLocked
    }

    var presetLockHelpText: String {
        if let context = activeContextResolver.context, context.source == .lockedPreset {
            return "App-specific rules are paused; \(context.preset.name) stays active while you switch apps."
        }
        return "Ignores app-specific preset rules and keeps the current preset while you switch apps."
    }

    var currentInputDeviceName: String {
        inputDeviceController.inputDeviceName
    }

    var showsInputSection: Bool {
        EqualEaseSettings.showsQuickPanelInputVolume
    }

    var showsInputVolumeControls: Bool {
        showsInputSection
    }

    var showsRoutingSection: Bool {
        EqualEaseSettings.showsQuickPanelRouting
    }

    var shouldShowRoutingOnboarding: Bool {
        EqualEaseSettings.shouldPresentRoutingOnboarding && !router.isRunning && router.state != .starting
    }

    var preferredPanelHeight: CGFloat {
        if shouldShowRoutingOnboarding {
            return 436
        }

        let baseHeightWithoutInputOrRouting: CGFloat = 376
        let inputSectionHeight: CGFloat = showsInputSection ? 92 : 0
        let routingSectionHeight: CGFloat = showsRoutingSection ? 108 : 0
        let promptHeight: CGFloat = appLearningPrompt == nil ? 0 : 72
        return min(
            Self.maximumPanelHeight,
            baseHeightWithoutInputOrRouting + inputSectionHeight + routingSectionHeight + promptHeight
        )
    }

    var panelBodyHeight: CGFloat {
        preferredPanelHeight - 11
    }

    var effectivePresetSummary: String {
        activeContextResolver.context?.sourceSummary ?? "No preset"
    }

    var appLearningPrompt: AppPresetSuggestion? {
        activeContextResolver.context?.appLearningPrompt
    }

    var isActive: Bool {
        router.isRunning || router.state == .starting
    }

    var statusTitle: String {
        if router.isRoutingTransitioning && router.statusText.localizedCaseInsensitiveContains("stopping") {
            return "Stopping…"
        }
        if router.isRoutingTransitioning && router.isRunning {
            return "Switching…"
        }

        return switch router.state {
        case .stopped: "Off"
        case .starting: "Starting…"
        case .running: "Active"
        case .failed: "Failed"
        }
    }

    private func relayChanges<Object: ObservableObject>(from object: Object) {
        object.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
