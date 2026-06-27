//
//  CoreAudioRouter.swift
//  EqualEase
//

import Combine
import Foundation

@MainActor
final class CoreAudioRouter: AudioRoutingBackend {
    @Published private(set) var state: AudioRoutingState = .stopped
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var outputDeviceName = "Unknown output device"
    @Published private(set) var outputDeviceUID: String?
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var isRoutingTransitioning = false
    @Published var selectedOutputDeviceUID: String? {
        didSet {
            refreshSelectedOutputDevice()
            if isRunning, oldValue != selectedOutputDeviceUID {
                scheduleRestartRouting(reason: "Output changed")
            }
        }
    }
    @Published var followsSystemOutput = true {
        didSet { refreshOutputDevice() }
    }
    @Published var isBypassed = false {
        didSet {
            host.setBypassed(isBypassed)
            refreshRunningStatus()
        }
    }
    @Published var outputVolume = 1.0 {
        didSet {
            guard !isRefreshingOutputVolume else { return }
            setSelectedOutputVolume(outputVolume)
        }
    }
    @Published private(set) var canSetOutputVolume = false
    @Published var outputGain = 1.0 {
        didSet {
            host.setOutputGain(clampedOutputGain)
            refreshRunningStatus()
        }
    }
    @Published var equalizerEnabled = false {
        didSet {
            host.setEqualizerEnabled(equalizerEnabled)
            refreshRunningStatus()
        }
    }
    @Published var bandGains = Array(repeating: 0.0, count: 10) {
        didSet { applyBandGains() }
    }
    @Published private(set) var appTapConfigs: [AudioAppTapConfig] = []

    private struct AppTapDiscoveryState {
        var firstSeenAt: Date
        var lastSeenAt: Date
    }

    private let host: CoreAudioRoutingHost
    private let restartDebounce: Duration
    private let appTapAddStability: TimeInterval
    private let appTapRemoveGrace: TimeInterval
    private let now: () -> Date
    private var outputDeviceObservation: AudioRoutingObservation?
    private var outputVolumeObservation: AudioRoutingObservation?
    private var restartTask: Task<Void, Never>?
    private var appTapDiscoveryStates: [AudioObjectID: AppTapDiscoveryState] = [:]
    private var isRefreshingOutputVolume = false
    private var outputDeviceSnapshot = AudioOutputDeviceSnapshot(devices: [], defaultOutputDeviceUID: nil)

    private var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputDeviceUID else { return nil }
        return outputDevices.first { $0.uid == selectedOutputDeviceUID }
    }

    private var clampedOutputGain: Double {
        min(max(outputGain, 0), 2)
    }

    convenience init() {
        self.init(host: ProductionCoreAudioRoutingHost())
    }

    init(
        host: CoreAudioRoutingHost,
        restartDebounce: Duration = .milliseconds(200),
        appTapAddStability: TimeInterval = 2.0,
        appTapRemoveGrace: TimeInterval = 8.0,
        now: @escaping () -> Date = Date.init,
        cleanupOnLaunch: Bool = false
    ) {
        self.host = host
        self.restartDebounce = restartDebounce
        self.appTapAddStability = appTapAddStability
        self.appTapRemoveGrace = appTapRemoveGrace
        self.now = now
        selectedOutputDeviceUID = nil
        refreshOutputDevice()
        startOutputDeviceObservation()
        if cleanupOnLaunch {
            do {
                try cleanupOwnedAudioStateBeforeExplicitRouting()
            } catch {
                state = .failed(error.localizedDescription)
                statusText = error.localizedDescription
            }
        }
    }

    var isRunning: Bool {
        state == .running
    }

    private var processingSummary: String {
        if isBypassed {
            return "DSP bypassed"
        }
        let eqState = equalizerEnabled ? "EQ on" : "EQ off"
        return "\(eqState), \(Int(clampedOutputGain * 100))% preamp"
    }

    private func refreshRunningStatus() {
        guard isRunning else { return }
        statusText = "Active: routing processed system audio to \(outputDeviceName) (\(processingSummary))."
    }

    func setBandGain(_ gain: Double, at index: Int) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = min(max(gain, -12), 12)
        host.setBandGain(bandGains[index], at: index)
        refreshRunningStatus()
    }

    func selectOutputDevice(uid: String?) {
        followsSystemOutput = false
        selectedOutputDeviceUID = resolvedPreferredOutputDeviceUID(requestedUID: uid)
    }

    func updateAppTapConfigs(apps: [AudioAppIdentity], volumeStore: AppVolumeStore) {
        let currentTime = now()
        let discoveredConfigs = customizedAppTapConfigs(apps: apps, volumeStore: volumeStore)
        let discoveredByProcessObjectID = Dictionary(
            uniqueKeysWithValues: discoveredConfigs.map { ($0.processObjectID, $0) }
        )
        var nextConfigs: [AudioAppTapConfig] = []
        var nextProcessObjectIDs: Set<AudioObjectID> = []

        for config in discoveredConfigs {
            let previousState = appTapDiscoveryStates[config.processObjectID]
            let state = AppTapDiscoveryState(
                firstSeenAt: previousState?.firstSeenAt ?? currentTime,
                lastSeenAt: currentTime
            )
            appTapDiscoveryStates[config.processObjectID] = state

            let isAlreadyTapped = appTapConfigs.contains { $0.processObjectID == config.processObjectID }
            let hasBeenStableLongEnough = currentTime.timeIntervalSince(state.firstSeenAt) >= appTapAddStability
            if isAlreadyTapped || hasBeenStableLongEnough {
                nextConfigs.append(config)
                nextProcessObjectIDs.insert(config.processObjectID)
            }
        }

        for config in appTapConfigs where discoveredByProcessObjectID[config.processObjectID] == nil {
            let lastSeenAt = appTapDiscoveryStates[config.processObjectID]?.lastSeenAt ?? currentTime
            if currentTime.timeIntervalSince(lastSeenAt) < appTapRemoveGrace {
                let updatedConfig = updatedAppTapConfig(config, volumeStore: volumeStore)
                nextConfigs.append(updatedConfig)
                nextProcessObjectIDs.insert(updatedConfig.processObjectID)
            } else {
                appTapDiscoveryStates.removeValue(forKey: config.processObjectID)
            }
        }

        appTapDiscoveryStates = appTapDiscoveryStates.filter { entry in
            discoveredByProcessObjectID[entry.key] != nil || nextProcessObjectIDs.contains(entry.key)
        }

        let previousProcessObjectIDs = appTapConfigs.map(\.processObjectID)
        if Set(previousProcessObjectIDs) == Set(nextConfigs.map(\.processObjectID)) {
            let nextByProcessObjectID = Dictionary(uniqueKeysWithValues: nextConfigs.map { ($0.processObjectID, $0) })
            nextConfigs = previousProcessObjectIDs.compactMap { nextByProcessObjectID[$0] }
        }

        let nextProcessObjectIDsInOrder = nextConfigs.map(\.processObjectID)
        appTapConfigs = nextConfigs

        if isRunning, previousProcessObjectIDs != nextProcessObjectIDsInOrder {
            scheduleRestartRouting(reason: "Audio apps changed")
        } else if isRunning {
            host.setStreamConfigs(streamConfigs(from: nextConfigs))
            refreshRunningStatus()
        }
    }

    func start() {
        guard !isRunning, !isRoutingTransitioning else { return }
        isRoutingTransitioning = true
        state = .starting
        statusText = "Starting audio routing…"

        do {
            _ = try cleanupOwnedAudioStateBeforeExplicitRouting()
            let result = try host.startRoute(configuration: startConfiguration)
            applyStartedOutputDevice(result.outputDevice)
            state = .running
            refreshRunningStatus()
        } catch {
            host.stopRoute()
            state = .failed(error.localizedDescription)
            statusText = "Could not start audio routing: \(error.localizedDescription)"
        }
        isRoutingTransitioning = false
    }

    func stop() {
        guard state != .stopped || isRoutingTransitioning else { return }
        isRoutingTransitioning = true
        statusText = "Stopping audio routing…"
        stop(cancelPendingRestart: true)
    }

    func restart() {
        scheduleRestartRouting(reason: "Manual restart requested")
    }

    func cleanupAudioState() {
        restartTask?.cancel()
        restartTask = nil
        appTapConfigs = []
        appTapDiscoveryStates = [:]
        isRoutingTransitioning = true
        host.stopRoute()

        do {
            let result = try host.cleanupOwnedAudioState(includeDevelopmentObjects: true)
            state = .stopped
            statusText = result.summary
        } catch {
            state = .failed(error.localizedDescription)
            statusText = "Could not clean up audio state: \(error.localizedDescription)"
        }
        isRoutingTransitioning = false
    }

    func refreshOutputDevice() {
        do {
            let snapshot = try host.loadOutputDevices()
            outputDeviceSnapshot = snapshot
            outputDevices = snapshot.devices
            let selectedDeviceStillAvailable = outputDevices.contains { $0.uid == selectedOutputDeviceUID }
            if followsSystemOutput {
                selectedOutputDeviceUID = resolvedPreferredOutputDeviceUID(
                    requestedUID: nil,
                    snapshot: snapshot
                )
            } else if selectedOutputDeviceUID == nil || !selectedDeviceStillAvailable {
                selectedOutputDeviceUID = resolvedPreferredOutputDeviceUID(
                    requestedUID: selectedOutputDeviceUID,
                    snapshot: snapshot
                )
            }
            refreshSelectedOutputDevice()
        } catch {
            outputDeviceSnapshot = AudioOutputDeviceSnapshot(devices: [], defaultOutputDeviceUID: nil)
            outputDevices = []
            outputDeviceName = "Unknown output device"
            outputDeviceUID = nil
            canSetOutputVolume = false
            outputVolumeObservation?.invalidate()
            outputVolumeObservation = nil
        }
    }

    private func customizedAppTapConfigs(
        apps: [AudioAppIdentity],
        volumeStore: AppVolumeStore
    ) -> [AudioAppTapConfig] {
        var seenProcessObjectIDs: Set<AudioObjectID> = []
        return AudioAppIdentity.sortedForDisplay(apps).compactMap { app -> AudioAppTapConfig? in
            guard seenProcessObjectIDs.insert(app.processObjectID).inserted else { return nil }
            let config = updatedAppTapConfig(
                AudioAppTapConfig(processObjectID: app.processObjectID, bundleID: app.bundleID, gain: 1, mode: .on),
                volumeStore: volumeStore
            )

            // The fallback tap already captures default apps at unity gain. Only apps with
            // explicit per-app audio settings need a dedicated tap. This keeps ordinary audio
            // process churn from restarting the route and briefly releasing EqualEase control.
            guard config.gain != 1 || config.mode != .on else { return nil }
            return config
        }
    }

    private func updatedAppTapConfig(
        _ config: AudioAppTapConfig,
        volumeStore: AppVolumeStore
    ) -> AudioAppTapConfig {
        AudioAppTapConfig(
            processObjectID: config.processObjectID,
            bundleID: config.bundleID,
            gain: min(max(volumeStore.volume(for: config.bundleID), 0), 1),
            mode: volumeStore.mode(for: config.bundleID)
        )
    }

    private var startConfiguration: AudioRouteStartConfiguration {
        AudioRouteStartConfiguration(
            selectedOutputDeviceUID: selectedOutputDeviceUID,
            isBypassed: isBypassed,
            outputGain: clampedOutputGain,
            equalizerEnabled: equalizerEnabled,
            bandGains: bandGains,
            appTapConfigs: appTapConfigs
        )
    }

    private func applyStartedOutputDevice(_ outputDevice: AudioOutputDevice) {
        outputDeviceUID = outputDevice.uid
        outputDeviceName = outputDevice.name
        if !outputDevices.contains(where: { $0.uid == outputDevice.uid }) {
            outputDevices.append(outputDevice)
            outputDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if selectedOutputDeviceUID != outputDevice.uid {
            selectedOutputDeviceUID = outputDevice.uid
        }
        refreshSelectedOutputDevice()
    }

    private func stop(cancelPendingRestart: Bool) {
        if cancelPendingRestart {
            restartTask?.cancel()
            restartTask = nil
            appTapConfigs = []
            appTapDiscoveryStates = [:]
        }
        host.stopRoute()
        state = .stopped
        statusText = "Stopped"
        isRoutingTransitioning = false
    }

    private func scheduleRestartRouting(reason: String) {
        guard isRunning else { return }
        restartTask?.cancel()
        isRoutingTransitioning = true
        let target = selectedOutputDevice?.name ?? outputDeviceName
        statusText = "\(reason). Restarting audio routing to \(target)…"
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.restartDebounce)
            guard !Task.isCancelled, self.isRunning else {
                self.isRoutingTransitioning = false
                return
            }
            self.restartRouting(reason: reason)
        }
    }

    private func restartRouting(reason: String) {
        let target = selectedOutputDevice?.name ?? outputDeviceName
        statusText = "\(reason). Restarting audio routing to \(target)…"
        stop(cancelPendingRestart: false)
        start()
    }

    private func applyBandGains() {
        for (index, gain) in bandGains.enumerated() {
            host.setBandGain(min(max(gain, -12), 12), at: index)
        }
    }

    private func streamConfigs(from appTapConfigs: [AudioAppTapConfig]) -> [StreamConfig] {
        appTapConfigs.map {
            StreamConfig(
                gain: Float(min(max($0.gain, 0), 1)),
                bypassed: ObjCBool($0.isBypassed),
                muted: ObjCBool($0.isMuted)
            )
        } + [StreamConfig(gain: 1.0, bypassed: ObjCBool(false), muted: ObjCBool(false))]
    }

    private func refreshSelectedOutputDevice() {
        outputDeviceUID = selectedOutputDeviceUID
        outputDeviceName = selectedOutputDevice?.name ?? "Unknown output device"
        startSelectedOutputVolumeObservation()
        refreshSelectedOutputVolume()
    }

    private func resolvedPreferredOutputDeviceUID(
        requestedUID: String?,
        snapshot: AudioOutputDeviceSnapshot? = nil
    ) -> String? {
        let snapshot = snapshot ?? outputDeviceSnapshot

        if let requestedUID,
           snapshot.devices.contains(where: { $0.uid == requestedUID }) {
            return requestedUID
        }

        if let defaultOutputDeviceUID = snapshot.defaultOutputDeviceUID,
           snapshot.devices.contains(where: { $0.uid == defaultOutputDeviceUID }) {
            return defaultOutputDeviceUID
        }

        return snapshot.devices.first?.uid
    }

    private func refreshSelectedOutputVolume() {
        let volumeState = host.outputVolumeState(for: selectedOutputDeviceUID)
        canSetOutputVolume = volumeState.canSetVolume
        guard let volume = volumeState.volume else { return }
        isRefreshingOutputVolume = true
        outputVolume = min(max(volume, 0), 1)
        isRefreshingOutputVolume = false
    }

    private func setSelectedOutputVolume(_ volume: Double) {
        guard canSetOutputVolume else { return }
        host.setOutputVolume(volume, for: selectedOutputDeviceUID)
        refreshSelectedOutputVolume()
    }

    private func startOutputDeviceObservation() {
        guard outputDeviceObservation == nil else { return }
        outputDeviceObservation = host.observeOutputDevices { [weak self] in
            self?.refreshOutputDevice()
        }
        if outputDeviceObservation == nil {
            statusText = "Output device change observation unavailable; refresh occurs when the menu opens or routing starts."
        }
    }

    private func startSelectedOutputVolumeObservation() {
        outputVolumeObservation?.invalidate()
        outputVolumeObservation = host.observeOutputVolume(for: selectedOutputDeviceUID) { [weak self] in
            self?.refreshSelectedOutputVolume()
        }
    }

    @discardableResult
    private func cleanupOwnedAudioStateBeforeExplicitRouting() throws -> AudioRoutingCleanupResult {
        let result = try host.cleanupOwnedAudioState(includeDevelopmentObjects: false)
        if result.destroyedTaps > 0 || result.destroyedAggregates > 0 {
            statusText = result.summary
        }
        return result
    }
}
