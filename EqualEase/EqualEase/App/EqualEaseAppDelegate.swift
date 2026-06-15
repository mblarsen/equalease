//
//  EqualEaseAppDelegate.swift
//  EqualEase
//

import AppKit
import SwiftUI

@MainActor
final class EqualEaseAppDelegate: NSObject, NSApplicationDelegate {
    let appModel = EqualEaseAppModel()

    private var quickPanelAdapter: MenuBarQuickPanelAdapter?
    private var managementWindow: NSWindow?
    private var autoStartTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EqualEaseAutomation.shared.configure(appModel: appModel)
        registerURLHandler()
        setApplicationIcon()
        NSApplication.shared.setActivationPolicy(.regular)
        installQuickPanelAdapter()
        appModel.startLocalNetworkControlIfEnabled()
        scheduleLaunchRoutingOrOnboarding()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            quickPanelAdapter?.show()
        }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        quickPanelAdapter?.hide()
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoStartTask?.cancel()
        quickPanelAdapter?.tearDown()
        appModel.shutdown()
    }

    func showAboutPanel() {
        quickPanelAdapter?.hide()

        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = applicationIcon() {
            options[.applicationIcon] = icon
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    func showManagementWindow(selectedTab: SettingsTab = .general) {
        quickPanelAdapter?.hide()

        if managementWindow == nil {
            managementWindow = makeManagementWindow(selectedTab: selectedTab)
        } else {
            managementWindow?.contentViewController = makeManagementContentController(selectedTab: selectedTab)
        }

        managementWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func installQuickPanelAdapter() {
        let adapter = MenuBarQuickPanelAdapter(
            appModel: appModel,
            openManagementWindow: { [weak self] selectedTab in
                self?.showManagementWindow(selectedTab: selectedTab)
            },
            openAboutPanel: { [weak self] in
                self?.showAboutPanel()
            }
        )
        adapter.install()
        quickPanelAdapter = adapter
    }

    private func scheduleLaunchRoutingOrOnboarding() {
        autoStartTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.quickPanelAdapter?.prewarm()

            if EqualEaseSettings.shouldPresentRoutingOnboarding {
                self?.quickPanelAdapter?.show()
                return
            }

            guard EqualEaseSettings.startAudioRoutingAtLaunch else { return }
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.appModel.autoStartRouting()
        }
    }

    private func setApplicationIcon() {
        guard let icon = applicationIcon() else { return }

        NSApplication.shared.applicationIconImage = icon
    }

    private func applicationIcon() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL)
        else { return nil }

        icon.size = NSSize(width: 64, height: 64)
        return icon
    }

    private func registerURLHandler() {
        let eventManager = NSAppleEventManager.shared()
        eventManager.setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        let automationEventClass = AEEventClass(Self.fourCharacterCode("EEqs"))
        for (eventID, selector) in [
            ("LPst", #selector(handleListPresetsEvent(_:withReplyEvent:))),
            ("SPst", #selector(handleSelectPresetEvent(_:withReplyEvent:))),
            ("GPre", #selector(handleCurrentPresetNameEvent(_:withReplyEvent:))),
            ("SPre", #selector(handleSetPreampEvent(_:withReplyEvent:))),
            ("GPlv", #selector(handleCurrentPreampEvent(_:withReplyEvent:))),
            ("SVol", #selector(handleSetOutputVolumeEvent(_:withReplyEvent:))),
            ("GVol", #selector(handleCurrentOutputVolumeEvent(_:withReplyEvent:))),
            ("SByp", #selector(handleSetBypassEvent(_:withReplyEvent:))),
            ("GByp", #selector(handleBypassStateEvent(_:withReplyEvent:))),
            ("TByp", #selector(handleToggleBypassEvent(_:withReplyEvent:))),
            ("SAct", #selector(handleSetActiveEvent(_:withReplyEvent:))),
            ("GAct", #selector(handleActiveStateEvent(_:withReplyEvent:))),
            ("TAct", #selector(handleToggleActiveEvent(_:withReplyEvent:))),
            ("LPrs", #selector(handleLockPresetEvent(_:withReplyEvent:))),
            ("UPrs", #selector(handleUnlockPresetEvent(_:withReplyEvent:))),
            ("GPlk", #selector(handlePresetLockStateEvent(_:withReplyEvent:))),
            ("TPlk", #selector(handleTogglePresetLockEvent(_:withReplyEvent:))),
        ] {
            eventManager.setEventHandler(
                self,
                andSelector: selector,
                forEventClass: automationEventClass,
                andEventID: AEEventID(Self.fourCharacterCode(eventID))
            )
        }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else {
            NSLog("EqualEase URL automation: missing or invalid URL event")
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            do {
                try EqualEaseAutomation.shared.handle(url: url)
            } catch {
                NSLog("EqualEase URL automation failed for %@: %@", urlString, error.localizedDescription)
            }
        }
    }

    @objc private func handleListPresetsEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.listPresets, event: event, replyEvent: replyEvent)
    }

    @objc private func handleSelectPresetEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.selectPreset, event: event, replyEvent: replyEvent)
    }

    @objc private func handleCurrentPresetNameEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.currentPresetName, event: event, replyEvent: replyEvent)
    }

    @objc private func handleSetPreampEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.setPreamp, event: event, replyEvent: replyEvent)
    }

    @objc private func handleCurrentPreampEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.currentPreamp, event: event, replyEvent: replyEvent)
    }

    @objc private func handleSetOutputVolumeEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.setOutputVolume, event: event, replyEvent: replyEvent)
    }

    @objc private func handleCurrentOutputVolumeEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.currentOutputVolume, event: event, replyEvent: replyEvent)
    }

    @objc private func handleSetBypassEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.setBypass, event: event, replyEvent: replyEvent)
    }

    @objc private func handleBypassStateEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.bypassState, event: event, replyEvent: replyEvent)
    }

    @objc private func handleToggleBypassEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.toggleBypass, event: event, replyEvent: replyEvent)
    }

    @objc private func handleSetActiveEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.setActive, event: event, replyEvent: replyEvent)
    }

    @objc private func handleActiveStateEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.activeState, event: event, replyEvent: replyEvent)
    }

    @objc private func handleToggleActiveEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.toggleActive, event: event, replyEvent: replyEvent)
    }

    @objc private func handleLockPresetEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.lockPreset, event: event, replyEvent: replyEvent)
    }

    @objc private func handleUnlockPresetEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.unlockPreset, event: event, replyEvent: replyEvent)
    }

    @objc private func handlePresetLockStateEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.presetLockState, event: event, replyEvent: replyEvent)
    }

    @objc private func handleTogglePresetLockEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        handleAppleScriptCommand(.togglePresetLock, event: event, replyEvent: replyEvent)
    }

    private func handleAppleScriptCommand(
        _ appleScriptCommand: EqualEaseAppleScriptCommand,
        event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        do {
            let command = try EqualEaseAppleScriptAdapter.automationCommand(for: appleScriptCommand, event: event)
            let result = try EqualEaseAutomation.shared.execute(command)
            EqualEaseAppleScriptAdapter.setResult(result, on: replyEvent)
        } catch {
            EqualEaseAppleScriptAdapter.setError(error, on: replyEvent)
        }
    }

    private static func fourCharacterCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }

    private func makeManagementContentController(selectedTab: SettingsTab) -> NSHostingController<SettingsView> {
        let contentView = SettingsView(
            router: appModel.router,
            inputDeviceController: appModel.inputDeviceController,
            localNetworkControlServer: appModel.localNetworkControlServer,
            presetStore: appModel.presetStore,
            foregroundAppObserver: appModel.foregroundAppObserver,
            browserPageObserver: appModel.browserPageObserver,
            selectedTab: selectedTab,
            applyPreset: appModel.apply,
            setLocalNetworkControlEnabled: appModel.setLocalNetworkControlEnabled
        )
        return NSHostingController(rootView: contentView)
    }

    private func makeManagementWindow(selectedTab: SettingsTab) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EqualEase Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = makeManagementContentController(selectedTab: selectedTab)
        return window
    }
}
