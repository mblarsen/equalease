//
//  PresetResolutionServiceTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class PresetResolutionServiceTests: XCTestCase {
    func testPresetLockWinsOverWebsiteAppRuleAndSelectedPreset() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            activeWebsite: meet,
            presets: presets,
            devicePresetIDs: ["speaker": treble.id],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: [meet.siteKey: treble.id],
            lockedPresetID: warm.id
        )

        XCTAssertEqual(resolution?.preset, warm)
        XCTAssertEqual(resolution?.source, .lockedPreset)
    }

    func testDeviceRuleIsIgnoredWhileDeviceRulesArePaused() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            presets: presets,
            devicePresetIDs: ["speaker": treble.id],
            appPresetIDs: [safari.bundleIdentifier: bass.id]
        )

        XCTAssertEqual(resolution?.preset, bass)
        XCTAssertEqual(
            resolution?.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
    }

    func testWebsiteRuleWinsOverActiveAppRule() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            activeWebsite: meet,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: [meet.siteKey: treble.id]
        )

        XCTAssertEqual(resolution?.preset, treble)
        XCTAssertEqual(
            resolution?.source,
            .activeWebsite(siteKey: meet.siteKey, displayName: meet.displayName)
        )
    }

    func testActiveAppRuleWinsOverSelectedPresetWhenNoWebsiteRuleMatches() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            activeWebsite: meet,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: ["youtube.com": treble.id]
        )

        XCTAssertEqual(resolution?.preset, bass)
        XCTAssertEqual(
            resolution?.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
    }

    func testActiveAppRuleWinsWhenWebsiteBelongsToDifferentBrowser() {
        let staleSafariPage = BrowserPageIdentity(
            browserBundleIdentifier: safari.bundleIdentifier,
            browserDisplayName: safari.displayName,
            url: URL(string: "https://github.com/plantura-garden/app/pull/1449")!,
            siteKey: "github.com",
            displayName: "github.com"
        )

        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: chrome,
            activeWebsite: staleSafariPage,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [chrome.bundleIdentifier: bass.id],
            websitePresetIDs: ["github.com": treble.id]
        )

        XCTAssertEqual(resolution?.preset, bass)
        XCTAssertEqual(
            resolution?.source,
            .activeApp(bundleIdentifier: chrome.bundleIdentifier, displayName: chrome.displayName)
        )
    }

    func testActiveAppRuleWinsWhenWebsitePresetIDIsMissing() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            activeWebsite: meet,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: [meet.siteKey: "missing-preset"]
        )

        XCTAssertEqual(resolution?.preset, bass)
        XCTAssertEqual(
            resolution?.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
    }

    func testActiveAppRuleWinsWhenWebsiteRulesExistButActiveWebsiteIsUnknown() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: flat.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            activeWebsite: nil,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: [meet.siteKey: treble.id]
        )

        XCTAssertEqual(resolution?.preset, bass)
        XCTAssertEqual(
            resolution?.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
    }

    func testSelectedPresetWinsWhenWebsiteRulesExistButActiveWebsiteAndAppAreUnknown() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: warm.id,
            outputDeviceUID: "speaker",
            activeApp: nil,
            activeWebsite: nil,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [safari.bundleIdentifier: bass.id],
            websitePresetIDs: [meet.siteKey: treble.id]
        )

        XCTAssertEqual(resolution?.preset, warm)
        XCTAssertEqual(resolution?.source, .selectedPreset)
    }

    func testSelectedPresetIsFallbackWhenNoRulesMatch() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: warm.id,
            outputDeviceUID: "speaker",
            activeApp: safari,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [:]
        )

        XCTAssertEqual(resolution?.preset, warm)
        XCTAssertEqual(resolution?.source, .selectedPreset)
    }

    func testSelectedPresetRemainsFallbackWhenNoActiveAppRuleMatches() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: warm.id,
            outputDeviceUID: "speaker",
            activeApp: terminal,
            presets: presets,
            devicePresetIDs: ["speaker": treble.id],
            appPresetIDs: [safari.bundleIdentifier: bass.id]
        )

        XCTAssertEqual(resolution?.preset, warm)
        XCTAssertEqual(resolution?.source, .selectedPreset)
    }

    func testMissingSelectedPresetFallsBackToFirstPreset() {
        let resolution = PresetResolutionService.resolve(
            selectedPresetID: "missing-preset",
            outputDeviceUID: nil,
            activeApp: nil,
            presets: presets,
            devicePresetIDs: [:],
            appPresetIDs: [:]
        )

        XCTAssertEqual(resolution?.preset, flat)
        XCTAssertEqual(resolution?.source, .selectedPreset)
    }

    @MainActor
    func testDeletingCustomPresetRemovesDeviceAndAppMappings() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let customPreset = store.saveCurrentPreset(
            bandGains: Array(repeating: 1, count: 10),
            outputGain: 0.8
        )
        store.assignPreset(id: customPreset.id, toDeviceUID: "speaker", deviceName: "Desk Speakers")
        store.assignPreset(id: customPreset.id, toAppBundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        store.assignPreset(id: customPreset.id, toWebsiteKey: meet.siteKey, displayName: meet.displayName)

        store.deleteCustomPreset(id: customPreset.id)

        XCTAssertNil(store.preset(id: customPreset.id))
        XCTAssertNil(store.devicePresetIDs["speaker"])
        XCTAssertNil(store.appPresetIDs[safari.bundleIdentifier])
        XCTAssertNil(store.websitePresetIDs[meet.siteKey])
        XCTAssertNil(store.deviceDisplayNames["speaker"])
        XCTAssertNil(store.appDisplayNames[safari.bundleIdentifier])
        XCTAssertNil(store.websiteDisplayNames[meet.siteKey])
        XCTAssertEqual(store.selectedPresetID, "built-in-flat")
    }

    @MainActor
    func testPresetStatePersistsAndReloadsFromDisk() throws {
        let url = temporaryPresetURL()
        let store = PresetStore(persistenceURL: url)
        let customPreset = store.saveCurrentPreset(
            bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            outputGain: 0.75
        )
        store.renameCustomPreset(id: customPreset.id, name: "Speech Test")
        store.assignPreset(id: customPreset.id, toDeviceUID: "speaker", deviceName: "Desk Speakers")
        store.assignPreset(id: customPreset.id, toAppBundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        store.assignPreset(id: customPreset.id, toWebsiteKey: meet.siteKey, displayName: meet.displayName)

        let reloadedStore = PresetStore(persistenceURL: url)
        let reloadedPreset = try XCTUnwrap(reloadedStore.preset(id: customPreset.id))

        XCTAssertEqual(reloadedPreset.name, "Speech Test")
        XCTAssertEqual(reloadedPreset.bandGains, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(reloadedPreset.outputGain, 0.75)
        XCTAssertEqual(reloadedStore.selectedPresetID, customPreset.id)
        XCTAssertEqual(reloadedStore.devicePresetIDs["speaker"], customPreset.id)
        XCTAssertEqual(reloadedStore.appPresetIDs[safari.bundleIdentifier], customPreset.id)
        XCTAssertEqual(reloadedStore.websitePresetIDs[meet.siteKey], customPreset.id)
        XCTAssertEqual(reloadedStore.deviceDisplayNames["speaker"], "Desk Speakers")
        XCTAssertEqual(reloadedStore.appDisplayNames[safari.bundleIdentifier], safari.displayName)
        XCTAssertEqual(reloadedStore.websiteDisplayNames[meet.siteKey], meet.displayName)
    }

    @MainActor
    func testDuplicatePresetCreatesSelectedCustomCopy() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let sourcePreset = try XCTUnwrap(store.presets.first { $0.name == "Bass Boost" })
        let duplicate = try XCTUnwrap(store.duplicatePreset(id: sourcePreset.id))

        XCTAssertNotEqual(duplicate.id, sourcePreset.id)
        XCTAssertEqual(duplicate.name, "Bass Boost Copy")
        XCTAssertEqual(duplicate.source, .custom)
        XCTAssertEqual(duplicate.bandGains, sourcePreset.bandGains)
        XCTAssertEqual(duplicate.outputGain, sourcePreset.outputGain)
        XCTAssertEqual(store.selectedPresetID, duplicate.id)
    }

    private func temporaryPresetURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    private var presets: [EQPreset] {
        [flat, bass, treble, warm]
    }

    private var flat: EQPreset {
        EQPreset(id: "flat", name: "Flat", source: .builtIn, bandGains: Array(repeating: 0, count: 10), outputGain: 1)
    }

    private var bass: EQPreset {
        EQPreset(id: "bass", name: "Bass", source: .builtIn, bandGains: Array(repeating: 2, count: 10), outputGain: 0.8)
    }

    private var treble: EQPreset {
        EQPreset(id: "treble", name: "Treble", source: .builtIn, bandGains: Array(repeating: 3, count: 10), outputGain: 0.7)
    }

    private var warm: EQPreset {
        EQPreset(id: "warm", name: "Warm", source: .builtIn, bandGains: Array(repeating: 1, count: 10), outputGain: 0.9)
    }

    private var safari: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
    }

    private var terminal: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
    }

    private var chrome: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
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
