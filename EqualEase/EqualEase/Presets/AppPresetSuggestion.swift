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
        String(
            localized: "Remember \(preset.name) for \(target.displayName)?",
            comment: "Smart-switching prompt title. First interpolation is a preset name; second is an app name or website host."
        )
    }

    var explanation: String {
        switch target {
        case let .app(app):
            String(
                localized: "EqualEase can switch to this preset whenever \(app.displayName) becomes the active app, then return to your selected default preset when you switch away.",
                comment: "Smart-switching prompt body for app rules. Interpolation is the active app name."
            )
        case let .website(page):
            String(
                localized: "EqualEase can switch to this preset whenever \(page.displayName) is the active website in a supported browser, then fall back to your app or default preset when you switch away.",
                comment: "Smart-switching prompt body for website rules. Interpolation is a website display name or host."
            )
        }
    }
}
