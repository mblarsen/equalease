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

    private struct AppTapRecord {
        var config: AudioAppTapConfig
        var displayName: String
    }

    private struct PendingAppTapRecord {
        var config: AudioAppTapConfig
        var consecutiveDiscoveryUpdates: Int
    }

    private let host: CoreAudioRoutingHost
    private let restartDebounce: Duration
    private let appTapAddConfirmationUpdates: Int
    private let appTapRemovalGrace: Duration
    private var outputDeviceObservation: AudioRoutingObservation?
    private var outputVolumeObservation: AudioRoutingObservation?
    private var restartTask: Task<Void, Never>?
    private var appTapRemovalTasks: [AudioObjectID: Task<Void, Never>] = [:]
    private var appTapRecords: [AudioObjectID: AppTapRecord] = [:]
    private var pendingAppTapRecords: [AudioObjectID: PendingAppTapRecord] = [:]
    private var lastAppTapDiscoveryGeneration: Int?
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
        appTapAddConfirmationUpdates: Int = 2,
        appTapRemovalGrace: Duration = .seconds(8),
        cleanupOnLaunch: Bool = false
    ) {
        self.host = host
        self.restartDebounce = restartDebounce
        self.appTapAddConfirmationUpdates = max(1, appTapAddConfirmationUpdates)
        self.appTapRemovalGrace = appTapRemovalGrace
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

    func updateAppTapConfigs(
        apps: [AudioAppIdentity],
        volumeStore: AppVolumeStore,
        discoveryGeneration: Int? = nil
    ) {
        let isDiscoveryRefresh = registerAppTapDiscoveryGeneration(discoveryGeneration)
        var seenProcessObjectIDs: Set<AudioObjectID> = []
        var discoveredProcessObjectIDs: Set<AudioObjectID> = []
        var customizedRecords: [AudioObjectID: AppTapRecord] = [:]

        for app in apps.sorted(by: appTapSort) {
            guard seenProcessObjectIDs.insert(app.processObjectID).inserted else { continue }
            discoveredProcessObjectIDs.insert(app.processObjectID)

            let gain = min(max(volumeStore.volume(for: app.bundleID), 0), 1)
            let mode = volumeStore.mode(for: app.bundleID)

            // The fallback tap already captures default apps at unity gain. Only apps with
            // explicit per-app audio settings need a dedicated tap. This keeps ordinary audio
            // process churn from restarting the route and briefly releasing EqualEase control.
            guard gain != 1 || mode != .on else { continue }

            let config = AudioAppTapConfig(
                processObjectID: app.processObjectID,
                bundleID: app.bundleID,
                gain: gain,
                mode: mode
            )
            customizedRecords[app.processObjectID] = AppTapRecord(config: config, displayName: app.displayName)
        }

        for (processObjectID, record) in Array(appTapRecords) {
            if let updatedRecord = customizedRecords[processObjectID] {
                cancelAppTapRemoval(for: processObjectID)
                appTapRecords[processObjectID] = updatedRecord
                pendingAppTapRecords.removeValue(forKey: processObjectID)
            } else if discoveredProcessObjectIDs.contains(processObjectID) {
                cancelAppTapRemoval(for: processObjectID)
                appTapRecords.removeValue(forKey: processObjectID)
                pendingAppTapRecords.removeValue(forKey: processObjectID)
            } else {
                appTapRecords[processObjectID] = record
                scheduleAppTapRemoval(for: processObjectID)
            }
        }

        for (processObjectID, record) in customizedRecords where appTapRecords[processObjectID] == nil {
            let previousPending = pendingAppTapRecords[processObjectID]
            let seenCount: Int
            if isDiscoveryRefresh {
                seenCount = (previousPending?.consecutiveDiscoveryUpdates ?? 0) + 1
            } else {
                seenCount = previousPending?.consecutiveDiscoveryUpdates ?? 0
            }

            if seenCount >= appTapAddConfirmationUpdates {
                pendingAppTapRecords.removeValue(forKey: processObjectID)
                appTapRecords[processObjectID] = record
            } else {
                pendingAppTapRecords[processObjectID] = PendingAppTapRecord(
                    config: record.config,
                    consecutiveDiscoveryUpdates: seenCount
                )
            }
        }

        pendingAppTapRecords = pendingAppTapRecords.filter { processObjectID, pending in
            if customizedRecords[processObjectID] != nil { return true }
            guard discoveredProcessObjectIDs.contains(processObjectID) else { return false }
            return volumeStore.volume(for: pending.config.bundleID) != 1
                || volumeStore.mode(for: pending.config.bundleID) != .on
        }

        publishAppTapConfigs(reason: "Audio apps changed")
    }

    private func registerAppTapDiscoveryGeneration(_ discoveryGeneration: Int?) -> Bool {
        guard let discoveryGeneration else { return true }

        defer { lastAppTapDiscoveryGeneration = discoveryGeneration }
        return lastAppTapDiscoveryGeneration != discoveryGeneration
    }

    private func appTapSort(_ lhs: AudioAppIdentity, _ rhs: AudioAppIdentity) -> Bool {
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let bundleOrder = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
        if bundleOrder != .orderedSame { return bundleOrder == .orderedAscending }
        return lhs.processObjectID < rhs.processObjectID
    }

    private func publishAppTapConfigs(reason: String) {
        let previousProcessObjectIDs = appTapConfigs.map(\.processObjectID)
        let configs = appTapRecords.values
            .sorted { lhs, rhs in
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                let bundleOrder = lhs.config.bundleID.localizedCaseInsensitiveCompare(rhs.config.bundleID)
                if bundleOrder != .orderedSame { return bundleOrder == .orderedAscending }
                return lhs.config.processObjectID < rhs.config.processObjectID
            }
            .map(\.config)
        let nextProcessObjectIDs = configs.map(\.processObjectID)
        appTapConfigs = configs

        if isRunning, previousProcessObjectIDs != nextProcessObjectIDs {
            scheduleRestartRouting(reason: reason)
        } else if isRunning {
            host.setStreamConfigs(streamConfigs(from: configs))
            refreshRunningStatus()
        }
    }

    private func scheduleAppTapRemoval(for processObjectID: AudioObjectID) {
        guard isRunning, appTapRemovalTasks[processObjectID] == nil else { return }
        appTapRemovalTasks[processObjectID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.appTapRemovalGrace)
            guard !Task.isCancelled else { return }
            self.appTapRemovalTasks[processObjectID] = nil
            guard self.appTapRecords.removeValue(forKey: processObjectID) != nil else { return }
            self.publishAppTapConfigs(reason: "Audio apps changed")
        }
    }

    private func cancelAppTapRemoval(for processObjectID: AudioObjectID) {
        appTapRemovalTasks[processObjectID]?.cancel()
        appTapRemovalTasks.removeValue(forKey: processObjectID)
    }

    private func resetAppTapHysteresis() {
        for task in appTapRemovalTasks.values { task.cancel() }
        appTapRemovalTasks = [:]
        appTapRecords = [:]
        pendingAppTapRecords = [:]
        lastAppTapDiscoveryGeneration = nil
        appTapConfigs = []
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
        resetAppTapHysteresis()
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
            resetAppTapHysteresis()
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
