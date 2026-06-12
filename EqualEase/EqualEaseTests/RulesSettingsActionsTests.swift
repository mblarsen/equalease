//
//  RulesSettingsActionsTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class RulesSettingsActionsTests: XCTestCase {
    func testAssignSelectedPresetToActiveAppCreatesAppRule() {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let observer = BrowserPageObserver(provider: FakeRulesBrowserPageProvider())
        let actions = RulesSettingsActions(presetStore: store, browserPageObserver: observer)

        actions.assignSelectedPreset(to: safari)

        XCTAssertEqual(store.appPresetIDs[safari.bundleIdentifier], store.selectedPresetID)
        XCTAssertEqual(store.appDisplayNames[safari.bundleIdentifier], safari.displayName)
    }

    func testRequestCurrentBrowserPageAndAssignSelectedPresetCreatesWebsiteRule() {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let provider = FakeRulesBrowserPageProvider()
        provider.page = meet
        let observer = BrowserPageObserver(provider: provider)
        observer.updateForegroundApp(safari)
        let actions = RulesSettingsActions(presetStore: store, browserPageObserver: observer)

        actions.requestCurrentBrowserPageAndAssignSelectedPreset()

        XCTAssertEqual(store.websitePresetIDs[meet.siteKey], store.selectedPresetID)
        XCTAssertEqual(store.websiteDisplayNames[meet.siteKey], meet.displayName)
        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(provider.permissionPromptRequests, [true])
    }

    func testRulesScreenRefreshPreservesCurrentPageWhenNoWebsiteRulesExist() async {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let provider = FakeRulesBrowserPageProvider()
        provider.page = meet
        let observer = BrowserPageObserver(provider: provider)
        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        let actions = RulesSettingsActions(presetStore: store, browserPageObserver: observer)

        provider.page = nil
        await actions.refreshBrowserPageForRulesScreen()

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(provider.permissionPromptRequests, [true, false])
    }

    func testRulesScreenRefreshClearsCurrentPageWhenWebsiteRulesExistAndReadFails() async {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let provider = FakeRulesBrowserPageProvider()
        provider.page = meet
        let observer = BrowserPageObserver(provider: provider)
        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        store.assignPreset(id: store.selectedPresetID, toWebsiteKey: meet.siteKey, displayName: meet.displayName)
        let actions = RulesSettingsActions(presetStore: store, browserPageObserver: observer)

        provider.page = nil
        await actions.refreshBrowserPageForRulesScreen()

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(provider.permissionPromptRequests, [true, false])
    }

    func testClearWebsiteRuleDoesNotForgetVisibleCurrentPage() {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let provider = FakeRulesBrowserPageProvider()
        provider.page = meet
        let observer = BrowserPageObserver(provider: provider)
        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        store.assignPreset(id: store.selectedPresetID, toWebsiteKey: meet.siteKey, displayName: meet.displayName)
        let actions = RulesSettingsActions(presetStore: store, browserPageObserver: observer)

        actions.clearWebsiteRule(siteKey: meet.siteKey)

        XCTAssertNil(store.websitePresetIDs[meet.siteKey])
        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
    }

    private func temporaryPresetURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseRulesSettingsActionsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    private var safari: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
    }

    private var meet: BrowserPageIdentity {
        BrowserPageIdentity(
            browserBundleIdentifier: safari.bundleIdentifier,
            browserDisplayName: safari.displayName,
            url: URL(string: "https://meet.google.com/")!,
            siteKey: "meet.google.com",
            displayName: "meet.google.com"
        )
    }
}

@MainActor
private final class FakeRulesBrowserPageProvider: ActiveBrowserPageProviding {
    var browserDisplayName = "Safari"
    var page: BrowserPageIdentity?
    var permissionPromptRequests: [Bool] = []

    func supports(bundleIdentifier: String) -> Bool {
        bundleIdentifier == SafariActivePageProvider.safariBundleIdentifier
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        permissionPromptRequests.append(promptsForPermission)
        guard supports(bundleIdentifier: foregroundApp.bundleIdentifier) else { return nil }
        return page
    }
}
