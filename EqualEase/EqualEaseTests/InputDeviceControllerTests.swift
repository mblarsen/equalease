//
//  InputDeviceControllerTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class InputDeviceControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearProtectionSettings()
    }

    override func tearDown() {
        clearProtectionSettings()
        super.tearDown()
    }

    func testCurrentInputDeviceNameReportsAndUpdatesDefaultInputChanges() {
        let host = TestInputDeviceControlHost()
        let controller = InputDeviceController(host: host)

        XCTAssertEqual(controller.inputDeviceName, "Built-in Microphone")
        XCTAssertEqual(controller.inputDeviceUID, "built-in-mic")

        host.currentDevice = host.usbMicrophone
        host.triggerInputDeviceChanged()

        XCTAssertEqual(controller.inputDeviceName, "USB Microphone")
        XCTAssertEqual(controller.inputDeviceUID, "usb-mic")
    }

    func testNoInputDeviceReportsUnavailableInputState() {
        let host = TestInputDeviceControlHost()
        let controller = InputDeviceController(host: host)

        host.currentDevice = nil
        host.triggerInputDeviceChanged()

        XCTAssertEqual(controller.inputDeviceName, "No input device")
        XCTAssertNil(controller.inputDeviceUID)
        XCTAssertFalse(controller.canReadInputVolume)
        XCTAssertFalse(controller.canSetInputVolume)
        XCTAssertEqual(controller.inputVolumeSummary, "Unavailable")
        XCTAssertEqual(controller.inputVolumeCapabilitySummary, "Unavailable")
    }

    func testReadableSettableInputVolumeWritesThroughHost() throws {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.35)
        let controller = InputDeviceController(host: host)

        XCTAssertTrue(controller.canReadInputVolume)
        XCTAssertTrue(controller.canSetInputVolume)
        XCTAssertEqual(controller.inputVolume, 0.35, accuracy: 0.001)
        XCTAssertEqual(controller.inputVolumeSummary, "35%")
        XCTAssertEqual(controller.inputVolumeCapabilitySummary, "Settable")

        controller.inputVolume = 0.82

        XCTAssertEqual(try XCTUnwrap(host.writtenVolumes[host.builtInMicrophone.uid]), 0.82, accuracy: 0.001)
        XCTAssertEqual(controller.inputVolume, 0.82, accuracy: 0.001)
    }

    func testUnavailableInputVolumeDisablesWrites() {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = .unavailable
        let controller = InputDeviceController(host: host)

        XCTAssertFalse(controller.canReadInputVolume)
        XCTAssertFalse(controller.canSetInputVolume)
        XCTAssertEqual(controller.inputVolumeSummary, "Unavailable")

        controller.inputVolume = 0.7

        XCTAssertTrue(host.writtenVolumes.isEmpty)
    }

    func testReadableButUnsettableInputVolumeIsReadOnly() {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: false, volume: 0.44)
        let controller = InputDeviceController(host: host)

        XCTAssertTrue(controller.canReadInputVolume)
        XCTAssertFalse(controller.canSetInputVolume)
        XCTAssertEqual(controller.inputVolume, 0.44, accuracy: 0.001)
        XCTAssertEqual(controller.inputVolumeCapabilitySummary, "Read-only")

        controller.inputVolume = 0.9

        XCTAssertTrue(host.writtenVolumes.isEmpty)
    }

    func testExternalInputVolumeRefreshUpdatesController() {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.25)
        let controller = InputDeviceController(host: host)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.61)
        host.triggerInputVolumeChanged()

        XCTAssertEqual(controller.inputVolume, 0.61, accuracy: 0.001)
        XCTAssertTrue(controller.canSetInputVolume)
    }

    func testLowVolumeThresholdCrossingAndRecovery() {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.5)
        let controller = InputDeviceController(host: host, notifier: TestInputVolumeProtectionNotifier())
        controller.protectionSettings.threshold = 0.35

        XCTAssertFalse(controller.isInputVolumeLow)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.2)
        host.triggerInputVolumeChanged()

        XCTAssertTrue(controller.isInputVolumeLow)
        XCTAssertEqual(controller.lowVolumeProtectionStatus, "Input volume is low.")

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.4)
        host.triggerInputVolumeChanged()

        XCTAssertFalse(controller.isInputVolumeLow)
        XCTAssertEqual(controller.lowVolumeProtectionStatus, "Input volume is OK.")
    }

    func testNotificationBackoffGrowsExponentiallyAndCapsAtOneMinute() async {
        let host = TestInputDeviceControlHost()
        let notifier = TestInputVolumeProtectionNotifier()
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = InputDeviceController(
            host: host,
            notifier: notifier,
            now: { currentTime },
            notificationPolicy: InputVolumeProtectionNotificationPolicy(initialBackoff: 5, maximumBackoff: 60, recoveryGracePeriod: 5 * 60)
        )
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.5, notificationsEnabled: true, capEnabled: false)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 1)

        currentTime = currentTime.addingTimeInterval(4)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 1)

        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 2)

        currentTime = currentTime.addingTimeInterval(9)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 2)

        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 3)

        currentTime = currentTime.addingTimeInterval(20)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 4)

        currentTime = currentTime.addingTimeInterval(40)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 5)

        currentTime = currentTime.addingTimeInterval(59)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 5)

        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 6)

        currentTime = currentTime.addingTimeInterval(60)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 7)
    }

    func testNotificationBackoffSurvivesBriefRecoveryAndResetsAfterFiveHealthyMinutes() async {
        let host = TestInputDeviceControlHost()
        let notifier = TestInputVolumeProtectionNotifier()
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = InputDeviceController(
            host: host,
            notifier: notifier,
            now: { currentTime },
            notificationPolicy: InputVolumeProtectionNotificationPolicy(initialBackoff: 5, maximumBackoff: 60, recoveryGracePeriod: 5 * 60)
        )
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.5, notificationsEnabled: true, capEnabled: false)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 1)

        currentTime = currentTime.addingTimeInterval(5)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 2)

        currentTime = currentTime.addingTimeInterval(10)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 3)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.5)
        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 3)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.5)
        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        currentTime = currentTime.addingTimeInterval(5 * 60)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 4)
    }

    func testFailedNotificationDoesNotAdvanceBackoff() async {
        let host = TestInputDeviceControlHost()
        let notifier = TestInputVolumeProtectionNotifier()
        notifier.status = .denied
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = InputDeviceController(
            host: host,
            notifier: notifier,
            now: { currentTime },
            notificationPolicy: InputVolumeProtectionNotificationPolicy(initialBackoff: 5, maximumBackoff: 60, recoveryGracePeriod: 5 * 60)
        )
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.5, notificationsEnabled: true, capEnabled: false)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.attemptedNotifications, 1)
        XCTAssertEqual(notifier.postedNotifications.count, 0)

        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.attemptedNotifications, 2)
        XCTAssertEqual(notifier.postedNotifications.count, 0)
    }

    func testInFlightNotificationPreventsDuplicateSendsBeforeCompletion() async {
        let host = TestInputDeviceControlHost()
        let notifier = TestInputVolumeProtectionNotifier()
        notifier.shouldBlockPost = true
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = InputDeviceController(
            host: host,
            notifier: notifier,
            now: { currentTime },
            notificationPolicy: InputVolumeProtectionNotificationPolicy(initialBackoff: 5, maximumBackoff: 60, recoveryGracePeriod: 5 * 60)
        )
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.5, notificationsEnabled: true, capEnabled: false)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.3)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.attemptedNotifications, 1)

        currentTime = currentTime.addingTimeInterval(1)
        host.triggerInputVolumeChanged()
        await Task.yield()
        XCTAssertEqual(notifier.attemptedNotifications, 1)

        notifier.resumeBlockedPost(result: true)
        await Task.yield()
        XCTAssertEqual(notifier.postedNotifications.count, 1)
    }

    func testMinimumCapRaisesSettableInputVolumeAndIsRateLimited() throws {
        let host = TestInputDeviceControlHost()
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = InputDeviceController(host: host, notifier: TestInputVolumeProtectionNotifier(), now: { currentTime }, capAttemptInterval: 60)
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.55, notificationsEnabled: false, capEnabled: true)

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.2)
        host.triggerInputVolumeChanged()

        XCTAssertEqual(try XCTUnwrap(host.writtenVolumes[host.builtInMicrophone.uid]), 0.55, accuracy: 0.001)
        XCTAssertEqual(controller.lastCapAttemptSummary, "Raised to 55%")

        host.volumeStates[host.builtInMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.1)
        currentTime = currentTime.addingTimeInterval(10)
        host.triggerInputVolumeChanged()

        XCTAssertEqual(host.writeCount, 1)
        XCTAssertEqual(controller.lowVolumeProtectionStatus, "Input volume is low; cap attempt is rate-limited.")
    }

    func testCapSkippedForUnsettableDeviceWithClearStatus() {
        let host = TestInputDeviceControlHost()
        host.currentDevice = host.usbMicrophone
        host.volumeStates[host.usbMicrophone.uid] = AudioInputVolumeState(canReadVolume: true, canSetVolume: false, volume: 0.2)
        let controller = InputDeviceController(host: host, notifier: TestInputVolumeProtectionNotifier())
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.55, notificationsEnabled: false, capEnabled: true)

        XCTAssertTrue(controller.isInputVolumeLow)
        XCTAssertTrue(host.writtenVolumes.isEmpty)
        XCTAssertEqual(controller.lowVolumeProtectionStatus, "Input volume is low; automatic capping is unavailable for this device.")
        XCTAssertEqual(controller.lastCapAttemptSummary, "Skipped: input volume is read-only or unavailable")
    }

    func testUnreadableDeviceReportsDetectionUnavailable() {
        let host = TestInputDeviceControlHost()
        host.volumeStates[host.builtInMicrophone.uid] = .unavailable
        let controller = InputDeviceController(host: host, notifier: TestInputVolumeProtectionNotifier())
        controller.protectionSettings = InputVolumeProtectionSettings(threshold: 0.4, capMinimum: 0.55, notificationsEnabled: true, capEnabled: true)

        XCTAssertFalse(controller.isInputVolumeLow)
        XCTAssertEqual(controller.lowVolumeProtectionStatus, "Low-volume detection unavailable for this input device.")
    }

    func testProtectionSettingsPersist() {
        let settings = InputVolumeProtectionSettings(threshold: 0.25, capMinimum: 0.6, notificationsEnabled: true, capEnabled: true)
        InputVolumeProtectionSettingsStore.save(settings)

        let restored = InputVolumeProtectionSettingsStore.load()

        XCTAssertEqual(restored, settings)
    }

    private func clearProtectionSettings() {
        UserDefaults.standard.removeObject(forKey: InputVolumeProtectionSettingsStore.thresholdKey)
        UserDefaults.standard.removeObject(forKey: InputVolumeProtectionSettingsStore.capMinimumKey)
        UserDefaults.standard.removeObject(forKey: InputVolumeProtectionSettingsStore.notificationsEnabledKey)
        UserDefaults.standard.removeObject(forKey: InputVolumeProtectionSettingsStore.capEnabledKey)
    }
}

@MainActor
final class TestInputDeviceControlHost: InputDeviceControlHost {
    let builtInMicrophone = AudioInputDevice(uid: "built-in-mic", name: "Built-in Microphone")
    let usbMicrophone = AudioInputDevice(uid: "usb-mic", name: "USB Microphone")

    var currentDevice: AudioInputDevice?
    var volumeStates: [String: AudioInputVolumeState] = [:]
    var writtenVolumes: [String: Double] = [:]
    var writeCount = 0

    private var inputDeviceChangeHandler: (@MainActor () -> Void)?
    private var inputVolumeChangeHandler: (@MainActor () -> Void)?

    init() {
        currentDevice = builtInMicrophone
        volumeStates = [
            builtInMicrophone.uid: AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.5),
            usbMicrophone.uid: AudioInputVolumeState(canReadVolume: true, canSetVolume: false, volume: 0.75),
        ]
    }

    func loadCurrentInputDevice() throws -> AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(device: currentDevice)
    }

    func inputVolumeState(for inputDeviceUID: String?) -> AudioInputVolumeState {
        guard let inputDeviceUID else { return .unavailable }
        return volumeStates[inputDeviceUID] ?? .unavailable
    }

    func setInputVolume(_ volume: Double, for inputDeviceUID: String?) -> Bool {
        guard let inputDeviceUID else { return false }
        let clampedVolume = min(max(volume, 0), 1)
        writeCount += 1
        writtenVolumes[inputDeviceUID] = clampedVolume
        volumeStates[inputDeviceUID] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: clampedVolume)
        return true
    }

    func observeInputDeviceChanges(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        inputDeviceChangeHandler = onChange
        return AudioRoutingObservation { }
    }

    func observeInputVolume(for inputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        inputVolumeChangeHandler = onChange
        return AudioRoutingObservation { }
    }

    func triggerInputDeviceChanged() {
        inputDeviceChangeHandler?()
    }

    func triggerInputVolumeChanged() {
        inputVolumeChangeHandler?()
    }
}

@MainActor
final class TestInputVolumeProtectionNotifier: InputVolumeProtectionNotifying {
    var status: InputVolumeProtectionNotificationStatus = .authorized
    var shouldBlockPost = false
    var attemptedNotifications = 0
    var postedNotifications: [(deviceName: String, volume: Double, threshold: Double)] = []

    private var blockedPostContinuation: CheckedContinuation<Bool, Never>?

    func refreshAuthorizationStatus() async -> InputVolumeProtectionNotificationStatus {
        status
    }

    func requestAuthorization() async -> InputVolumeProtectionNotificationStatus {
        status = .authorized
        return status
    }

    func postLowInputVolumeNotification(deviceName: String, volume: Double, threshold: Double) async -> Bool {
        attemptedNotifications += 1
        if shouldBlockPost {
            let posted = await withCheckedContinuation { continuation in
                blockedPostContinuation = continuation
            }
            if posted {
                postedNotifications.append((deviceName: deviceName, volume: volume, threshold: threshold))
            }
            return posted
        }
        guard status == .authorized else { return false }
        postedNotifications.append((deviceName: deviceName, volume: volume, threshold: threshold))
        return true
    }

    func resumeBlockedPost(result: Bool) {
        shouldBlockPost = false
        blockedPostContinuation?.resume(returning: result)
        blockedPostContinuation = nil
    }
}
