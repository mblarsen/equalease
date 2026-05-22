//
//  EqualEaseAppModel.swift
//  EqualEase
//

import AppKit
import Combine
import Foundation

@MainActor
final class EqualEaseAppModel: ObservableObject {
    let router = CoreAudioRouter()
    let inputDeviceController = InputDeviceController()
    let presetStore = PresetStore()
    let foregroundAppObserver = ForegroundAppObserver()
    let activeContextResolver = ActiveContextPresetResolver()

    lazy var localNetworkControlBridge = LocalNetworkControlBridge(appModel: self)
    lazy var localNetworkControlServer = LocalNetworkControlServer(bridge: localNetworkControlBridge)

    var activeContext: ActivePresetContext? {
        activeContextResolver.context
    }

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledEffectivePresetTask: Task<Void, Never>?
    private var isSelectingPresetManually = false

    init() {
        foregroundAppObserver.$activeApp
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleEffectivePresetApplication()
            }
            .store(in: &cancellables)

        foregroundAppObserver.$activationGeneration
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleEffectivePresetApplication()
            }
            .store(in: &cancellables)

        router.$outputDeviceUID
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyEffectivePreset()
            }
            .store(in: &cancellables)

        presetStore.$selectedPresetID
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.isSelectingPresetManually else { return }
                self.applyEffectivePreset()
            }
            .store(in: &cancellables)

        presetStore.$devicePresetIDs
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyEffectivePreset()
            }
            .store(in: &cancellables)

        presetStore.$appPresetIDs
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyEffectivePreset()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.applyEffectivePreset()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.shutdown()
            }
            .store(in: &cancellables)

        installLocalNetworkStateBroadcasts()

        applyEffectivePreset()
    }

    func autoStartRouting() {
        guard EqualEaseSettings.startAudioRoutingAtLaunch else { return }
        guard !router.isRunning, !router.isRoutingTransitioning else { return }
        router.start()
    }

    func startLocalNetworkControlIfEnabled() {
        guard EqualEaseSettings.localNetworkRemoteEnabled else { return }
        localNetworkControlServer.start()
    }

    func setLocalNetworkControlEnabled(_ enabled: Bool) {
        EqualEaseSettings.localNetworkRemoteEnabled = enabled
        if enabled {
            localNetworkControlServer.start()
        } else {
            localNetworkControlServer.stop()
        }
    }

    func shutdown() {
        scheduledEffectivePresetTask?.cancel()
        scheduledEffectivePresetTask = nil
        localNetworkControlServer.stop()
        router.stop()
    }

    func selectPreset(id presetID: String) {
        isSelectingPresetManually = true
        defer { isSelectingPresetManually = false }

        guard let preset = presetStore.selectPreset(id: presetID) else { return }
        if EqualEaseSettings.isPresetLocked {
            EqualEaseSettings.lockedPresetID = preset.id
            applyEffectivePreset()
            return
        }

        let context = activeContextResolver.recordManualPresetSelection(preset, input: activeContextInput)
        apply(context?.preset ?? preset)
    }

    func setPresetLock(_ isLocked: Bool) {
        if isLocked {
            lockCurrentPreset()
        } else {
            unlockPreset()
        }
    }

    func lockCurrentPreset() {
        let presetID = activeContextResolver.context?.preset.id
            ?? presetStore.preset(id: presetStore.selectedPresetID)?.id
            ?? presetStore.presets.first?.id
        guard let presetID else { return }
        lockPreset(id: presetID)
    }

    func lockPreset(id presetID: String) {
        guard presetStore.preset(id: presetID) != nil else { return }
        EqualEaseSettings.lockedPresetID = presetID
        applyEffectivePreset()
    }

    func unlockPreset() {
        EqualEaseSettings.lockedPresetID = nil
        applyEffectivePreset()
    }

    @discardableResult
    func togglePresetLock() -> Bool {
        if EqualEaseSettings.isPresetLocked {
            unlockPreset()
            return false
        }

        lockCurrentPreset()
        return EqualEaseSettings.isPresetLocked
    }

    func acceptAppPresetSuggestion() {
        guard let suggestion = activeContextResolver.acceptPrompt() else { return }
        presetStore.assignPreset(
            id: suggestion.preset.id,
            toAppBundleIdentifier: suggestion.app.bundleIdentifier,
            displayName: suggestion.app.displayName
        )
        applyEffectivePreset()
    }

    func dismissAppPresetSuggestion() {
        activeContextResolver.dismissPrompt()
    }

    func resetAppPresetSuggestionDismissals() {
        activeContextResolver.resetPromptSession()
    }

    func applyEffectivePreset() {
        if let lockedPresetID = EqualEaseSettings.lockedPresetID,
           presetStore.preset(id: lockedPresetID) == nil {
            EqualEaseSettings.lockedPresetID = nil
        }

        guard let context = activeContextResolver.resolve(input: activeContextInput) else { return }
        apply(context.preset)
    }

    private func scheduleEffectivePresetApplication() {
        scheduledEffectivePresetTask?.cancel()
        scheduledEffectivePresetTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.applyEffectivePreset()
        }
    }

    private var activeContextInput: ActiveContextPresetInput {
        ActiveContextPresetInput(
            selectedPresetID: presetStore.selectedPresetID,
            outputDeviceUID: router.outputDeviceUID,
            foregroundApp: foregroundAppObserver.activeApp,
            presets: presetStore.presets,
            devicePresetIDs: presetStore.devicePresetIDs,
            appPresetIDs: presetStore.appPresetIDs,
            lockedPresetID: EqualEaseSettings.lockedPresetID,
            foregroundActivationGeneration: foregroundAppObserver.activationGeneration
        )
    }

    private func installLocalNetworkStateBroadcasts() {
        let routerPublishers: [AnyPublisher<Void, Never>] = [
            router.$state.map { _ in () }.eraseToAnyPublisher(),
            router.$statusText.map { _ in () }.eraseToAnyPublisher(),
            router.$isRoutingTransitioning.map { _ in () }.eraseToAnyPublisher(),
            router.$outputVolume.map { _ in () }.eraseToAnyPublisher(),
            router.$outputGain.map { _ in () }.eraseToAnyPublisher(),
            router.$bandGains.map { _ in () }.eraseToAnyPublisher(),
            router.$equalizerEnabled.map { _ in () }.eraseToAnyPublisher(),
        ]

        let contextPublishers: [AnyPublisher<Void, Never>] = [
            foregroundAppObserver.$activeApp.map { _ in () }.eraseToAnyPublisher(),
            foregroundAppObserver.$activationGeneration.map { _ in () }.eraseToAnyPublisher(),
            activeContextResolver.$context.map { _ in () }.eraseToAnyPublisher(),
        ]

        let presetPublishers: [AnyPublisher<Void, Never>] = [
            presetStore.$selectedPresetID.map { _ in () }.eraseToAnyPublisher(),
            presetStore.$customPresets.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.eraseToAnyPublisher(),
        ]

        Publishers.MergeMany(routerPublishers + contextPublishers + presetPublishers)
            .dropFirst()
            .sink { [weak self] _ in
                self?.localNetworkControlServer.broadcastStatePatch()
            }
            .store(in: &cancellables)
    }

    func apply(_ preset: EQPreset) {
        if router.outputGain != preset.outputGain {
            router.outputGain = preset.outputGain
        }

        let equalizerEnabled = !preset.isFlat
        if router.equalizerEnabled != equalizerEnabled {
            router.equalizerEnabled = equalizerEnabled
        }

        for (index, gain) in preset.bandGains.enumerated() where router.bandGains.indices.contains(index) {
            if router.bandGains[index] != gain {
                router.setBandGain(gain, at: index)
            }
        }
    }
}
