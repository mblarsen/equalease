#!/usr/bin/env swift
import CoreAudio
import Foundation

let destroy = CommandLine.arguments.contains("--destroy")
let includeSample = CommandLine.arguments.contains("--include-sample")

let ownedTapNames = [
    "EqualEase System Audio Tap",
]
let developmentTapNames = ownedTapNames + ["Sample audio tap"]
let ownedAggregateNames = [
    "EqualEase Aggregate Audio Device",
]
let aggregateUIDPrefix = "boutique.code.EqualEase.routing.aggregate."

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readIDs(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var propertyAddress = address(selector)
    var propertySize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize
    )
    guard status == kAudioHardwareNoError else {
        print("Could not read property size for \(selector): \(status)")
        return []
    }

    var ids = [AudioObjectID](repeating: 0, count: Int(propertySize) / MemoryLayout<AudioObjectID>.stride)
    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &ids
    )
    guard status == kAudioHardwareNoError else {
        print("Could not read object IDs for \(selector): \(status)")
        return []
    }
    return ids
}

func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var propertyAddress = address(selector)
    var propertySize = UInt32(MemoryLayout<CFString>.stride)
    var value: CFString = "" as CFString
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, pointer)
    }
    return status == kAudioHardwareNoError ? value as String : "<status \(status)>"
}

func readUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var propertyAddress = address(selector)
    var propertySize = UInt32(MemoryLayout<UInt32>.stride)
    var value: UInt32 = 0
    let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &value)
    return status == kAudioHardwareNoError ? value : nil
}

let tapNames = includeSample ? developmentTapNames : ownedTapNames
var matchingTaps: [(AudioObjectID, String, String)] = []
for tap in readIDs(kAudioHardwarePropertyTapList) {
    let name = readString(tap, kAudioObjectPropertyName)
    let uid = readString(tap, kAudioTapPropertyUID)
    if tapNames.contains(name) {
        matchingTaps.append((tap, name, uid))
    }
}

var matchingAggregates: [(AudioObjectID, String, String)] = []
for device in readIDs(kAudioHardwarePropertyDevices) {
    guard readUInt32(device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { continue }
    let name = readString(device, kAudioObjectPropertyName)
    let uid = readString(device, kAudioDevicePropertyDeviceUID)
    if ownedAggregateNames.contains(name) || uid.hasPrefix(aggregateUIDPrefix) {
        matchingAggregates.append((device, name, uid))
    }
}

print("EqualEase audio routing cleanup")
print(destroy ? "Mode: destroy" : "Mode: dry-run; pass --destroy to remove matches")
if includeSample {
    print("Including Apple sample tap cleanup")
}

print("\nMatching taps:")
if matchingTaps.isEmpty {
    print("- none")
}
for (tap, name, uid) in matchingTaps {
    print("- \(tap): \(name) uid=\(uid)")
    if destroy {
        print("  destroy status: \(AudioHardwareDestroyProcessTap(tap))")
    }
}

print("\nMatching aggregate devices:")
if matchingAggregates.isEmpty {
    print("- none")
}
for (device, name, uid) in matchingAggregates {
    print("- \(device): \(name) uid=\(uid)")
    if destroy {
        print("  destroy status: \(AudioHardwareDestroyAggregateDevice(device))")
    }
}
