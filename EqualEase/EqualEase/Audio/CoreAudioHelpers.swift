//
//  CoreAudioHelpers.swift
//  EqualEase
//

import AppKit
import CoreAudio

func coreAudioPropertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

enum CoreAudioRoutingError: LocalizedError {
    case propertyReadFailed(String, OSStatus)
    case propertyWriteFailed(String, OSStatus)
    case createTapFailed(OSStatus)
    case createAggregateFailed(OSStatus)
    case destroyTapFailed(String, OSStatus)
    case destroyAggregateFailed(String, OSStatus)
    case missingOwnAudioProcess(pid_t)
    case missingDefaultOutputDevice
    case missingDeviceUID(AudioObjectID)
    case loopbackStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .propertyReadFailed(name, status):
            "Could not read Core Audio property \(name) (status \(status))."
        case let .propertyWriteFailed(name, status):
            "Could not write Core Audio property \(name) (status \(status))."
        case let .createTapFailed(status):
            "Could not create Core Audio process tap (status \(status))."
        case let .createAggregateFailed(status):
            "Could not create aggregate device (status \(status))."
        case let .destroyTapFailed(name, status):
            "Could not clean up Core Audio tap \(name) (status \(status))."
        case let .destroyAggregateFailed(name, status):
            "Could not clean up aggregate device \(name) (status \(status))."
        case let .missingOwnAudioProcess(pid):
            "Could not find EqualEase's Core Audio process object for pid \(pid)."
        case .missingDefaultOutputDevice:
            "Could not find the current default output device."
        case let .missingDeviceUID(deviceID):
            "Could not read device UID for Core Audio device \(deviceID)."
        case let .loopbackStartFailed(status):
            "Could not start audio loopback IO (status \(status))."
        }
    }
}

func audioObjectHasProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> Bool {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    return AudioObjectHasProperty(objectID, &address)
}

func audioObjectIsPropertySettable(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> Bool {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    var isSettable: DarwinBoolean = false
    let status = AudioObjectIsPropertySettable(objectID, &address, &isSettable)
    return status == kAudioHardwareNoError && isSettable.boolValue
}

func readAudioObjectFloat32(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> Float32 {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    var propertySize = UInt32(MemoryLayout<Float32>.stride)
    var value: Float32 = 0
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &value)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }
    return value
}

func writeAudioObjectFloat32(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    value: Float32,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    var writableValue = value
    let status = AudioObjectSetPropertyData(
        objectID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<Float32>.stride),
        &writableValue
    )
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyWriteFailed(String(selector), status)
    }
}

func readAudioObjectDouble(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> Double {
    var address = coreAudioPropertyAddress(selector)
    var propertySize = UInt32(MemoryLayout<Double>.stride)
    var value: Double = 0
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &value)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }
    return value
}

func readAudioObjectUInt32(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> UInt32 {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    var propertySize = UInt32(MemoryLayout<UInt32>.stride)
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &value)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }
    return value
}

func readAudioObjectIDs(
    objectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws -> [AudioObjectID] {
    var address = coreAudioPropertyAddress(selector, scope: scope)
    var propertySize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }

    let count = Int(propertySize) / MemoryLayout<AudioObjectID>.stride
    var values = [AudioObjectID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &values)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }
    return values
}

func readAudioObjectString(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var address = coreAudioPropertyAddress(selector)
    var propertySize = UInt32(MemoryLayout<CFString>.stride)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, pointer)
    }
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed(String(selector), status)
    }
    return value as String
}

func readAudioObjectPID(objectID: AudioObjectID) throws -> pid_t {
    var address = coreAudioPropertyAddress(kAudioProcessPropertyPID)
    var propertySize = UInt32(MemoryLayout<pid_t>.stride)
    var pid: pid_t = 0
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &pid)
    guard status == kAudioHardwareNoError else {
        throw CoreAudioRoutingError.propertyReadFailed("kAudioProcessPropertyPID", status)
    }
    return pid
}

func readDefaultOutputDevice() throws -> AudioObjectID {
    var address = coreAudioPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var propertySize = UInt32(MemoryLayout<AudioObjectID>.stride)
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID)
    guard status == kAudioHardwareNoError, deviceID != kAudioObjectUnknown else {
        throw CoreAudioRoutingError.missingDefaultOutputDevice
    }
    return deviceID
}

func processName(pid: pid_t) -> String {
    for app in NSWorkspace.shared.runningApplications where app.processIdentifier == pid {
        return app.localizedName ?? "pid \(pid)"
    }
    return "pid \(pid)"
}
