//
//  EqualEaseSettings.swift
//  EqualEase
//

import Foundation

enum EqualEaseSettings {
    static let allowsExternalAutomationWritesKey = "allowsExternalAutomationWrites"
    static let localNetworkRemoteEnabledKey = "localNetworkRemoteEnabled"
    static let hasCompletedRoutingOnboardingKey = "hasCompletedRoutingOnboarding"
    static let startAudioRoutingAtLaunchKey = "startAudioRoutingAtLaunch"
    static let lockedPresetIDKey = "lockedPresetID"
    static let showsQuickPanelVolumeKey = "showsQuickPanelVolume"
    static let showsQuickPanelPreampKey = "showsQuickPanelPreamp"
    static let showsQuickPanelInputVolumeKey = "showsQuickPanelInputVolume"
    static let showsQuickPanelRoutingKey = "showsQuickPanelRouting"
    static let showsQuickPanelAppVolumeKey = "showsQuickPanelAppVolume"
    static let languageOverrideIdentifierKey = "languageOverrideIdentifier"
    static let ownsAppleLanguagesKey = "languageOverrideOwnsAppleLanguages"
    static let appleLanguagesKey = "AppleLanguages"

    static var allowsExternalAutomationWrites: Bool {
        get {
            guard UserDefaults.standard.object(forKey: allowsExternalAutomationWritesKey) != nil else {
                return false
            }
            return UserDefaults.standard.bool(forKey: allowsExternalAutomationWritesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: allowsExternalAutomationWritesKey)
        }
    }

    static var localNetworkRemoteEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: localNetworkRemoteEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: localNetworkRemoteEnabledKey)
        }
    }

    static var hasCompletedRoutingOnboarding: Bool {
        get {
            UserDefaults.standard.bool(forKey: hasCompletedRoutingOnboardingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hasCompletedRoutingOnboardingKey)
        }
    }

    static var startAudioRoutingAtLaunch: Bool {
        get {
            UserDefaults.standard.bool(forKey: startAudioRoutingAtLaunchKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: startAudioRoutingAtLaunchKey)
        }
    }

    static var shouldPresentRoutingOnboarding: Bool {
        !hasCompletedRoutingOnboarding
    }

    static var lockedPresetID: String? {
        get {
            UserDefaults.standard.string(forKey: lockedPresetIDKey)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: lockedPresetIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lockedPresetIDKey)
            }
        }
    }

    static var isPresetLocked: Bool {
        lockedPresetID != nil
    }

    static var languageOverrideIdentifier: String? {
        get {
            guard let identifier = UserDefaults.standard.string(forKey: languageOverrideIdentifierKey),
                  !identifier.isEmpty
            else { return nil }
            return identifier
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: languageOverrideIdentifierKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageOverrideIdentifierKey)
            }
        }
    }

    static var availableLanguageIdentifiers: [String] {
        let identifiers = Bundle.main.localizations
            .filter { $0 != "Base" }
        let preferred = identifiers.isEmpty ? ["en"] : identifiers
        return Array(Set(preferred)).sorted { localizedLanguageName(for: $0) < localizedLanguageName(for: $1) }
    }

    static func localizedLanguageName(for identifier: String, displayLocale: Locale = .current) -> String {
        displayLocale.localizedString(forIdentifier: identifier)
            ?? Locale(identifier: identifier).localizedString(forIdentifier: identifier)
            ?? identifier
    }

    static func applyStoredLanguageOverrideForLaunch() {
        guard let identifier = languageOverrideIdentifier else { return }
        applyLanguageOverrideForNextLaunch(identifier)
    }

    static func applyLanguageOverrideForNextLaunch(_ identifier: String?) {
        guard let identifier, availableLanguageIdentifiers.contains(identifier) else {
            clearLanguageOverrideForNextLaunch()
            return
        }

        languageOverrideIdentifier = identifier
        UserDefaults.standard.set(true, forKey: ownsAppleLanguagesKey)
        UserDefaults.standard.set([identifier], forKey: appleLanguagesKey)
    }

    static func clearLanguageOverrideForNextLaunch() {
        if UserDefaults.standard.bool(forKey: ownsAppleLanguagesKey) || languageOverrideIdentifier != nil {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
        }

        languageOverrideIdentifier = nil
        UserDefaults.standard.removeObject(forKey: ownsAppleLanguagesKey)
    }

    static var showsQuickPanelVolume: Bool {
        get {
            defaultTrueBool(forKey: showsQuickPanelVolumeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showsQuickPanelVolumeKey)
        }
    }

    static var showsQuickPanelPreamp: Bool {
        get {
            defaultTrueBool(forKey: showsQuickPanelPreampKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showsQuickPanelPreampKey)
        }
    }

    static var showsQuickPanelInputVolume: Bool {
        get {
            defaultTrueBool(forKey: showsQuickPanelInputVolumeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showsQuickPanelInputVolumeKey)
        }
    }

    static var showsQuickPanelRouting: Bool {
        get {
            defaultTrueBool(forKey: showsQuickPanelRoutingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showsQuickPanelRoutingKey)
        }
    }

    static var showsQuickPanelAppVolume: Bool {
        get {
            defaultTrueBool(forKey: showsQuickPanelAppVolumeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showsQuickPanelAppVolumeKey)
        }
    }

    private static func defaultTrueBool(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}
