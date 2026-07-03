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
    @Published private(set) var inputDeviceName = String(localized: "No input device", comment: "Input device fallback shown when macOS reports no microphone/input device.")
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
    @Published private(set) var lowVolumeProtectionStatus = String(localized: "Monitoring current input volume.", comment: "Microphone low-volume protection status while monitoring is healthy.")
    @Published private(set) var notificationAuthorizationStatus: InputVolumeProtectionNotificationStatus = .notRequested
    @Published private(set) var lastLowVolumeNotificationSummary = String(localized: "Never", comment: "Status value meaning an event has not happened yet.")
    @Published private(set) var lastCapAttemptSummary = String(localized: "Never", comment: "Status value meaning an event has not happened yet.")

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
        guard canReadInputVolume else {
            return String(localized: "Input volume summary: Unavailable", defaultValue: "Unavailable", comment: "Status value for unavailable input volume data.")
        }
        return String(
            localized: "\(Int(inputVolume * 100))%",
            comment: "Input volume percentage. Interpolation is an integer from 0 to 100."
        )
    }

    var inputVolumeCapabilitySummary: String {
        if canSetInputVolume {
            return String(localized: "Settable", comment: "Input volume capability: EqualEase can change this microphone volume.")
        }
        if canReadInputVolume {
            return String(localized: "Read-only", comment: "Input volume capability: EqualEase can read but not change this microphone volume.")
        }
        return String(localized: "Input volume capability: Unavailable", defaultValue: "Unavailable", comment: "Input volume capability: macOS does not expose this microphone volume.")
    }

    func refreshInputDevice() {
        do {
            let snapshot = try host.loadCurrentInputDevice()
            inputDeviceName = snapshot.device?.name
                ?? String(localized: "No input device", comment: "Input device fallback shown when macOS reports no microphone/input device.")
            inputDeviceUID = snapshot.device?.uid
            startCurrentInputVolumeObservation()
            refreshCurrentInputVolume()
        } catch {
            inputDeviceName = String(localized: "No input device", comment: "Input device fallback shown when macOS reports no microphone/input device.")
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
            lowVolumeProtectionStatus = String(localized: "Low-volume detection unavailable for this input device.", comment: "Microphone protection status when EqualEase cannot read the current input volume.")
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
            lowVolumeProtectionStatus = String(localized: "Low-volume detection unavailable for this input device.", comment: "Microphone protection status when EqualEase cannot read the current input volume.")
            return
        }

        let settings = protectionSettings.normalized
        let currentDate = now()
        let currentVolume = inputVolume
        let isLow = currentVolume < settings.threshold
        isInputVolumeLow = isLow

        guard isLow else {
            notificationPolicy.recordHealthyVolume(at: currentDate)
            lowVolumeProtectionStatus = String(localized: "Input volume is OK.", comment: "Microphone protection status when the input volume is above the low-volume threshold.")
            return
        }

        notificationPolicy.recordLowVolume(at: currentDate)

        if settings.capEnabled {
            attemptCapIfNeeded(settings: settings, currentVolume: currentVolume)
        } else if !canSetInputVolume {
            lowVolumeProtectionStatus = String(localized: "Input volume is low; automatic capping is unavailable for this device.", comment: "Microphone protection status when volume is low and EqualEase cannot automatically raise this device.")
        } else {
            lowVolumeProtectionStatus = String(localized: "Input volume is low.", comment: "Microphone protection status when the current input volume is below the configured threshold.")
        }

        if settings.notificationsEnabled,
           !isLowVolumeNotificationInFlight,
           notificationPolicy.shouldNotify(at: currentDate) {
            postLowVolumeNotification(volume: currentVolume, threshold: settings.threshold, currentDate: currentDate)
        }
    }

    private func attemptCapIfNeeded(settings: InputVolumeProtectionSettings, currentVolume: Double) {
        guard canSetInputVolume else {
            lowVolumeProtectionStatus = String(localized: "Input volume is low; automatic capping is unavailable for this device.", comment: "Microphone protection status when volume is low and EqualEase cannot automatically raise this device.")
            lastCapAttemptSummary = String(localized: "Skipped: input volume is read-only or unavailable", comment: "Microphone protection cap-attempt summary when input volume cannot be changed.")
            return
        }
        guard settings.capMinimum > currentVolume else { return }
        let currentDate = now()
        if let lastCapAttemptDate, currentDate.timeIntervalSince(lastCapAttemptDate) < capAttemptInterval {
            lowVolumeProtectionStatus = String(localized: "Input volume is low; cap attempt is rate-limited.", comment: "Microphone protection status when EqualEase recently tried to raise input volume and is waiting before retrying.")
            return
        }
        lastCapAttemptDate = currentDate
        let capSucceeded = host.setInputVolume(settings.capMinimum, for: inputDeviceUID)
        if capSucceeded {
            isRefreshingInputVolume = true
            inputVolume = settings.capMinimum
            isRefreshingInputVolume = false
            isInputVolumeLow = inputVolume < settings.threshold
            lastCapAttemptSummary = String(
                localized: "Raised to \(Int(settings.capMinimum * 100))%",
                comment: "Microphone protection cap-attempt summary. Interpolation is the configured minimum input volume percentage."
            )
            lowVolumeProtectionStatus = String(
                localized: "Input volume was low and EqualEase raised it to \(Int(settings.capMinimum * 100))%.",
                comment: "Microphone protection status after automatically raising input volume. Interpolation is the configured minimum percentage."
            )
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.refreshCurrentInputVolume()
            }
        } else {
            lastCapAttemptSummary = String(localized: "Failed to set input volume", comment: "Microphone protection cap-attempt summary when setting input volume failed.")
            lowVolumeProtectionStatus = String(localized: "Input volume is low; EqualEase could not set this device's input volume.", comment: "Microphone protection status when an automatic cap attempt failed.")
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
            lastLowVolumeNotificationSummary = posted
                ? String(
                    localized: "Posted at \(Self.shortTimeFormatter.string(from: now()))",
                    comment: "Microphone protection notification summary. Interpolation is a localized time."
                )
                : String(
                    localized: "Unavailable: \(notificationAuthorizationStatus.summary)",
                    comment: "Microphone protection notification summary when notifications cannot be posted. Interpolation is a notification permission status."
                )
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
