//
//  CoreAudioRouterLifecycleTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class CoreAudioRouterLifecycleTests: XCTestCase {
    func testDefaultInitializationDoesNotCleanUpAudioStateBeforeUserStartsRouting() {
        let host = TestRoutingHost()
        _ = CoreAudioRouter(host: host)

        XCTAssertEqual(host.cleanupRequests, [])
        XCTAssertEqual(host.startConfigurations.count, 0)
        XCTAssertEqual(host.stopCount, 0)
    }

    func testStartSuccessRoutesToSelectedOutput() {
        let host = TestRoutingHost()
        let router = CoreAudioRouter(host: host, restartDebounce: .milliseconds(10), cleanupOnLaunch: false)

        router.start()

        XCTAssertEqual(router.state, .running)
        XCTAssertTrue(router.isRunning)
        XCTAssertEqual(router.outputDeviceUID, host.speakers.uid)
        XCTAssertEqual(router.outputDeviceName, host.speakers.name)
        XCTAssertEqual(host.cleanupRequests, [false])
        XCTAssertEqual(host.startConfigurations.count, 1)
        XCTAssertEqual(host.startedOutputUIDs, [host.speakers.uid])
        XCTAssertTrue(router.statusText.contains("routing processed system audio"))
    }

    func testStartFailureReportsFailedStateAndStopsHostRoute() {
        let host = TestRoutingHost()
        host.startError = TestRoutingError.startFailed
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)

        router.start()

        XCTAssertEqual(router.state, .failed("Simulated route start failure."))
        XCTAssertFalse(router.isRunning)
        XCTAssertEqual(host.startConfigurations.count, 1)
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertTrue(router.statusText.contains("Could not start audio routing"))
    }

    func testStopStopsHostRouteAndReportsStopped() {
        let host = TestRoutingHost()
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)
        router.start()

        router.stop()

        XCTAssertEqual(router.state, .stopped)
        XCTAssertFalse(router.isRunning)
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(router.statusText, "Stopped")
    }

    func testSelectingOutputDisablesSystemFollowAndRestartsAfterDebounce() async throws {
        let host = TestRoutingHost()
        let router = CoreAudioRouter(host: host, restartDebounce: .milliseconds(20), cleanupOnLaunch: false)
        router.start()

        router.selectOutputDevice(uid: host.headphones.uid)

        XCTAssertFalse(router.followsSystemOutput)
        XCTAssertEqual(router.selectedOutputDeviceUID, host.headphones.uid)
        XCTAssertTrue(router.isRoutingTransitioning)
        XCTAssertEqual(host.startConfigurations.count, 1)

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(router.state, .running)
        XCTAssertFalse(router.isRoutingTransitioning)
        XCTAssertEqual(router.outputDeviceUID, host.headphones.uid)
        XCTAssertEqual(host.startedOutputUIDs, [host.speakers.uid, host.headphones.uid])
        XCTAssertEqual(host.stopCount, 1)
    }

    func testCleanupAudioStateStopsRouteAndReportsCleanupResult() {
        let host = TestRoutingHost()
        host.cleanupResult = AudioRoutingCleanupResult(destroyedTaps: 1, destroyedAggregates: 2)
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)
        router.start()

        router.cleanupAudioState()

        XCTAssertEqual(router.state, .stopped)
        XCTAssertEqual(host.stopCount, 1)
        XCTAssertEqual(host.cleanupRequests, [false, true])
        XCTAssertEqual(router.statusText, "Cleaned up 1 stale tap(s) and 2 aggregate device(s).")
    }

    func testSelectedOutputDisappearingWhileFollowingSystemOutputRestartsToDefaultOutput() async throws {
        let host = TestRoutingHost()
        let router = CoreAudioRouter(host: host, restartDebounce: .milliseconds(20), cleanupOnLaunch: false)
        router.start()

        host.devices = [host.headphones]
        host.defaultOutputDeviceUID = host.headphones.uid
        host.triggerOutputDevicesChanged()

        XCTAssertTrue(router.followsSystemOutput)
        XCTAssertEqual(router.selectedOutputDeviceUID, host.headphones.uid)
        XCTAssertTrue(router.isRoutingTransitioning)

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(router.state, .running)
        XCTAssertEqual(router.outputDeviceUID, host.headphones.uid)
        XCTAssertEqual(host.startedOutputUIDs, [host.speakers.uid, host.headphones.uid])
        XCTAssertEqual(host.stopCount, 1)
    }

    func testFollowSystemOutputIgnoresHiddenDefaultOutputUID() {
        let host = TestRoutingHost()
        host.defaultOutputDeviceUID = host.hiddenAggregate.uid
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)

        XCTAssertEqual(router.selectedOutputDeviceUID, host.speakers.uid)
        XCTAssertEqual(router.outputDeviceUID, host.speakers.uid)
        XCTAssertEqual(router.outputDeviceName, host.speakers.name)
    }

    func testSelectingUnknownOutputFallsBackToVisibleDefaultOutput() {
        let host = TestRoutingHost()
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)

        router.selectOutputDevice(uid: host.hiddenAggregate.uid)

        XCTAssertEqual(router.selectedOutputDeviceUID, host.speakers.uid)
        XCTAssertEqual(router.outputDeviceUID, host.speakers.uid)
    }

    func testOutputVolumeCapabilityWriteAndExternalRefresh() throws {
        let host = TestRoutingHost()
        host.volumeStates[host.speakers.uid] = AudioOutputVolumeState(canSetVolume: true, volume: 0.35)
        let router = CoreAudioRouter(host: host, cleanupOnLaunch: false)

        XCTAssertTrue(router.canSetOutputVolume)
        XCTAssertEqual(router.outputVolume, 0.35, accuracy: 0.001)

        router.outputVolume = 0.82

        XCTAssertEqual(try XCTUnwrap(host.writtenVolumes[host.speakers.uid]), 0.82, accuracy: 0.001)

        host.volumeStates[host.speakers.uid] = AudioOutputVolumeState(canSetVolume: true, volume: 0.44)
        host.triggerOutputVolumeChanged()

        XCTAssertEqual(router.outputVolume, 0.44, accuracy: 0.001)
    }

    func testOutputVolumeCapabilityRefreshesWhenSelectedOutputChanges() async throws {
        let host = TestRoutingHost()
        host.volumeStates[host.speakers.uid] = AudioOutputVolumeState(canSetVolume: true, volume: 0.5)
        host.volumeStates[host.headphones.uid] = AudioOutputVolumeState(canSetVolume: false, volume: nil)
        let router = CoreAudioRouter(host: host, restartDebounce: .milliseconds(10), cleanupOnLaunch: false)
        router.start()

        router.selectOutputDevice(uid: host.headphones.uid)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(router.canSetOutputVolume)
        XCTAssertEqual(router.outputDeviceUID, host.headphones.uid)
    }
}

private enum TestRoutingError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        switch self {
        case .startFailed:
            "Simulated route start failure."
        }
    }
}

@MainActor
private final class TestRoutingHost: CoreAudioRoutingHost {
    let speakers = AudioOutputDevice(uid: "speakers", name: "MacBook Speakers", transport: .builtIn)
    let headphones = AudioOutputDevice(uid: "headphones", name: "Desk Headphones", transport: .bluetooth)
    let hiddenAggregate = AudioOutputDevice(
        uid: "boutique.code.EqualEase.routing.aggregate.hidden",
        name: "EqualEase Aggregate Audio Device",
        transport: .aggregate
    )

    var devices: [AudioOutputDevice]
    var defaultOutputDeviceUID: String?
    var startError: Error?
    var cleanupError: Error?
    var cleanupResult = AudioRoutingCleanupResult()
    var volumeStates: [String: AudioOutputVolumeState] = [:]
    var writtenVolumes: [String: Double] = [:]
    var cleanupRequests: [Bool] = []
    var startConfigurations: [AudioRouteStartConfiguration] = []
    var startedOutputUIDs: [String] = []
    var stopCount = 0
    var bypassed = false
    var outputGain = 1.0
    var equalizerEnabled = false
    var bandGains = Array(repeating: 0.0, count: 10)

    private var outputDeviceChangeHandler: (@MainActor () -> Void)?
    private var outputVolumeChangeHandler: (@MainActor () -> Void)?

    init() {
        devices = [speakers, headphones]
        defaultOutputDeviceUID = speakers.uid
        volumeStates = [
            speakers.uid: AudioOutputVolumeState(canSetVolume: true, volume: 1.0),
            headphones.uid: AudioOutputVolumeState(canSetVolume: true, volume: 1.0),
        ]
    }

    func loadOutputDevices() throws -> AudioOutputDeviceSnapshot {
        AudioOutputDeviceSnapshot(devices: devices, defaultOutputDeviceUID: defaultOutputDeviceUID)
    }

    func startRoute(configuration: AudioRouteStartConfiguration) throws -> AudioRouteStartResult {
        startConfigurations.append(configuration)
        if let startError {
            throw startError
        }

        let requestedUID = configuration.selectedOutputDeviceUID
        let outputDevice = devices.first { $0.uid == requestedUID }
            ?? devices.first { $0.uid == defaultOutputDeviceUID }
            ?? speakers
        startedOutputUIDs.append(outputDevice.uid)
        bypassed = configuration.isBypassed
        outputGain = min(max(configuration.outputGain, 0), 2)
        equalizerEnabled = configuration.equalizerEnabled
        for (index, gain) in configuration.bandGains.enumerated() where bandGains.indices.contains(index) {
            bandGains[index] = min(max(gain, -12), 12)
        }
        return AudioRouteStartResult(outputDevice: outputDevice)
    }

    func stopRoute() {
        stopCount += 1
    }

    func cleanupOwnedAudioState(includeDevelopmentObjects: Bool) throws -> AudioRoutingCleanupResult {
        cleanupRequests.append(includeDevelopmentObjects)
        if let cleanupError {
            throw cleanupError
        }
        return cleanupResult
    }

    func setBypassed(_ isBypassed: Bool) {
        bypassed = isBypassed
    }

    func setOutputGain(_ gain: Double) {
        outputGain = min(max(gain, 0), 2)
    }

    func setEqualizerEnabled(_ isEnabled: Bool) {
        equalizerEnabled = isEnabled
    }

    func setBandGain(_ gain: Double, at index: Int) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = min(max(gain, -12), 12)
    }

    func outputVolumeState(for outputDeviceUID: String?) -> AudioOutputVolumeState {
        guard let uid = outputDeviceUID else {
            return AudioOutputVolumeState(canSetVolume: false, volume: nil)
        }
        return volumeStates[uid] ?? AudioOutputVolumeState(canSetVolume: false, volume: nil)
    }

    func setOutputVolume(_ volume: Double, for outputDeviceUID: String?) {
        guard let outputDeviceUID else { return }
        writtenVolumes[outputDeviceUID] = min(max(volume, 0), 1)
    }

    func observeOutputDevices(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        outputDeviceChangeHandler = onChange
        return AudioRoutingObservation { }
    }

    func observeOutputVolume(for outputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        outputVolumeChangeHandler = onChange
        return AudioRoutingObservation { }
    }

    func triggerOutputDevicesChanged() {
        outputDeviceChangeHandler?()
    }

    func triggerOutputVolumeChanged() {
        outputVolumeChangeHandler?()
    }
}
