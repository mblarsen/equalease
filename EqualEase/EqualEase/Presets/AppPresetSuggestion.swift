//
//  AppPresetSuggestion.swift
//  EqualEase
//

import Foundation

enum PresetLearningTarget: Equatable {
    case app(ForegroundAppIdentity)
    case website(BrowserPageIdentity)

    var storageKey: String {
        switch self {
        case let .app(app):
            "app:\(app.bundleIdentifier)"
        case let .website(page):
            "website:\(page.siteKey)"
        }
    }

    var displayName: String {
        switch self {
        case let .app(app):
            app.displayName
        case let .website(page):
            page.displayName
        }
    }
}

struct AppPresetSuggestion: Equatable {
    var target: PresetLearningTarget
    var preset: EQPreset

    var title: String {
        "Remember \(preset.name) for \(target.displayName)?"
    }

    var explanation: String {
        switch target {
        case let .app(app):
            "EqualEase can switch to this preset whenever \(app.displayName) becomes the active app, then return to your selected default preset when you switch away."
        case let .website(page):
            "EqualEase can switch to this preset whenever \(page.displayName) is the active website in a supported browser, then fall back to your app or default preset when you switch away."
        }
    }
}
