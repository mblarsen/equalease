//
//  EqualEaseAppleScriptAdapter.swift
//  EqualEase
//

import AppKit
import Foundation

enum EqualEaseAppleScriptCommand {
    case listPresets
    case selectPreset
    case currentPresetName
    case setPreamp
    case currentPreamp
    case setOutputVolume
    case currentOutputVolume
    case setBypass
    case bypassState
    case toggleBypass
    case lockPreset
    case unlockPreset
    case presetLockState
    case togglePresetLock
}

enum EqualEaseAppleScriptAdapter {
    static func automationCommand(
        for appleScriptCommand: EqualEaseAppleScriptCommand,
        event: NSAppleEventDescriptor
    ) throws -> EqualEaseAutomationCommand {
        switch appleScriptCommand {
        case .listPresets:
            return .listPresets
        case .selectPreset:
            return .selectPreset(name: try directParameterString(from: event, fallbackAction: "select preset"))
        case .currentPresetName:
            return .currentPresetName
        case .setPreamp:
            return .setPreamp(rawValue: try directParameterString(from: event, fallbackAction: "set preamp level"))
        case .currentPreamp:
            return .currentPreamp
        case .setOutputVolume:
            return .setOutputVolume(rawValue: try directParameterString(from: event, fallbackAction: "set output volume"))
        case .currentOutputVolume:
            return .currentOutputVolume
        case .setBypass:
            return .setBypass(rawValue: try directParameterString(from: event, fallbackAction: "set bypass"))
        case .bypassState:
            return .bypassState
        case .toggleBypass:
            return .toggleBypass
        case .lockPreset:
            return .lockPreset(name: directParameterStringIfPresent(from: event))
        case .unlockPreset:
            return .unlockPreset
        case .presetLockState:
            return .presetLockState
        case .togglePresetLock:
            return .togglePresetLock
        }
    }

    static func setResult(_ result: EqualEaseAutomationResult, on replyEvent: NSAppleEventDescriptor) {
        switch result {
        case let .strings(values):
            let list = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() {
                list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
            }
            replyEvent.setParam(list, forKeyword: keyDirectObject)
        case let .string(value):
            replyEvent.setParam(NSAppleEventDescriptor(string: value), forKeyword: keyDirectObject)
        case let .number(value):
            replyEvent.setParam(NSAppleEventDescriptor(double: value), forKeyword: keyDirectObject)
        case let .boolean(value):
            replyEvent.setParam(NSAppleEventDescriptor(boolean: value), forKeyword: keyDirectObject)
        }
    }

    static func setError(_ error: Error, on replyEvent: NSAppleEventDescriptor) {
        // Do not use -1708 (errAEEventNotHandled) for validation failures.
        // AppleScript can treat that as a missing handler and cache confusing
        // "missing value" results for later custom commands in the same app.
        replyEvent.setParam(NSAppleEventDescriptor(int32: -10000), forKeyword: keyErrorNumber)
        replyEvent.setParam(NSAppleEventDescriptor(string: error.localizedDescription), forKeyword: keyErrorString)
    }

    private static func directParameterStringIfPresent(from event: NSAppleEventDescriptor) -> String? {
        guard let descriptor = event.paramDescriptor(forKeyword: keyDirectObject) else {
            return nil
        }

        if let stringValue = descriptor.stringValue, !stringValue.isEmpty {
            return stringValue
        }

        return descriptor.description
    }

    private static func directParameterString(
        from event: NSAppleEventDescriptor,
        fallbackAction: String
    ) throws -> String {
        guard let descriptor = event.paramDescriptor(forKeyword: keyDirectObject) else {
            throw EqualEaseAutomationError.missingValue(fallbackAction)
        }

        if let stringValue = descriptor.stringValue, !stringValue.isEmpty {
            return stringValue
        }

        return descriptor.description
    }
}
