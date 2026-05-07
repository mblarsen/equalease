//
//  SettingsView.swift
//  EqualEase
//

import SwiftUI

enum SettingsTab: Hashable {
    case general
    case presets
    case rules
    case diagnostics
}

struct SettingsView: View {
    @ObservedObject var router: CoreAudioRouter
    @ObservedObject var inputDeviceController: InputDeviceController
    @ObservedObject var localNetworkControlServer: LocalNetworkControlServer
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var foregroundAppObserver: ForegroundAppObserver
    var applyPreset: (EQPreset) -> Void
    var setLocalNetworkControlEnabled: (Bool) -> Void
    @State private var selectedTab: SettingsTab

    init(
        router: CoreAudioRouter,
        inputDeviceController: InputDeviceController,
        localNetworkControlServer: LocalNetworkControlServer,
        presetStore: PresetStore,
        foregroundAppObserver: ForegroundAppObserver,
        selectedTab: SettingsTab = .general,
        applyPreset: @escaping (EQPreset) -> Void,
        setLocalNetworkControlEnabled: @escaping (Bool) -> Void
    ) {
        self.router = router
        self.inputDeviceController = inputDeviceController
        self.localNetworkControlServer = localNetworkControlServer
        self.presetStore = presetStore
        self.foregroundAppObserver = foregroundAppObserver
        self.applyPreset = applyPreset
        self.setLocalNetworkControlEnabled = setLocalNetworkControlEnabled
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                inputDeviceController: inputDeviceController,
                localNetworkControlServer: localNetworkControlServer,
                localNetworkAuthStore: localNetworkControlServer.authStore,
                setLocalNetworkControlEnabled: setLocalNetworkControlEnabled
            )
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            PresetSettingsView(
                router: router,
                presetStore: presetStore,
                applyPreset: applyPreset
            )
            .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            .tag(SettingsTab.presets)

            RulesSettingsView(
                router: router,
                presetStore: presetStore,
                foregroundAppObserver: foregroundAppObserver
            )
            .tabItem { Label("Rules", systemImage: "switch.2") }
            .tag(SettingsTab.rules)

            DiagnosticsSettingsView(router: router, inputDeviceController: inputDeviceController)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
        }
        .frame(width: 760, height: 540)
        .padding(20)
    }
}

#Preview {
    let appModel = EqualEaseAppModel()
    SettingsView(
        router: appModel.router,
        inputDeviceController: appModel.inputDeviceController,
        localNetworkControlServer: appModel.localNetworkControlServer,
        presetStore: appModel.presetStore,
        foregroundAppObserver: appModel.foregroundAppObserver,
        applyPreset: appModel.apply,
        setLocalNetworkControlEnabled: appModel.setLocalNetworkControlEnabled
    )
}
