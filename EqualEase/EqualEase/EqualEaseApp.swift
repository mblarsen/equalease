//
//  EqualEaseApp.swift
//  EqualEase
//
//

import SwiftUI

private let applyLanguageOverrideAtStartup: Void = {
    EqualEaseSettings.applyStoredLanguageOverrideForLaunch()
}()

@main
struct EqualEaseApp: App {
    init() {
        _ = applyLanguageOverrideAtStartup
    }

    @NSApplicationDelegateAdaptor(EqualEaseAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                router: appDelegate.appModel.router,
                inputDeviceController: appDelegate.appModel.inputDeviceController,
                localNetworkControlServer: appDelegate.appModel.localNetworkControlServer,
                presetStore: appDelegate.appModel.presetStore,
                foregroundAppObserver: appDelegate.appModel.foregroundAppObserver,
                browserPageObserver: appDelegate.appModel.browserPageObserver,
                appVolumeStore: appDelegate.appModel.appVolumeStore,
                audioProcessDiscovery: appDelegate.appModel.audioProcessDiscovery,
                applyPreset: appDelegate.appModel.apply,
                setLocalNetworkControlEnabled: appDelegate.appModel.setLocalNetworkControlEnabled
            )
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About EqualEase") {
                    appDelegate.showAboutPanel()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Manage EqualEase…") {
                    appDelegate.showManagementWindow()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
