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

    private let host: CoreAudioRoutingHost
    private let restartDebounce: Duration
    private var outputDeviceObservation: AudioRoutingObservation?
    private var outputVolumeObservation: AudioRoutingObservation?
    private var restartTask: Task<Void, Never>?
    private var isRefreshingOutputVolume = false

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
        cleanupOnLaunch: Bool = true
    ) {
        self.host = host
        self.restartDebounce = restartDebounce
        selectedOutputDeviceUID = nil
        refreshOutputDevice()
        startOutputDeviceObservation()
        if cleanupOnLaunch {
            cleanupOwnedAudioStateOnLaunch()
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
        selectedOutputDeviceUID = uid
    }

    func start() {
        guard !isRunning, !isRoutingTransitioning else { return }
        isRoutingTransitioning = true
        state = .starting
        statusText = "Starting audio routing…"

        do {
            _ = try host.cleanupOwnedAudioState(includeDevelopmentObjects: false)
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
            outputDevices = snapshot.devices
            let selectedDeviceStillAvailable = outputDevices.contains { $0.uid == selectedOutputDeviceUID }
            if followsSystemOutput || selectedOutputDeviceUID == nil || !selectedDeviceStillAvailable {
                selectedOutputDeviceUID = snapshot.defaultOutputDeviceUID ?? outputDevices.first?.uid
            }
            refreshSelectedOutputDevice()
        } catch {
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
            bandGains: bandGains
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

    private func refreshSelectedOutputDevice() {
        outputDeviceUID = selectedOutputDeviceUID
        outputDeviceName = selectedOutputDevice?.name ?? "Unknown output device"
        startSelectedOutputVolumeObservation()
        refreshSelectedOutputVolume()
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

    private func cleanupOwnedAudioStateOnLaunch() {
        do {
            let result = try host.cleanupOwnedAudioState(includeDevelopmentObjects: false)
            if result.destroyedTaps > 0 || result.destroyedAggregates > 0 {
                statusText = result.summary
            }
        } catch {
            state = .failed(error.localizedDescription)
            statusText = error.localizedDescription
        }
    }
}
