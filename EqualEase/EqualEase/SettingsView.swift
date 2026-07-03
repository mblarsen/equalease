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
    @ObservedObject var browserPageObserver: BrowserPageObserver
    @ObservedObject var appVolumeStore: AppVolumeStore
    @ObservedObject var audioProcessDiscovery: AudioProcessDiscovery
    var applyPreset: (EQPreset) -> Void
    var setLocalNetworkControlEnabled: (Bool) -> Void
    @State private var selectedTab: SettingsTab

    init(
        router: CoreAudioRouter,
        inputDeviceController: InputDeviceController,
        localNetworkControlServer: LocalNetworkControlServer,
        presetStore: PresetStore,
        foregroundAppObserver: ForegroundAppObserver,
        browserPageObserver: BrowserPageObserver,
        appVolumeStore: AppVolumeStore,
        audioProcessDiscovery: AudioProcessDiscovery,
        selectedTab: SettingsTab = .general,
        applyPreset: @escaping (EQPreset) -> Void,
        setLocalNetworkControlEnabled: @escaping (Bool) -> Void
    ) {
        self.router = router
        self.inputDeviceController = inputDeviceController
        self.localNetworkControlServer = localNetworkControlServer
        self.presetStore = presetStore
        self.foregroundAppObserver = foregroundAppObserver
        self.browserPageObserver = browserPageObserver
        self.appVolumeStore = appVolumeStore
        self.audioProcessDiscovery = audioProcessDiscovery
        self.applyPreset = applyPreset
        self.setLocalNetworkControlEnabled = setLocalNetworkControlEnabled
        _selectedTab = State(initialValue: selectedTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                settingsTabButton(.general, title: String(localized: "General", comment: "Settings tab title for general app settings."), systemImage: "gearshape")
                settingsTabButton(.presets, title: String(localized: "Presets", comment: "Settings tab title for preset settings."), systemImage: "slider.horizontal.3")
                settingsTabButton(.rules, title: String(localized: "Rules", comment: "Settings tab title for preset rule settings."), systemImage: "switch.2")
                settingsTabButton(.diagnostics, title: String(localized: "Diagnostics", comment: "Settings tab title for diagnostics settings."), systemImage: "stethoscope")
                Spacer()
            }

            Divider()

            selectedTabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 540)
        .padding(20)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(
                inputDeviceController: inputDeviceController,
                localNetworkControlServer: localNetworkControlServer,
                localNetworkAuthStore: localNetworkControlServer.authStore,
                setLocalNetworkControlEnabled: setLocalNetworkControlEnabled
            )
        case .presets:
            PresetSettingsView(
                router: router,
                presetStore: presetStore,
                applyPreset: applyPreset
            )
        case .rules:
            RulesSettingsView(
                router: router,
                presetStore: presetStore,
                foregroundAppObserver: foregroundAppObserver,
                browserPageObserver: browserPageObserver
            )
        case .diagnostics:
            DiagnosticsSettingsView(
                router: router,
                inputDeviceController: inputDeviceController,
                appVolumeStore: appVolumeStore,
                audioProcessDiscovery: audioProcessDiscovery
            )
        }
    }

    private func settingsTabButton(_ tab: SettingsTab, title: String, systemImage: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(selectedTab == tab ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(selectedTab == tab ? .white : .primary)
                .background(
                    selectedTab == tab ? Color.accentColor : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
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
        browserPageObserver: appModel.browserPageObserver,
        appVolumeStore: appModel.appVolumeStore,
        audioProcessDiscovery: appModel.audioProcessDiscovery,
        applyPreset: appModel.apply,
        setLocalNetworkControlEnabled: appModel.setLocalNetworkControlEnabled
    )
}
