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
    let appVolumeStore: AppVolumeStore
    let audioProcessDiscovery: AudioProcessDiscovery

    private let actions: QuickPanelActions
    private var cancellables: Set<AnyCancellable> = []

    init(
        router: Router,
        inputDeviceController: InputDeviceController,
        presetStore: PresetStore,
        foregroundAppObserver: ForegroundAppObserver,
        activeContextResolver: ActiveContextPresetResolver,
        presentationState: QuickPanelPresentationState,
        appVolumeStore: AppVolumeStore,
        audioProcessDiscovery: AudioProcessDiscovery,
        actions: QuickPanelActions
    ) {
        self.router = router
        self.inputDeviceController = inputDeviceController
        self.presetStore = presetStore
        self.foregroundAppObserver = foregroundAppObserver
        self.activeContextResolver = activeContextResolver
        self.presentationState = presentationState
        self.appVolumeStore = appVolumeStore
        self.audioProcessDiscovery = audioProcessDiscovery
        self.actions = actions

        relayChanges(from: router)
        relayChanges(from: inputDeviceController)
        relayChanges(from: presetStore)
        relayChanges(from: foregroundAppObserver)
        relayChanges(from: activeContextResolver)
        relayChanges(from: presentationState)
        relayChanges(from: appVolumeStore)
        relayChanges(from: audioProcessDiscovery)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
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

    func hideVolumeControls() {
        EqualEaseSettings.showsQuickPanelVolume = false
        objectWillChange.send()
    }

    func hidePreampControls() {
        EqualEaseSettings.showsQuickPanelPreamp = false
        objectWillChange.send()
    }

    func hideInputVolumeControls() {
        EqualEaseSettings.showsQuickPanelInputVolume = false
        objectWillChange.send()
    }

    func hideRoutingControls() {
        EqualEaseSettings.showsQuickPanelRouting = false
        objectWillChange.send()
    }

    func hideAppVolumeControls() {
        EqualEaseSettings.showsQuickPanelAppVolume = false
        objectWillChange.send()
    }

    func setAppVolume(_ volume: Double, for bundleID: String) {
        appVolumeStore.setVolume(volume, for: bundleID)
    }

    func setAppMode(_ mode: AppAudioMode, for bundleID: String) {
        appVolumeStore.setMode(mode, for: bundleID)
    }

    func toggleAppProcessBypass(for bundleID: String) {
        let underlying = appVolumeStore.nonMuteMode(for: bundleID)
        let next = underlying == .on ? AppAudioMode.off : .on
        if appVolumeStore.mode(for: bundleID) == .mute {
            appVolumeStore.setMuted(false, for: bundleID)
        }
        setAppMode(next, for: bundleID)
    }

    /// Toggle mute on/off without disturbing the underlying Process/Bypass state.
    func toggleAppMute(for bundleID: String) {
        appVolumeStore.setMuted(appVolumeStore.mode(for: bundleID) != .mute, for: bundleID)
    }

    func setAppBypassed(_ bypassed: Bool, for bundleID: String) {
        appVolumeStore.setBypassed(bypassed, for: bundleID)
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
            return "Preset rules are paused; \(context.preset.name) stays active while you switch apps or websites."
        }
        return "Ignores app and website preset rules and keeps the current preset while you switch focus."
    }

    var currentInputDeviceName: String {
        inputDeviceController.inputDeviceName
    }

    var showsVolumeControls: Bool {
        EqualEaseSettings.showsQuickPanelVolume
    }

    var showsPreampControls: Bool {
        EqualEaseSettings.showsQuickPanelPreamp
    }

    var showsLevelControls: Bool {
        showsVolumeControls || showsPreampControls
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

    var showsAppVolumeSection: Bool {
        EqualEaseSettings.showsQuickPanelAppVolume
    }

    /// Audio-emitting apps discovered by CoreAudio, sorted by name.
    var discoveredApps: [AudioAppIdentity] {
        var seenBundleIDs: Set<String> = []
        return audioProcessDiscovery.discoveredApps
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .filter { app in
                seenBundleIDs.insert(app.bundleID).inserted
            }
    }

    /// Whether per-app volume is available (requires audio routing to be active).
    var isAppVolumeAvailable: Bool {
        router.isRunning
    }

    var shouldShowRoutingOnboarding: Bool {
        EqualEaseSettings.shouldPresentRoutingOnboarding && !router.isRunning && router.state != .starting
    }

    var preferredPanelHeight: CGFloat {
        if shouldShowRoutingOnboarding {
            return 436
        }

        let baseHeightWithoutOptionalControls: CGFloat = 244
        let levelControlHeight: CGFloat = 62
        let levelControlSpacing: CGFloat = showsVolumeControls && showsPreampControls ? 8 : 0
        let volumeSectionHeight: CGFloat = showsVolumeControls ? levelControlHeight : 0
        let preampSectionHeight: CGFloat = showsPreampControls ? levelControlHeight : 0
        let inputSectionHeight: CGFloat = showsInputSection ? 92 : 0
        let routingSectionHeight: CGFloat = showsRoutingSection ? 108 : 0
        let appVolumeSectionHeight: CGFloat = showsAppVolumeSection && isAppVolumeAvailable ? CGFloat(max(44, discoveredApps.count * 48 + 28)) : 0
        let promptHeight: CGFloat = appLearningPrompt == nil ? 0 : 72
        return min(
            Self.maximumPanelHeight,
            baseHeightWithoutOptionalControls
                + volumeSectionHeight
                + preampSectionHeight
                + levelControlSpacing
                + inputSectionHeight
                + appVolumeSectionHeight
                + routingSectionHeight
                + promptHeight
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
