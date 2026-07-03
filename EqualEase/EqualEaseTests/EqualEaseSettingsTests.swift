//
//  EqualEaseSettingsTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class EqualEaseSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.allowsExternalAutomationWritesKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.localNetworkRemoteEnabledKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.hasCompletedRoutingOnboardingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.startAudioRoutingAtLaunchKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.lockedPresetIDKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelPreampKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelInputVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelRoutingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelAppVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.languageOverrideIdentifierKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.ownsAppleLanguagesKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.appleLanguagesKey)
        super.tearDown()
    }

    func testExternalAutomationWritesDefaultOff() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.allowsExternalAutomationWritesKey)

        XCTAssertFalse(EqualEaseSettings.allowsExternalAutomationWrites)
    }

    func testExternalAutomationWritesPersistEnabledState() {
        EqualEaseSettings.allowsExternalAutomationWrites = true
        XCTAssertTrue(EqualEaseSettings.allowsExternalAutomationWrites)

        EqualEaseSettings.allowsExternalAutomationWrites = false
        XCTAssertFalse(EqualEaseSettings.allowsExternalAutomationWrites)
    }

    func testLocalNetworkRemoteDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.localNetworkRemoteEnabledKey)

        XCTAssertFalse(EqualEaseSettings.localNetworkRemoteEnabled)
    }

    func testLocalNetworkRemotePersistsEnabledState() {
        EqualEaseSettings.localNetworkRemoteEnabled = true
        XCTAssertTrue(EqualEaseSettings.localNetworkRemoteEnabled)

        EqualEaseSettings.localNetworkRemoteEnabled = false
        XCTAssertFalse(EqualEaseSettings.localNetworkRemoteEnabled)
    }

    func testRoutingOnboardingDefaultsToRequiredAndLaunchRestoreDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.hasCompletedRoutingOnboardingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.startAudioRoutingAtLaunchKey)

        XCTAssertTrue(EqualEaseSettings.shouldPresentRoutingOnboarding)
        XCTAssertFalse(EqualEaseSettings.hasCompletedRoutingOnboarding)
        XCTAssertFalse(EqualEaseSettings.startAudioRoutingAtLaunch)
    }

    func testPresetLockDefaultsOffAndPersistsPresetID() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.lockedPresetIDKey)

        XCTAssertFalse(EqualEaseSettings.isPresetLocked)
        XCTAssertNil(EqualEaseSettings.lockedPresetID)

        EqualEaseSettings.lockedPresetID = "built-in-warm"

        XCTAssertTrue(EqualEaseSettings.isPresetLocked)
        XCTAssertEqual(EqualEaseSettings.lockedPresetID, "built-in-warm")

        EqualEaseSettings.lockedPresetID = nil

        XCTAssertFalse(EqualEaseSettings.isPresetLocked)
        XCTAssertNil(EqualEaseSettings.lockedPresetID)
    }

    func testStoredLanguageOverrideLaunchNoOpWhenNoEqualEaseOverridePreservesAppleLanguages() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.languageOverrideIdentifierKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.ownsAppleLanguagesKey)
        UserDefaults.standard.set(["fr"], forKey: EqualEaseSettings.appleLanguagesKey)

        EqualEaseSettings.applyStoredLanguageOverrideForLaunch()

        XCTAssertNil(EqualEaseSettings.languageOverrideIdentifier)
        XCTAssertEqual(Self.standardDefaultsPersistentValue(forKey: EqualEaseSettings.appleLanguagesKey) as? [String], ["fr"])
    }

    func testExplicitSystemDefaultClearsEqualEaseOwnedAppleLanguages() throws {
        let identifier = try XCTUnwrap(EqualEaseSettings.availableLanguageIdentifiers.first)
        EqualEaseSettings.applyLanguageOverrideForNextLaunch(identifier)

        EqualEaseSettings.applyLanguageOverrideForNextLaunch(nil)

        XCTAssertNil(EqualEaseSettings.languageOverrideIdentifier)
        XCTAssertNil(Self.standardDefaultsPersistentValue(forKey: EqualEaseSettings.ownsAppleLanguagesKey))
        XCTAssertNil(Self.standardDefaultsPersistentValue(forKey: EqualEaseSettings.appleLanguagesKey))
    }

    func testLanguageOverridePersistsAndSetsAppleLanguagesForNextLaunch() throws {
        let identifier = try XCTUnwrap(EqualEaseSettings.availableLanguageIdentifiers.first)

        EqualEaseSettings.applyLanguageOverrideForNextLaunch(identifier)

        XCTAssertEqual(EqualEaseSettings.languageOverrideIdentifier, identifier)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: EqualEaseSettings.ownsAppleLanguagesKey))
        XCTAssertEqual(UserDefaults.standard.array(forKey: EqualEaseSettings.appleLanguagesKey) as? [String], [identifier])
    }

    func testUnsupportedLanguageOverrideFallsBackToSystemDefault() {
        EqualEaseSettings.languageOverrideIdentifier = "zz"
        UserDefaults.standard.set(true, forKey: EqualEaseSettings.ownsAppleLanguagesKey)
        UserDefaults.standard.set(["zz"], forKey: EqualEaseSettings.appleLanguagesKey)

        EqualEaseSettings.applyStoredLanguageOverrideForLaunch()

        XCTAssertNil(EqualEaseSettings.languageOverrideIdentifier)
        XCTAssertNil(Self.standardDefaultsPersistentValue(forKey: EqualEaseSettings.ownsAppleLanguagesKey))
        XCTAssertNil(Self.standardDefaultsPersistentValue(forKey: EqualEaseSettings.appleLanguagesKey))
    }

    private static func standardDefaultsPersistentValue(forKey key: String) -> Any? {
        guard let domainName = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: domainName)?[key]
    }

    func testQuickPanelControlVisibilityDefaultsOnAndPersistsExplicitChoices() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelPreampKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelInputVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelRoutingKey)

        XCTAssertTrue(EqualEaseSettings.showsQuickPanelVolume)
        XCTAssertTrue(EqualEaseSettings.showsQuickPanelPreamp)
        XCTAssertTrue(EqualEaseSettings.showsQuickPanelInputVolume)
        XCTAssertTrue(EqualEaseSettings.showsQuickPanelRouting)

        EqualEaseSettings.showsQuickPanelVolume = false
        EqualEaseSettings.showsQuickPanelPreamp = false
        EqualEaseSettings.showsQuickPanelInputVolume = false
        EqualEaseSettings.showsQuickPanelRouting = false

        XCTAssertFalse(EqualEaseSettings.showsQuickPanelVolume)
        XCTAssertFalse(EqualEaseSettings.showsQuickPanelPreamp)
        XCTAssertFalse(EqualEaseSettings.showsQuickPanelInputVolume)
        XCTAssertFalse(EqualEaseSettings.showsQuickPanelRouting)
    }

    func testRoutingOnboardingAndLaunchRestorePersistExplicitChoices() {
        EqualEaseSettings.hasCompletedRoutingOnboarding = true
        EqualEaseSettings.startAudioRoutingAtLaunch = true

        XCTAssertFalse(EqualEaseSettings.shouldPresentRoutingOnboarding)
        XCTAssertTrue(EqualEaseSettings.hasCompletedRoutingOnboarding)
        XCTAssertTrue(EqualEaseSettings.startAudioRoutingAtLaunch)

        EqualEaseSettings.startAudioRoutingAtLaunch = false

        XCTAssertFalse(EqualEaseSettings.startAudioRoutingAtLaunch)
    }
}
