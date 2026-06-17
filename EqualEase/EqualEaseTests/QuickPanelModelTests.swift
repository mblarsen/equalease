//
//  QuickPanelModelTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class QuickPanelModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelPreampKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelInputVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelRoutingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.hasCompletedRoutingOnboardingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.startAudioRoutingAtLaunchKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.lockedPresetIDKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelPreampKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelInputVolumeKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.showsQuickPanelRoutingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.hasCompletedRoutingOnboardingKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.startAudioRoutingAtLaunchKey)
        UserDefaults.standard.removeObject(forKey: EqualEaseSettings.lockedPresetIDKey)
        super.tearDown()
    }

    func testModelSummarizesSelectedAndEffectivePresetForQuickPanel() throws {
        let presetStore = PresetStore(persistenceURL: temporaryPresetURL())
        let voiceBoost = try XCTUnwrap(presetStore.presets.first { $0.name == "Voice Boost" })
        _ = presetStore.selectPreset(id: voiceBoost.id)

        let resolver = ActiveContextPresetResolver()
        _ = resolver.resolve(input: ActiveContextPresetInput(
            selectedPresetID: presetStore.selectedPresetID,
            outputDeviceUID: nil,
            foregroundApp: nil,
            presets: presetStore.presets,
            devicePresetIDs: [:],
            appPresetIDs: [:]
        ))

        let model = makeModel(presetStore: presetStore, activeContextResolver: resolver)

        XCTAssertEqual(model.selectedPresetName, "Voice Boost")
        XCTAssertEqual(model.effectivePresetSummary, "Voice Boost")
    }

    func testStatusTitleMatchesRoutingLifecycleState() {
        let router = TestQuickPanelRouter()
        let model = makeModel(router: router)

        router.state = .stopped
        XCTAssertEqual(model.statusTitle, "Off")

        router.state = .starting
        XCTAssertEqual(model.statusTitle, "Starting…")

        router.state = .running
        XCTAssertEqual(model.statusTitle, "Active")

        router.state = .failed("No route")
        XCTAssertEqual(model.statusTitle, "Failed")

        router.state = .running
        router.isRunning = true
        router.isRoutingTransitioning = true
        router.statusText = "Switching to headphones"
        XCTAssertEqual(model.statusTitle, "Switching…")

        router.statusText = "Stopping audio routing"
        XCTAssertEqual(model.statusTitle, "Stopping…")
    }

    func testActiveToggleDelegatesToRouterLifecycle() {
        let router = TestQuickPanelRouter()
        let model = makeModel(router: router)

        model.setActive(true)
        XCTAssertEqual(router.startCount, 1)
        XCTAssertEqual(router.stopCount, 0)
        XCTAssertTrue(EqualEaseSettings.hasCompletedRoutingOnboarding)

        model.setActive(false)
        XCTAssertEqual(router.startCount, 1)
        XCTAssertEqual(router.stopCount, 1)
    }

    func testRoutingOnboardingStartsRoutingAndPersistsRestorePreference() {
        let router = TestQuickPanelRouter()
        let model = makeModel(router: router, hasCompletedRoutingOnboarding: false)

        XCTAssertTrue(model.shouldShowRoutingOnboarding)

        model.startRoutingFromOnboarding(restoreAtLaunch: true)

        XCTAssertEqual(router.startCount, 1)
        XCTAssertTrue(EqualEaseSettings.hasCompletedRoutingOnboarding)
        XCTAssertTrue(EqualEaseSettings.startAudioRoutingAtLaunch)
        XCTAssertFalse(model.shouldShowRoutingOnboarding)
    }

    func testRoutingOnboardingCanBeDismissedWithoutLaunchRestore() {
        let model = makeModel(hasCompletedRoutingOnboarding: false)

        model.dismissRoutingOnboarding()

        XCTAssertTrue(EqualEaseSettings.hasCompletedRoutingOnboarding)
        XCTAssertFalse(EqualEaseSettings.startAudioRoutingAtLaunch)
        XCTAssertFalse(model.shouldShowRoutingOnboarding)
    }

    func testOnAppearRefreshesInputStateAndRunsQuickPanelRefreshActions() {
        var didApplyEffectivePreset = false
        var didResetPromptDismissals = false
        let actions = QuickPanelActions(
            applyEffectivePreset: { didApplyEffectivePreset = true },
            selectPreset: { _ in },
            setPresetLock: { _ in },
            acceptAppPresetSuggestion: {},
            dismissAppPresetSuggestion: {},
            resetAppPresetSuggestionDismissals: { didResetPromptDismissals = true },
            openSettingsWindow: {},
            openPresetsSettings: {},
            showAboutPanel: {},
            quit: {}
        )
        let inputHost = TestInputDeviceControlHost()
        let inputDeviceController = InputDeviceController(host: inputHost)
        let model = makeModel(inputDeviceController: inputDeviceController, actions: actions)

        inputHost.currentDevice = inputHost.usbMicrophone
        model.onAppear()

        XCTAssertEqual(model.currentInputDeviceName, "USB Microphone")
        XCTAssertTrue(didApplyEffectivePreset)
        XCTAssertTrue(didResetPromptDismissals)
    }

    func testVolumeVisibilityPreferenceDefaultsVisibleAndCanBeHiddenAndRestored() {
        let model = makeModel()

        XCTAssertTrue(model.showsVolumeControls)
        XCTAssertTrue(model.showsLevelControls)

        model.hideVolumeControls()

        XCTAssertFalse(EqualEaseSettings.showsQuickPanelVolume)
        XCTAssertFalse(model.showsVolumeControls)
        XCTAssertTrue(model.showsLevelControls)

        EqualEaseSettings.showsQuickPanelVolume = true

        XCTAssertTrue(model.showsVolumeControls)
    }

    func testPreampVisibilityPreferenceDefaultsVisibleAndCanBeHiddenAndRestored() {
        let model = makeModel()

        XCTAssertTrue(model.showsPreampControls)
        XCTAssertTrue(model.showsLevelControls)

        model.hidePreampControls()

        XCTAssertFalse(EqualEaseSettings.showsQuickPanelPreamp)
        XCTAssertFalse(model.showsPreampControls)
        XCTAssertTrue(model.showsLevelControls)

        EqualEaseSettings.showsQuickPanelPreamp = true

        XCTAssertTrue(model.showsPreampControls)
    }

    func testInputVolumeVisibilityPreferenceDefaultsVisibleAndCanBeHiddenAndRestored() {
        let model = makeModel()

        XCTAssertTrue(model.showsInputVolumeControls)

        model.hideInputVolumeControls()

        XCTAssertFalse(EqualEaseSettings.showsQuickPanelInputVolume)
        XCTAssertFalse(model.showsInputVolumeControls)

        EqualEaseSettings.showsQuickPanelInputVolume = true

        XCTAssertTrue(model.showsInputVolumeControls)
    }

    func testPanelHeightAdaptsWhenOptionalSectionsAreHidden() {
        let model = makeModel()
        let visibleHeight = model.preferredPanelHeight

        model.hideInputVolumeControls()

        XCTAssertLessThan(model.preferredPanelHeight, visibleHeight)
        XCTAssertEqual(model.preferredPanelHeight, 484)

        model.hideRoutingControls()

        XCTAssertEqual(model.preferredPanelHeight, 376)

        model.hideVolumeControls()

        XCTAssertEqual(model.preferredPanelHeight, 306)

        model.hidePreampControls()

        XCTAssertEqual(model.preferredPanelHeight, 244)
        XCTAssertFalse(model.showsLevelControls)
    }

    func testRoutingSectionHidesWithRoutingPreference() {
        let model = makeModel()

        XCTAssertTrue(model.showsRoutingSection)

        model.hideRoutingControls()

        XCTAssertFalse(EqualEaseSettings.showsQuickPanelRouting)
        XCTAssertFalse(model.showsRoutingSection)
    }

    func testInputSectionHidesWithInputVolumePreference() {
        let inputHost = TestInputDeviceControlHost()
        inputHost.currentDevice = AudioInputDevice(uid: "studio-mic", name: "Studio Microphone")
        inputHost.volumeStates["studio-mic"] = AudioInputVolumeState(canReadVolume: true, canSetVolume: true, volume: 0.55)
        let model = makeModel(inputDeviceController: InputDeviceController(host: inputHost))

        XCTAssertTrue(model.showsInputSection)
        XCTAssertEqual(model.currentInputDeviceName, "Studio Microphone")

        model.hideInputVolumeControls()

        XCTAssertFalse(model.showsInputSection)
        XCTAssertFalse(model.showsInputVolumeControls)
    }

    func testPresetLockHelpTextExplainsPresetRules() throws {
        let presetStore = PresetStore(persistenceURL: temporaryPresetURL())
        let flat = try XCTUnwrap(presetStore.presets.first { $0.name == "Flat" })
        EqualEaseSettings.lockedPresetID = flat.id

        let resolver = ActiveContextPresetResolver()
        _ = resolver.resolve(input: ActiveContextPresetInput(
            selectedPresetID: presetStore.selectedPresetID,
            outputDeviceUID: nil,
            foregroundApp: nil,
            presets: presetStore.presets,
            devicePresetIDs: [:],
            appPresetIDs: [:],
            lockedPresetID: flat.id
        ))
        let model = makeModel(presetStore: presetStore, activeContextResolver: resolver)

        XCTAssertEqual(
            model.presetLockHelpText,
            "Preset rules are paused; Flat stays active while you switch apps or websites."
        )
    }

    func testPresetLockActionUsesFocusedActionObject() {
        var requestedLockState: Bool?
        let actions = QuickPanelActions(
            applyEffectivePreset: {},
            selectPreset: { _ in },
            setPresetLock: { requestedLockState = $0 },
            acceptAppPresetSuggestion: {},
            dismissAppPresetSuggestion: {},
            resetAppPresetSuggestionDismissals: {},
            openSettingsWindow: {},
            openPresetsSettings: {},
            showAboutPanel: {},
            quit: {}
        )
        let model = makeModel(actions: actions)

        model.setPresetLock(true)

        XCTAssertEqual(requestedLockState, true)
    }

    func testGearAndPresetActionsUseFocusedActionObject() {
        var selectedPresetID: String?
        var openedSettings = false
        var openedPresets = false
        var openedAbout = false
        var didQuit = false
        let actions = QuickPanelActions(
            applyEffectivePreset: {},
            selectPreset: { selectedPresetID = $0 },
            setPresetLock: { _ in },
            acceptAppPresetSuggestion: {},
            dismissAppPresetSuggestion: {},
            resetAppPresetSuggestionDismissals: {},
            openSettingsWindow: { openedSettings = true },
            openPresetsSettings: { openedPresets = true },
            showAboutPanel: { openedAbout = true },
            quit: { didQuit = true }
        )
        let model = makeModel(actions: actions)

        model.selectPreset(id: "voice")
        model.openSettingsWindow()
        model.openPresetsSettings()
        model.showAboutPanel()
        model.quit()

        XCTAssertEqual(selectedPresetID, "voice")
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(openedPresets)
        XCTAssertTrue(openedAbout)
        XCTAssertTrue(didQuit)
    }

    private func makeModel(
        router providedRouter: TestQuickPanelRouter? = nil,
        inputDeviceController providedInputDeviceController: InputDeviceController? = nil,
        presetStore providedPresetStore: PresetStore? = nil,
        foregroundAppObserver providedForegroundAppObserver: ForegroundAppObserver? = nil,
        activeContextResolver providedActiveContextResolver: ActiveContextPresetResolver? = nil,
        presentationState providedPresentationState: QuickPanelPresentationState? = nil,
        actions providedActions: QuickPanelActions? = nil,
        hasCompletedRoutingOnboarding: Bool = true
    ) -> QuickPanelModel<TestQuickPanelRouter> {
        EqualEaseSettings.hasCompletedRoutingOnboarding = hasCompletedRoutingOnboarding
        let router = providedRouter ?? TestQuickPanelRouter()
        let inputDeviceController = providedInputDeviceController ?? InputDeviceController(host: TestInputDeviceControlHost())
        let presetStore = providedPresetStore ?? PresetStore(persistenceURL: temporaryPresetURL())
        let foregroundAppObserver = providedForegroundAppObserver ?? ForegroundAppObserver()
        let activeContextResolver = providedActiveContextResolver ?? ActiveContextPresetResolver()
        let presentationState = providedPresentationState ?? QuickPanelPresentationState()
        let actions = providedActions ?? .noOp

        return QuickPanelModel(
            router: router,
            inputDeviceController: inputDeviceController,
            presetStore: presetStore,
            foregroundAppObserver: foregroundAppObserver,
            activeContextResolver: activeContextResolver,
            presentationState: presentationState,
            appVolumeStore: AppVolumeStore(persistenceURL: temporaryAppVolumeURL()),
            audioProcessDiscovery: AudioProcessDiscovery(pollingInterval: 60),
            actions: actions
        )
    }

    private func temporaryPresetURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseQuickPanelTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    private func temporaryAppVolumeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseQuickPanelTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("app-volumes.json")
    }
}

@MainActor
private final class TestQuickPanelRouter: AudioRoutingBackend {
    @Published var state: AudioRoutingState = .stopped
    @Published var statusText = "Stopped"
    @Published var outputDeviceName = "MacBook Speakers"
    @Published var outputDeviceUID: String? = "speakers"
    @Published var outputDevices: [AudioOutputDevice] = [
        AudioOutputDevice(uid: "speakers", name: "MacBook Speakers", transport: .builtIn),
        AudioOutputDevice(uid: "headphones", name: "Desk Headphones", transport: .bluetooth),
    ]
    @Published var selectedOutputDeviceUID: String? = "speakers"
    @Published var followsSystemOutput = true
    @Published var isRunning = false
    @Published var isRoutingTransitioning = false
    @Published var isBypassed = false
    @Published var outputVolume = 0.7
    @Published var canSetOutputVolume = true
    @Published var outputGain = 1.0
    @Published var equalizerEnabled = false
    @Published var bandGains = Array(repeating: 0.0, count: 10)

    var startCount = 0
    var stopCount = 0
    var restartCount = 0
    var cleanupCount = 0
    var selectedOutputRequests: [String?] = []

    func setBandGain(_ gain: Double, at index: Int) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = gain
    }

    func selectOutputDevice(uid: String?) {
        selectedOutputRequests.append(uid)
        selectedOutputDeviceUID = uid
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func restart() {
        restartCount += 1
    }

    func cleanupAudioState() {
        cleanupCount += 1
    }
}
