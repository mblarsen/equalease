//
//  ActiveContextPresetResolverTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class ActiveContextPresetResolverTests: XCTestCase {
    func testPresetLockTakesPrecedenceOverAppRule() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: muffled.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id],
            lockedPresetID: flat.id
        )))

        XCTAssertEqual(context.preset, flat)
        XCTAssertEqual(context.source, .lockedPreset)
        XCTAssertEqual(context.selectedDefaultPresetID, muffled.id)
        XCTAssertEqual(context.sourceSummary, "Flat · paused")
        XCTAssertTrue(context.sourceExplanation.contains("stays on Flat"))
    }

    func testPresetLockSuppressesManualOverrideAndPrompt() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari, lockedPresetID: flat.id)
        ))

        XCTAssertEqual(context.preset, flat)
        XCTAssertEqual(context.source, .lockedPreset)
        XCTAssertNil(context.appLearningPrompt)
    }

    func testAppRuleTakesPrecedenceOverSelectedDefaultPreset() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: muffled.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
        )))

        XCTAssertEqual(context.preset, voiceBoost)
        XCTAssertEqual(
            context.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
        XCTAssertEqual(context.selectedDefaultPresetID, muffled.id)
        XCTAssertEqual(context.sourceSummary, "Voice Boost for Safari")
        XCTAssertTrue(context.sourceExplanation.contains(safari.bundleIdentifier))
    }

    func testAppRuleApplicationDoesNotMutateSelectedDefaultPreset() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let muffledPreset = try XCTUnwrap(store.presets.first { $0.name == "Muffled" })
        let voiceBoostPreset = try XCTUnwrap(store.presets.first { $0.name == "Voice Boost" })
        _ = store.selectPreset(id: muffledPreset.id)
        store.assignPreset(
            id: voiceBoostPreset.id,
            toAppBundleIdentifier: safari.bundleIdentifier,
            displayName: safari.displayName
        )

        let resolver = ActiveContextPresetResolver()
        let safariContext = try XCTUnwrap(resolver.resolve(input: ActiveContextPresetInput(
            selectedPresetID: store.selectedPresetID,
            outputDeviceUID: nil,
            foregroundApp: safari,
            presets: store.presets,
            devicePresetIDs: store.devicePresetIDs,
            appPresetIDs: store.appPresetIDs
        )))

        XCTAssertEqual(safariContext.preset.id, voiceBoostPreset.id)
        XCTAssertEqual(store.selectedPresetID, muffledPreset.id)

        let terminalContext = try XCTUnwrap(resolver.resolve(input: ActiveContextPresetInput(
            selectedPresetID: store.selectedPresetID,
            outputDeviceUID: nil,
            foregroundApp: terminal,
            presets: store.presets,
            devicePresetIDs: store.devicePresetIDs,
            appPresetIDs: store.appPresetIDs
        )))

        XCTAssertEqual(terminalContext.preset.id, muffledPreset.id)
        XCTAssertEqual(terminalContext.source, .selectedPreset)
        XCTAssertEqual(store.selectedPresetID, muffledPreset.id)
    }

    func testWebsiteRuleTakesPrecedenceOverAppRule() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: muffled.id,
            foregroundApp: safari,
            activeWebsite: meet,
            appPresetIDs: [safari.bundleIdentifier: muffled.id],
            websitePresetIDs: [meet.siteKey: voiceBoost.id]
        )))

        XCTAssertEqual(context.preset, voiceBoost)
        XCTAssertEqual(context.source, .activeWebsite(siteKey: meet.siteKey, displayName: meet.displayName))
        XCTAssertEqual(context.sourceSummary, "Voice Boost for meet.google.com")
        XCTAssertTrue(context.sourceExplanation.contains(meet.siteKey))
    }

    func testSelectedDefaultPresetIsFallbackWhenNoAppRuleMatches() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: muffled.id,
            foregroundApp: terminal,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
        )))

        XCTAssertEqual(context.preset, muffled)
        XCTAssertEqual(context.source, .selectedPreset)
        XCTAssertEqual(context.sourceExplanation, "Using the selected default preset Muffled.")
    }

    func testManualPresetSelectionShowsPromptForForegroundAppWithoutSameRule() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        ))

        let prompt = try XCTUnwrap(context.appLearningPrompt)
        XCTAssertEqual(prompt.target, .app(safari))
        XCTAssertEqual(prompt.preset, voiceBoost)
    }

    func testManualPresetSelectionPrefersWebsitePromptWhenActiveWebsiteIsReadable() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(
                selectedPresetID: voiceBoost.id,
                foregroundApp: safari,
                activeWebsite: meet
            )
        ))

        XCTAssertEqual(context.appLearningPrompt?.target, .website(meet))
        XCTAssertEqual(context.appLearningPrompt?.preset, voiceBoost)
    }

    func testManualPresetSelectionDoesNotPromptWhenAppAlreadyRemembersPreset() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(
                selectedPresetID: voiceBoost.id,
                foregroundApp: safari,
                appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
            )
        ))

        XCTAssertNil(context.appLearningPrompt)
    }

    func testManualPresetSelectionDoesNotPromptWhenWebsiteAlreadyRemembersPreset() throws {
        let resolver = ActiveContextPresetResolver()

        let context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(
                selectedPresetID: voiceBoost.id,
                foregroundApp: safari,
                activeWebsite: meet,
                websitePresetIDs: [meet.siteKey: voiceBoost.id]
            )
        ))

        XCTAssertNil(context.appLearningPrompt)
    }

    func testManualPresetSelectionOverridesExistingAppRuleUntilAppChanges() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.resolve(input: input(
            selectedPresetID: muffled.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
        ))

        let manualContext = try XCTUnwrap(resolver.recordManualPresetSelection(
            flat,
            input: input(
                selectedPresetID: flat.id,
                foregroundApp: safari,
                appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
            )
        ))

        XCTAssertEqual(manualContext.preset, flat)
        XCTAssertEqual(manualContext.source, .selectedPreset)
        XCTAssertEqual(manualContext.appLearningPrompt?.preset, flat)

        let stillInSafariContext = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: flat.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id]
        )))
        XCTAssertEqual(stillInSafariContext.preset, flat)

        _ = resolver.resolve(input: input(
            selectedPresetID: flat.id,
            foregroundApp: terminal,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id],
            foregroundActivationGeneration: 1
        ))
        let returnedToSafariContext = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: flat.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id],
            foregroundActivationGeneration: 2
        )))
        XCTAssertEqual(returnedToSafariContext.preset, voiceBoost)
        XCTAssertEqual(
            returnedToSafariContext.source,
            .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName)
        )
    }

    func testManualPresetSelectionIsClearedByActivationEvenWhenAppIdentityIsPreserved() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.recordManualPresetSelection(
            flat,
            input: input(
                selectedPresetID: flat.id,
                foregroundApp: safari,
                appPresetIDs: [safari.bundleIdentifier: voiceBoost.id],
                foregroundActivationGeneration: 1
            )
        )

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: flat.id,
            foregroundApp: safari,
            appPresetIDs: [safari.bundleIdentifier: voiceBoost.id],
            foregroundActivationGeneration: 2
        )))

        XCTAssertEqual(context.preset, voiceBoost)
        XCTAssertEqual(context.source, .activeApp(bundleIdentifier: safari.bundleIdentifier, displayName: safari.displayName))
    }

    func testManualPresetSelectionIsClearedByWebsiteGenerationChange() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.recordManualPresetSelection(
            flat,
            input: input(
                selectedPresetID: flat.id,
                foregroundApp: safari,
                activeWebsite: meet,
                websitePresetIDs: [meet.siteKey: voiceBoost.id],
                websiteGeneration: 1
            )
        )

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: flat.id,
            foregroundApp: safari,
            activeWebsite: meet,
            websitePresetIDs: [meet.siteKey: voiceBoost.id],
            websiteGeneration: 2
        )))

        XCTAssertEqual(context.preset, voiceBoost)
        XCTAssertEqual(context.source, .activeWebsite(siteKey: meet.siteKey, displayName: meet.displayName))
    }

    func testAppSwitchClearsVisiblePrompt() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        )
        XCTAssertNotNil(resolver.context?.appLearningPrompt)

        let context = try XCTUnwrap(resolver.resolve(input: input(
            selectedPresetID: voiceBoost.id,
            foregroundApp: terminal
        )))

        XCTAssertNil(context.appLearningPrompt)
    }

    func testDismissalSuppressesRepeatedPromptUntilSessionReset() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        )
        XCTAssertNotNil(resolver.context?.appLearningPrompt)

        resolver.dismissPrompt()
        var context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        ))
        XCTAssertNil(context.appLearningPrompt)

        resolver.resetPromptSession()
        context = try XCTUnwrap(resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        ))
        XCTAssertNotNil(context.appLearningPrompt)
    }

    func testAcceptPromptReturnsSuggestionAndClearsPrompt() throws {
        let resolver = ActiveContextPresetResolver()
        _ = resolver.recordManualPresetSelection(
            voiceBoost,
            input: input(selectedPresetID: voiceBoost.id, foregroundApp: safari)
        )

        let suggestion = try XCTUnwrap(resolver.acceptPrompt())

        XCTAssertEqual(suggestion.target, .app(safari))
        XCTAssertEqual(suggestion.preset, voiceBoost)
        XCTAssertNil(resolver.context?.appLearningPrompt)
    }

    private func input(
        selectedPresetID: String,
        outputDeviceUID: String? = nil,
        foregroundApp: ForegroundAppIdentity? = nil,
        activeWebsite: BrowserPageIdentity? = nil,
        devicePresetIDs: [String: String] = [:],
        appPresetIDs: [String: String] = [:],
        websitePresetIDs: [String: String] = [:],
        lockedPresetID: String? = nil,
        foregroundActivationGeneration: Int = 0,
        websiteGeneration: Int = 0
    ) -> ActiveContextPresetInput {
        ActiveContextPresetInput(
            selectedPresetID: selectedPresetID,
            outputDeviceUID: outputDeviceUID,
            foregroundApp: foregroundApp,
            activeWebsite: activeWebsite,
            presets: presets,
            devicePresetIDs: devicePresetIDs,
            appPresetIDs: appPresetIDs,
            websitePresetIDs: websitePresetIDs,
            lockedPresetID: lockedPresetID,
            foregroundActivationGeneration: foregroundActivationGeneration,
            websiteGeneration: websiteGeneration
        )
    }

    private func temporaryPresetURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    private var presets: [EQPreset] {
        [flat, voiceBoost, muffled]
    }

    private var flat: EQPreset {
        EQPreset(id: "flat", name: "Flat", source: .builtIn, bandGains: Array(repeating: 0, count: 10), outputGain: 1)
    }

    private var voiceBoost: EQPreset {
        EQPreset(id: "voice-boost", name: "Voice Boost", source: .builtIn, bandGains: Array(repeating: 2, count: 10), outputGain: 0.9)
    }

    private var muffled: EQPreset {
        EQPreset(id: "muffled", name: "Muffled", source: .builtIn, bandGains: Array(repeating: -4, count: 10), outputGain: 0.5)
    }

    private var safari: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
    }

    private var terminal: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
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
