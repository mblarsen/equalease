//
//  AppPresetSuggestion.swift
//  EqualEase
//

import Foundation

struct AppPresetSuggestion: Equatable {
    var app: ForegroundAppIdentity
    var preset: EQPreset

    var title: String {
        "Remember \(preset.name) for \(app.displayName)?"
    }

    var explanation: String {
        "EqualEase can switch to this preset whenever \(app.displayName) becomes the active app, then return to your selected default preset when you switch away."
    }
}
