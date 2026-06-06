//
//  InputDeviceControl.swift
//  EqualEase
//

import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    var id: String { uid }
    var uid: String
    var name: String
}

struct AudioInputDeviceSnapshot: Equatable {
    var device: AudioInputDevice?
}

struct AudioInputVolumeState: Equatable {
    var canReadVolume: Bool
    var canSetVolume: Bool
    var volume: Double?

    static let unavailable = AudioInputVolumeState(canReadVolume: false, canSetVolume: false, volume: nil)
}

@MainActor
protocol InputDeviceControlHost: AnyObject {
    func loadCurrentInputDevice() throws -> AudioInputDeviceSnapshot
    func inputVolumeState(for inputDeviceUID: String?) -> AudioInputVolumeState
    @discardableResult
    func setInputVolume(_ volume: Double, for inputDeviceUID: String?) -> Bool
    func observeInputDeviceChanges(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation?
    func observeInputVolume(for inputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation?
}

@MainActor
final class InputDeviceController: ObservableObject {
    @Published private(set) var inputDeviceName = "No input device"
    @Published private(set) var inputDeviceUID: String?
    @Published private(set) var canReadInputVolume = false
    @Published private(set) var canSetInputVolume = false
    @Published var inputVolume = 1.0 {
        didSet {
            guard !isRefreshingInputVolume else { return }
            setCurrentInputVolume(inputVolume)
        }
    }
    @Published var protectionSettings: InputVolumeProtectionSettings {
        didSet {
            let normalized = protectionSettings.normalized
            guard protectionSettings == normalized else {
                protectionSettings = normalized
                return
            }
            InputVolumeProtectionSettingsStore.save(normalized)
            evaluateLowVolumeProtection()
        }
    }
    @Published private(set) var isInputVolumeLow = false
    @Published private(set) var lowVolumeProtectionStatus = "Monitoring current input volume."
    @Published private(set) var notificationAuthorizationStatus: InputVolumeProtectionNotificationStatus = .notRequested
    @Published private(set) var lastLowVolumeNotificationSummary = "Never"
    @Published private(set) var lastCapAttemptSummary = "Never"

    private let host: InputDeviceControlHost
    private let notifier: InputVolumeProtectionNotifying
    private let now: () -> Date
    private let capAttemptInterval: TimeInterval
    private var notificationPolicy: InputVolumeProtectionNotificationPolicy
    private var inputDeviceObservation: AudioRoutingObservation?
    private var inputVolumeObservation: AudioRoutingObservation?
    private var isRefreshingInputVolume = false
    private var isLowVolumeNotificationInFlight = false
    private var lastCapAttemptDate: Date?

    convenience init() {
        self.init(host: ProductionInputDeviceControlHost())
    }

    init(
        host: InputDeviceControlHost,
        notifier: InputVolumeProtectionNotifying? = nil,
        now: @escaping () -> Date = Date.init,
        notificationPolicy: InputVolumeProtectionNotificationPolicy = .default,
        capAttemptInterval: TimeInterval = 10
    ) {
        self.host = host
        self.notifier = notifier ?? UserNotificationInputVolumeProtectionNotifier()
        self.now = now
        self.capAttemptInterval = capAttemptInterval
        self.notificationPolicy = notificationPolicy
        self.protectionSettings = InputVolumeProtectionSettingsStore.load()
        refreshInputDevice()
        startInputDeviceObservation()
        Task { [weak self] in
            guard let self else { return }
            notificationAuthorizationStatus = await self.notifier.refreshAuthorizationStatus()
        }
    }

    var inputVolumeSummary: String {
        guard canReadInputVolume else { return "Unavailable" }
        return "\(Int(inputVolume * 100))%"
    }

    var inputVolumeCapabilitySummary: String {
        if canSetInputVolume {
            return "Settable"
        }
        if canReadInputVolume {
            return "Read-only"
        }
        return "Unavailable"
    }

    func refreshInputDevice() {
        do {
            let snapshot = try host.loadCurrentInputDevice()
            inputDeviceName = snapshot.device?.name ?? "No input device"
            inputDeviceUID = snapshot.device?.uid
            startCurrentInputVolumeObservation()
            refreshCurrentInputVolume()
        } catch {
            inputDeviceName = "No input device"
            inputDeviceUID = nil
            canReadInputVolume = false
            canSetInputVolume = false
            inputVolumeObservation?.invalidate()
            inputVolumeObservation = nil
        }
    }

    func refreshCurrentInputVolume() {
        let volumeState = host.inputVolumeState(for: inputDeviceUID)
        canReadInputVolume = volumeState.canReadVolume
        canSetInputVolume = volumeState.canSetVolume
        guard let volume = volumeState.volume else {
            isInputVolumeLow = false
            lowVolumeProtectionStatus = "Low-volume detection unavailable for this input device."
            return
        }
        isRefreshingInputVolume = true
        inputVolume = min(max(volume, 0), 1)
        isRefreshingInputVolume = false
        evaluateLowVolumeProtection()
    }

    func requestNotificationPermission() {
        Task { [weak self] in
            guard let self else { return }
            notificationAuthorizationStatus = await notifier.requestAuthorization()
        }
    }

    private func setCurrentInputVolume(_ volume: Double) {
        guard canSetInputVolume else { return }
        _ = host.setInputVolume(volume, for: inputDeviceUID)
        refreshCurrentInputVolume()
    }

    private func evaluateLowVolumeProtection() {
        guard canReadInputVolume else {
            isInputVolumeLow = false
            lowVolumeProtectionStatus = "Low-volume detection unavailable for this input device."
            return
        }

        let settings = protectionSettings.normalized
        let currentDate = now()
        let currentVolume = inputVolume
        let isLow = currentVolume < settings.threshold
        isInputVolumeLow = isLow

        guard isLow else {
            notificationPolicy.recordHealthyVolume(at: currentDate)
            lowVolumeProtectionStatus = "Input volume is OK."
            return
        }

        notificationPolicy.recordLowVolume(at: currentDate)

        if settings.capEnabled {
            attemptCapIfNeeded(settings: settings, currentVolume: currentVolume)
        } else if !canSetInputVolume {
            lowVolumeProtectionStatus = "Input volume is low; automatic capping is unavailable for this device."
        } else {
            lowVolumeProtectionStatus = "Input volume is low."
        }

        if settings.notificationsEnabled,
           !isLowVolumeNotificationInFlight,
           notificationPolicy.shouldNotify(at: currentDate) {
            postLowVolumeNotification(volume: currentVolume, threshold: settings.threshold, currentDate: currentDate)
        }
    }

    private func attemptCapIfNeeded(settings: InputVolumeProtectionSettings, currentVolume: Double) {
        guard canSetInputVolume else {
            lowVolumeProtectionStatus = "Input volume is low; automatic capping is unavailable for this device."
            lastCapAttemptSummary = "Skipped: input volume is read-only or unavailable"
            return
        }
        guard settings.capMinimum > currentVolume else { return }
        let currentDate = now()
        if let lastCapAttemptDate, currentDate.timeIntervalSince(lastCapAttemptDate) < capAttemptInterval {
            lowVolumeProtectionStatus = "Input volume is low; cap attempt is rate-limited."
            return
        }
        lastCapAttemptDate = currentDate
        let capSucceeded = host.setInputVolume(settings.capMinimum, for: inputDeviceUID)
        if capSucceeded {
            isRefreshingInputVolume = true
            inputVolume = settings.capMinimum
            isRefreshingInputVolume = false
            isInputVolumeLow = inputVolume < settings.threshold
            lastCapAttemptSummary = "Raised to \(Int(settings.capMinimum * 100))%"
            lowVolumeProtectionStatus = "Input volume was low and EqualEase raised it to \(Int(settings.capMinimum * 100))%."
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.refreshCurrentInputVolume()
            }
        } else {
            lastCapAttemptSummary = "Failed to set input volume"
            lowVolumeProtectionStatus = "Input volume is low; EqualEase could not set this device's input volume."
        }
    }

    private func postLowVolumeNotification(volume: Double, threshold: Double, currentDate: Date) {
        isLowVolumeNotificationInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let posted = await notifier.postLowInputVolumeNotification(
                deviceName: inputDeviceName,
                volume: volume,
                threshold: threshold
            )
            if posted {
                notificationPolicy.recordNotificationSent(at: currentDate)
            }
            notificationAuthorizationStatus = await notifier.refreshAuthorizationStatus()
            lastLowVolumeNotificationSummary = posted ? "Posted at \(Self.shortTimeFormatter.string(from: now()))" : "Unavailable: \(notificationAuthorizationStatus.summary)"
            isLowVolumeNotificationInFlight = false
        }
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func startInputDeviceObservation() {
        guard inputDeviceObservation == nil else { return }
        inputDeviceObservation = host.observeInputDeviceChanges { [weak self] in
            self?.refreshInputDevice()
        }
    }

    private func startCurrentInputVolumeObservation() {
        inputVolumeObservation?.invalidate()
        inputVolumeObservation = host.observeInputVolume(for: inputDeviceUID) { [weak self] in
            self?.refreshCurrentInputVolume()
        }
    }
}

@MainActor
final class ProductionInputDeviceControlHost: InputDeviceControlHost {
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    func loadCurrentInputDevice() throws -> AudioInputDeviceSnapshot {
        guard let inputDeviceID = try? readDefaultInputDevice() else {
            return AudioInputDeviceSnapshot(device: nil)
        }

        let uid = try readAudioObjectString(objectID: inputDeviceID, selector: kAudioDevicePropertyDeviceUID)
        let name = (try? readAudioObjectString(objectID: inputDeviceID, selector: kAudioObjectPropertyName)) ?? uid
        return AudioInputDeviceSnapshot(device: AudioInputDevice(uid: uid, name: name))
    }

    func inputVolumeState(for inputDeviceUID: String?) -> AudioInputVolumeState {
        guard let deviceID = try? currentInputDeviceID(matching: inputDeviceUID) else {
            return .unavailable
        }

        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        let scope = kAudioDevicePropertyScopeInput
        guard audioObjectHasProperty(objectID: deviceID, selector: selector, scope: scope) else {
            return .unavailable
        }

        let volume = (try? readAudioObjectFloat32(objectID: deviceID, selector: selector, scope: scope))
            .map { min(max(Double($0), 0), 1) }
        let canReadVolume = volume != nil
        let canSetVolume = canReadVolume && audioObjectIsPropertySettable(objectID: deviceID, selector: selector, scope: scope)
        return AudioInputVolumeState(canReadVolume: canReadVolume, canSetVolume: canSetVolume, volume: volume)
    }

    func setInputVolume(_ volume: Double, for inputDeviceUID: String?) -> Bool {
        guard let deviceID = try? currentInputDeviceID(matching: inputDeviceUID) else { return false }
        let clampedVolume = Float32(min(max(volume, 0), 1))
        do {
            try writeAudioObjectFloat32(
                objectID: deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                value: clampedVolume,
                scope: kAudioDevicePropertyScopeInput
            )
            return true
        } catch {
            return false
        }
    }

    func observeInputDeviceChanges(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        let queue = DispatchQueue.main
        var removals: [() -> Void] = []

        let defaultInputListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        var defaultInputDeviceAddress = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        let defaultStatus = AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultInputDeviceAddress, queue, defaultInputListener)
        if defaultStatus == kAudioHardwareNoError {
            removals.append { [systemObjectID] in
                var address = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, queue, defaultInputListener)
            }
        }

        let devicesListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        var devicesAddress = coreAudioPropertyAddress(kAudioHardwarePropertyDevices)
        let devicesStatus = AudioObjectAddPropertyListenerBlock(systemObjectID, &devicesAddress, queue, devicesListener)
        if devicesStatus == kAudioHardwareNoError {
            removals.append { [systemObjectID] in
                var address = coreAudioPropertyAddress(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, queue, devicesListener)
            }
        }

        guard defaultStatus == kAudioHardwareNoError, devicesStatus == kAudioHardwareNoError else {
            removals.forEach { $0() }
            return nil
        }

        return AudioRoutingObservation {
            removals.forEach { $0() }
        }
    }

    func observeInputVolume(for inputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        guard let deviceID = try? currentInputDeviceID(matching: inputDeviceUID),
              audioObjectHasProperty(
                objectID: deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeInput
              )
        else { return nil }

        let queue = DispatchQueue.main
        var inputVolumeAddress = coreAudioPropertyAddress(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeInput
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &inputVolumeAddress, queue, listener)
        guard status == kAudioHardwareNoError else { return nil }

        return AudioRoutingObservation {
            var address = coreAudioPropertyAddress(
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeInput
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
    }

    private func currentInputDeviceID(matching inputDeviceUID: String?) throws -> AudioObjectID {
        let deviceID = try readDefaultInputDevice()
        if let inputDeviceUID {
            let currentUID = try? readAudioObjectString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
            guard currentUID == inputDeviceUID else { return deviceID }
        }
        return deviceID
    }

    private func readDefaultInputDevice() throws -> AudioObjectID {
        var address = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.stride)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &propertySize, &deviceID)
        guard status == kAudioHardwareNoError, deviceID != kAudioObjectUnknown else {
            throw CoreAudioRoutingError.propertyReadFailed("kAudioHardwarePropertyDefaultInputDevice", status)
        }
        return deviceID
    }
}
