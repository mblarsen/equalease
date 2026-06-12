//
//  RulesSettingsActions.swift
//  EqualEase
//

import Foundation

@MainActor
struct RulesSettingsActions {
    var presetStore: PresetStore
    var browserPageObserver: BrowserPageObserver

    func assignSelectedPreset(to activeApp: ForegroundAppIdentity) {
        presetStore.assignPreset(
            id: presetStore.selectedPresetID,
            toAppBundleIdentifier: activeApp.bundleIdentifier,
            displayName: activeApp.displayName
        )
    }

    func clearAppRule(bundleIdentifier: String) {
        presetStore.clearPreset(forAppBundleIdentifier: bundleIdentifier)
    }

    func requestCurrentBrowserPageAndAssignSelectedPreset() {
        guard let activePage = browserPageObserver.requestActivePageFromUserAction() else { return }
        assignSelectedPreset(to: activePage)
    }

    func assignSelectedPreset(to activePage: BrowserPageIdentity) {
        presetStore.assignPreset(
            id: presetStore.selectedPresetID,
            toWebsiteKey: activePage.siteKey,
            displayName: activePage.displayName
        )
        preserveUserRequestedPageAfterCurrentUpdate(activePage)
    }

    func clearWebsiteRule(siteKey: String) {
        presetStore.clearPreset(forWebsiteKey: siteKey)
    }

    func refreshBrowserPageForRulesScreen() async {
        await Task.yield()
        browserPageObserver.refreshActivePageWithoutPrompt(clearOnFailure: !presetStore.websitePresetIDs.isEmpty)
    }

    private func preserveUserRequestedPageAfterCurrentUpdate(_ page: BrowserPageIdentity) {
        Task { @MainActor in
            await Task.yield()
            browserPageObserver.preserveUserRequestedPage(page)
        }
    }
}
