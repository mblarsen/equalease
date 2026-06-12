//
//  PresetResolutionService.swift
//  EqualEase
//

import Foundation

enum PresetResolutionSource: Equatable {
    case lockedPreset
    case activeWebsite(siteKey: String, displayName: String)
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
        activeWebsite: BrowserPageIdentity? = nil,
        presets: [EQPreset],
        devicePresetIDs: [String: String],
        appPresetIDs: [String: String],
        websitePresetIDs: [String: String] = [:],
        lockedPresetID: String? = nil
    ) -> PresetResolution? {
        let presetsByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })

        if let lockedPresetID,
           let preset = presetsByID[lockedPresetID] {
            return PresetResolution(preset: preset, source: .lockedPreset)
        }

        // Device preset rules are intentionally paused for the first release.
        // Keep the persisted data/code paths around, but do not let them affect
        // the effective preset until the product model is redesigned as a
        // clearer base-device profile plus app/source overlay.
        _ = outputDeviceUID
        _ = devicePresetIDs

        if let activeWebsite,
           let presetID = websitePresetIDs[activeWebsite.siteKey],
           let preset = presetsByID[presetID] {
            return PresetResolution(
                preset: preset,
                source: .activeWebsite(
                    siteKey: activeWebsite.siteKey,
                    displayName: activeWebsite.displayName
                )
            )
        }

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
