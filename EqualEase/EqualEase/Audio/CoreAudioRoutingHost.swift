//
//  CoreAudioRoutingHost.swift
//  EqualEase
//

import AudioToolbox
import CoreAudio
import Foundation

struct AudioOutputDeviceSnapshot: Equatable {
    var devices: [AudioOutputDevice]
    var defaultOutputDeviceUID: String?
}

struct AudioRouteStartConfiguration: Equatable {
    var selectedOutputDeviceUID: String?
    var isBypassed: Bool
    var outputGain: Double
    var equalizerEnabled: Bool
    var bandGains: [Double]
}

struct AudioRouteStartResult: Equatable {
    var outputDevice: AudioOutputDevice
}

struct AudioOutputVolumeState: Equatable {
    var canSetVolume: Bool
    var volume: Double?
}

struct AudioRoutingCleanupResult: Equatable {
    var destroyedTaps = 0
    var destroyedAggregates = 0

    var summary: String {
        if destroyedTaps == 0 && destroyedAggregates == 0 {
            return "No stale EqualEase audio objects found."
        }
        return "Cleaned up \(destroyedTaps) stale tap(s) and \(destroyedAggregates) aggregate device(s)."
    }
}

@MainActor
protocol CoreAudioRoutingHost: AnyObject {
    func loadOutputDevices() throws -> AudioOutputDeviceSnapshot
    func startRoute(configuration: AudioRouteStartConfiguration) throws -> AudioRouteStartResult
    func stopRoute()
    func cleanupOwnedAudioState(includeDevelopmentObjects: Bool) throws -> AudioRoutingCleanupResult

    func setBypassed(_ isBypassed: Bool)
    func setOutputGain(_ gain: Double)
    func setEqualizerEnabled(_ isEnabled: Bool)
    func setBandGain(_ gain: Double, at index: Int)

    func outputVolumeState(for outputDeviceUID: String?) -> AudioOutputVolumeState
    func setOutputVolume(_ volume: Double, for outputDeviceUID: String?)

    func observeOutputDevices(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation?
    func observeOutputVolume(for outputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation?
}

final class AudioRoutingObservation {
    private var cancellation: (() -> Void)?

    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func invalidate() {
        cancellation?()
        cancellation = nil
    }

    deinit {
        invalidate()
    }
}

@MainActor
final class ProductionCoreAudioRoutingHost: CoreAudioRoutingHost {
    private enum Names {
        static let currentTapName = "EqualEase System Audio Tap"
        static let sampleTapName = "Sample audio tap"
        static let currentAggregateName = "EqualEase Aggregate Audio Device"
        static let aggregateUIDPrefix = "boutique.code.EqualEase.routing.aggregate."

        static let ownedTapNames = [currentTapName]
        static let developmentCleanupTapNames = [currentTapName, sampleTapName]
        static let ownedAggregateNames = [currentAggregateName]
    }

    private struct HostOutputDevice {
        var id: AudioObjectID
        var device: AudioOutputDevice
        var sampleRate: Double
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private let loopback = CoreAudioLoopback()
    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    func loadOutputDevices() throws -> AudioOutputDeviceSnapshot {
        let defaultOutputDeviceID = try readDefaultOutputDevice()
        let defaultOutputDeviceUID = try readAudioObjectString(
            objectID: defaultOutputDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        )
        return AudioOutputDeviceSnapshot(
            devices: try readOutputDevices(),
            defaultOutputDeviceUID: defaultOutputDeviceUID
        )
    }

    func startRoute(configuration: AudioRouteStartConfiguration) throws -> AudioRouteStartResult {
        let ownProcessID = try findOwnAudioProcessID()
        let output = try selectedOutputDevice(uid: configuration.selectedOutputDeviceUID)

        tapID = try createExclusiveTap(excluding: ownProcessID)
        let tapUID = try readAudioObjectString(objectID: tapID, selector: kAudioTapPropertyUID)

        aggregateDeviceID = try createAggregateDevice()
        try add(uid: output.device.uid, to: aggregateDeviceID, selector: kAudioAggregateDevicePropertyFullSubDeviceList)
        try add(uid: tapUID, to: aggregateDeviceID, selector: kAudioAggregateDevicePropertyTapList)

        loopback.deviceID = aggregateDeviceID
        loopback.sampleRate = Float(output.sampleRate)
        setBypassed(configuration.isBypassed)
        setEqualizerEnabled(configuration.equalizerEnabled)
        setOutputGain(configuration.outputGain)
        for (index, gain) in configuration.bandGains.enumerated() {
            setBandGain(gain, at: index)
        }

        waitForAggregateDeviceReadiness(aggregateDeviceID)
        try startLoopbackWithRetry()
        return AudioRouteStartResult(outputDevice: output.device)
    }

    func stopRoute() {
        loopback.stop()
        destroyCurrentAggregate()
        destroyCurrentTap()
    }

    func cleanupOwnedAudioState(includeDevelopmentObjects: Bool) throws -> AudioRoutingCleanupResult {
        let tapNames = includeDevelopmentObjects ? Names.developmentCleanupTapNames : Names.ownedTapNames
        return try cleanupAudioState(tapNames: tapNames)
    }

    func setBypassed(_ isBypassed: Bool) {
        loopback.bypassed = isBypassed
    }

    func setOutputGain(_ gain: Double) {
        loopback.outputGain = Float(gain)
    }

    func setEqualizerEnabled(_ isEnabled: Bool) {
        loopback.equalizerEnabled = isEnabled
    }

    func setBandGain(_ gain: Double, at index: Int) {
        loopback.setBandGain(Float(gain), at: index)
    }

    func outputVolumeState(for outputDeviceUID: String?) -> AudioOutputVolumeState {
        guard let deviceID = try? selectedOutputDeviceID(uid: outputDeviceUID) else {
            return AudioOutputVolumeState(canSetVolume: false, volume: nil)
        }

        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        let scope = kAudioDevicePropertyScopeOutput
        let canSetVolume = audioObjectHasProperty(objectID: deviceID, selector: selector, scope: scope)
            && audioObjectIsPropertySettable(objectID: deviceID, selector: selector, scope: scope)
        let volume = try? readAudioObjectFloat32(objectID: deviceID, selector: selector, scope: scope)
        return AudioOutputVolumeState(
            canSetVolume: canSetVolume,
            volume: volume.map { min(max(Double($0), 0), 1) }
        )
    }

    func setOutputVolume(_ volume: Double, for outputDeviceUID: String?) {
        guard let deviceID = try? selectedOutputDeviceID(uid: outputDeviceUID) else { return }
        let clampedVolume = Float32(min(max(volume, 0), 1))
        try? writeAudioObjectFloat32(
            objectID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            value: clampedVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    func observeOutputDevices(_ onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        let queue = DispatchQueue.main
        var removals: [() -> Void] = []

        let defaultListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        var defaultOutputDeviceAddress = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultStatus = AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultOutputDeviceAddress, queue, defaultListener)
        if defaultStatus == kAudioHardwareNoError {
            removals.append { [systemObjectID] in
                var address = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, queue, defaultListener)
            }
        }

        let defaultSystemListener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        var defaultSystemOutputDeviceAddress = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let defaultSystemStatus = AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultSystemOutputDeviceAddress, queue, defaultSystemListener)
        if defaultSystemStatus == kAudioHardwareNoError {
            removals.append { [systemObjectID] in
                var address = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
                AudioObjectRemovePropertyListenerBlock(systemObjectID, &address, queue, defaultSystemListener)
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

        guard defaultStatus == kAudioHardwareNoError,
              defaultSystemStatus == kAudioHardwareNoError,
              devicesStatus == kAudioHardwareNoError
        else {
            removals.forEach { $0() }
            return nil
        }

        return AudioRoutingObservation {
            removals.forEach { $0() }
        }
    }

    func observeOutputVolume(for outputDeviceUID: String?, onChange: @escaping @MainActor () -> Void) -> AudioRoutingObservation? {
        guard let deviceID = try? selectedOutputDeviceID(uid: outputDeviceUID),
              audioObjectHasProperty(
                objectID: deviceID,
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput
              )
        else { return nil }

        let queue = DispatchQueue.main
        var outputVolumeAddress = coreAudioPropertyAddress(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &outputVolumeAddress, queue, listener)
        guard status == kAudioHardwareNoError else { return nil }

        return AudioRoutingObservation {
            var address = coreAudioPropertyAddress(
                kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioDevicePropertyScopeOutput
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
    }

    private func selectedOutputDevice(uid selectedOutputDeviceUID: String?) throws -> HostOutputDevice {
        let deviceID = try selectedOutputDeviceID(uid: selectedOutputDeviceUID)
        return try hostOutputDevice(id: deviceID)
    }

    private func selectedOutputDeviceID(uid selectedOutputDeviceUID: String?) throws -> AudioObjectID {
        let devices = try readAudioObjectIDs(selector: kAudioHardwarePropertyDevices)
        if let selectedOutputDeviceUID {
            for device in devices {
                let uid = try? readAudioObjectString(objectID: device, selector: kAudioDevicePropertyDeviceUID)
                if uid == selectedOutputDeviceUID {
                    return device
                }
            }
        }
        return try readDefaultOutputDevice()
    }

    private func hostOutputDevice(id deviceID: AudioObjectID) throws -> HostOutputDevice {
        let uid = try readAudioObjectString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
        let name = (try? readAudioObjectString(objectID: deviceID, selector: kAudioObjectPropertyName)) ?? uid
        let transport = (try? readAudioObjectUInt32(objectID: deviceID, selector: kAudioDevicePropertyTransportType))
            .map(AudioOutputTransport.init(coreAudioTransport:)) ?? .other
        let sampleRate = (try? readAudioObjectDouble(objectID: deviceID, selector: kAudioDevicePropertyNominalSampleRate)) ?? 48_000
        return HostOutputDevice(
            id: deviceID,
            device: AudioOutputDevice(uid: uid, name: name, transport: transport),
            sampleRate: sampleRate
        )
    }

    private func readOutputDevices() throws -> [AudioOutputDevice] {
        var devices: [AudioOutputDevice] = []
        for deviceID in try readAudioObjectIDs(selector: kAudioHardwarePropertyDevices) {
            guard isOutputDevice(deviceID) else { continue }
            guard let uid = try? readAudioObjectString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID) else { continue }
            let name = (try? readAudioObjectString(objectID: deviceID, selector: kAudioObjectPropertyName)) ?? uid
            guard !isEqualEaseOwnedAggregateDevice(name: name, uid: uid) else { continue }
            let transport = (try? readAudioObjectUInt32(objectID: deviceID, selector: kAudioDevicePropertyTransportType))
                .map(AudioOutputTransport.init(coreAudioTransport:)) ?? .other
            devices.append(AudioOutputDevice(uid: uid, name: name, transport: transport))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        (try? readAudioObjectIDs(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioDevicePropertyScopeOutput
        ).isEmpty == false) ?? false
    }

    private func isEqualEaseOwnedAggregateDevice(name: String, uid: String) -> Bool {
        Names.ownedAggregateNames.contains(name) || uid.hasPrefix(Names.aggregateUIDPrefix)
    }

    private func cleanupAudioState(tapNames: [String]) throws -> AudioRoutingCleanupResult {
        var result = AudioRoutingCleanupResult()

        for tap in try readAudioObjectIDs(selector: kAudioHardwarePropertyTapList) {
            let name = (try? readAudioObjectString(objectID: tap, selector: kAudioObjectPropertyName)) ?? ""
            if tapNames.contains(name) {
                let status = AudioHardwareDestroyProcessTap(tap)
                guard status == kAudioHardwareNoError else {
                    throw CoreAudioRoutingError.destroyTapFailed(name, status)
                }
                result.destroyedTaps += 1
            }
        }

        for device in try readAudioObjectIDs(selector: kAudioHardwarePropertyDevices) {
            let transport = try? readAudioObjectUInt32(objectID: device, selector: kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeAggregate else { continue }

            let name = (try? readAudioObjectString(objectID: device, selector: kAudioObjectPropertyName)) ?? ""
            let uid = (try? readAudioObjectString(objectID: device, selector: kAudioDevicePropertyDeviceUID)) ?? ""
            guard Names.ownedAggregateNames.contains(name) || uid.hasPrefix(Names.aggregateUIDPrefix) else { continue }

            let status = AudioHardwareDestroyAggregateDevice(device)
            guard status == kAudioHardwareNoError else {
                throw CoreAudioRoutingError.destroyAggregateFailed(name, status)
            }
            result.destroyedAggregates += 1
        }

        return result
    }

    private func findOwnAudioProcessID() throws -> AudioObjectID {
        let ownPID = getpid()
        let processIDs = try readAudioObjectIDs(selector: kAudioHardwarePropertyProcessObjectList)
        for processID in processIDs {
            if try readAudioObjectPID(objectID: processID) == ownPID {
                return processID
            }
        }
        throw CoreAudioRoutingError.missingOwnAudioProcess(ownPID)
    }

    private func createExclusiveTap(excluding ownProcessID: AudioObjectID) throws -> AudioObjectID {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessID])
        description.name = Names.currentTapName
        description.isPrivate = false
        description.isProcessRestoreEnabled = true
        description.muteBehavior = .muted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard status == kAudioHardwareNoError, createdTapID != kAudioObjectUnknown else {
            throw CoreAudioRoutingError.createTapFailed(status)
        }
        return createdTapID
    }

    private func createAggregateDevice() throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Names.currentAggregateName,
            kAudioAggregateDeviceUIDKey: "\(Names.aggregateUIDPrefix)\(UUID().uuidString)",
        ]

        var createdDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdDeviceID)
        guard status == kAudioHardwareNoError, createdDeviceID != kAudioObjectUnknown else {
            throw CoreAudioRoutingError.createAggregateFailed(status)
        }
        return createdDeviceID
    }

    private func destroyCurrentAggregate() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func destroyCurrentTap() {
        guard tapID != kAudioObjectUnknown else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func waitForAggregateDeviceReadiness(_ deviceID: AudioObjectID) {
        for _ in 0..<10 {
            let inputStreams = (try? readAudioObjectIDs(
                objectID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput
            )) ?? []
            let outputStreams = (try? readAudioObjectIDs(
                objectID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeOutput
            )) ?? []
            if !inputStreams.isEmpty && !outputStreams.isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func startLoopbackWithRetry() throws {
        for attempt in 1...4 {
            if loopback.start() {
                return
            }
            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        throw CoreAudioRoutingError.loopbackStartFailed(loopback.lastStartError)
    }

    private func add(
        uid: String,
        to aggregateDeviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws {
        var address = coreAudioPropertyAddress(selector)
        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &propertySize)
        guard status == kAudioHardwareNoError else {
            throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
        }

        var list: CFArray? = nil
        status = withUnsafeMutablePointer(to: &list) { pointer in
            AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &propertySize, pointer)
        }
        guard status == kAudioHardwareNoError else {
            throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
        }

        var values = (list as? [CFString] ?? []).map { $0 as String }
        if !values.contains(uid) {
            values.append(uid)
        }

        var updatedList = values as CFArray
        propertySize = UInt32(MemoryLayout<CFString>.stride * values.count)
        status = withUnsafeMutablePointer(to: &updatedList) { pointer in
            AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, propertySize, pointer)
        }
        guard status == kAudioHardwareNoError else {
            throw CoreAudioRoutingError.propertyWriteFailed(String(selector), status)
        }
    }
}

private extension AudioOutputTransport {
    init(coreAudioTransport: UInt32) {
        switch coreAudioTransport {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            self = .display
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            self = .usb
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeAggregate:
            self = .aggregate
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        default:
            self = .other
        }
    }
}
