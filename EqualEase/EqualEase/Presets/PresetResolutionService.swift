//
//  PresetResolutionService.swift
//  EqualEase
//

import Foundation

enum PresetResolutionSource: Equatable {
    case activeApp(bundleIdentifier: String, displayName: String)
    case selectedPreset
}

struct PresetResolution: Equatable {
    var preset: EQPreset
    var source: PresetResolutionSource
}

struct PresetResolutionService {
    static func resolve(
        selectedPresetID: String,
        outputDeviceUID: String?,
        activeApp: ForegroundAppIdentity?,
        presets: [EQPreset],
        devicePresetIDs: [String: String],
        appPresetIDs: [String: String]
    ) -> PresetResolution? {
        let presetsByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })

        // Device preset rules are intentionally paused for the first release.
        // Keep the persisted data/code paths around, but do not let them affect
        // the effective preset until the product model is redesigned as a
        // clearer base-device profile plus app/source overlay.
        _ = outputDeviceUID
        _ = devicePresetIDs

        if let activeApp,
           let presetID = appPresetIDs[activeApp.bundleIdentifier],
           let preset = presetsByID[presetID] {
            return PresetResolution(
                preset: preset,
                source: .activeApp(
                    bundleIdentifier: activeApp.bundleIdentifier,
                    displayName: activeApp.displayName
                )
            )
        }

        if let preset = presetsByID[selectedPresetID] {
            return PresetResolution(preset: preset, source: .selectedPreset)
        }

        return presets.first.map { PresetResolution(preset: $0, source: .selectedPreset) }
    }
}
