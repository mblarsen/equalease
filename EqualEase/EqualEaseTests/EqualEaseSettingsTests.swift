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
