//
//  ContentView.swift
//  EqualEase
//
//

import AppKit
import SwiftUI

struct ContentView<Router: AudioRoutingBackend>: View {
    @ObservedObject var model: QuickPanelModel<Router>

    @Environment(\.colorScheme) private var colorScheme
    @State private var restoreRoutingAtLaunch = true

    private var router: Router { model.router }
    private var inputDeviceController: InputDeviceController { model.inputDeviceController }
    private var presetStore: PresetStore { model.presetStore }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.presentationState.showsPointer {
                    HeaderPointer()
                        .fill(headerGradient)
                        .frame(width: 22, height: 12)
                        .transition(.opacity)
                }
            }
            .frame(height: 12)
            .padding(.bottom, -1)
            .animation(.easeOut(duration: 0.12), value: model.presentationState.showsPointer)

            ZStack(alignment: .top) {
                panelSurface

                VStack(spacing: 0) {
                    header
                    VStack(spacing: 0) {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 10) {
                                if model.shouldShowRoutingOnboarding {
                                    routingOnboarding
                                } else {
                                    presetSelection
                                    levelControls
                                    inputControls
                                    appLearningPrompt
                                    secondaryControls
                                }
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }

                        Divider()
                            .padding(.horizontal, 16)

                        footerActions
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 10)
                    }
                    .background(panelSurface)
                }
            }
            .frame(width: QuickPanelModel<Router>.panelWidth, height: model.panelBodyHeight, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .background(Color.clear)
        .frame(width: QuickPanelModel<Router>.panelWidth, height: model.preferredPanelHeight, alignment: .topLeading)
        .onAppear {
            model.onAppear()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "EqualEase")!)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.white.opacity(0.92))

            VStack(alignment: .leading, spacing: 2) {
                Text("EqualEase")
                    .font(.headline.weight(.semibold))
                Text(model.effectivePresetSummary)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .opacity(0.8)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            statusBadge
                .frame(minWidth: 64, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(height: 58)
        .background(headerGradient)
    }

    private var statusBadge: some View {
        Text(model.statusTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var routingOnboarding: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.wave.2.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(red: 0.94, green: 0.39, blue: 0.11))
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("Turn On EqualEase")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Route system audio locally through this Mac so EqualEase can apply EQ before playback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Audio stays on this Mac", systemImage: "lock")
                Label("macOS asks for capture permission when routing starts", systemImage: "checkmark.shield")
                Label("You can turn EqualEase off anytime", systemImage: "power")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)

            Toggle("Start audio routing automatically on future launches", isOn: $restoreRoutingAtLaunch)
                .font(.caption)
                .toggleStyle(.checkbox)
                .accessibilityHint("When enabled, EqualEase may restore audio routing after you launch the app.")

            VStack(spacing: 6) {
                Button {
                    model.startRoutingFromOnboarding(restoreAtLaunch: restoreRoutingAtLaunch)
                } label: {
                    Text("Turn On EqualEase")
                        .frame(width: 172)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(router.isRoutingTransitioning)
                .accessibilityHint("Starts local system audio routing and may show the macOS audio capture permission prompt.")

                Button("Not Now") {
                    model.dismissRoutingOnboarding()
                }
                .buttonStyle(.link)
                .controlSize(.regular)
                .accessibilityHint("Keep EqualEase off and show the normal controls.")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var presetSelection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset")
                .font(.caption.weight(.semibold))

            HStack(spacing: 8) {
                presetMenu
                    .layoutPriority(1)

                Button("Manage") {
                    model.openPresetsSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Manage presets")
                .help("Open Presets settings")
            }

            Toggle("Pause app preset switching", isOn: Binding(
                get: { model.isPresetLocked },
                set: { isLocked in
                    model.setPresetLock(isLocked)
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .help(model.presetLockHelpText)

            Text(model.presetLockHelpText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var levelControls: some View {
        if model.showsLevelControls {
            VStack(alignment: .leading, spacing: 8) {
                if model.showsVolumeControls {
                    levelSlider(
                        title: "Volume",
                        value: Binding(
                            get: { router.outputVolume },
                            set: { router.outputVolume = $0 }
                        ),
                        range: 0...1,
                        percentage: Int(router.outputVolume * 100),
                        isEnabled: router.canSetOutputVolume,
                        helpText: "Convenience control for your Mac’s output volume. Use this first for everyday loudness.",
                        hideAction: { model.hideVolumeControls() }
                    )

                    appVolumeSection
                }

                if model.showsPreampControls {
                    levelSlider(
                        title: "Preamp",
                        value: Binding(
                            get: { router.outputGain },
                            set: { router.outputGain = $0 }
                        ),
                        range: 0...2,
                        percentage: Int(router.outputGain * 100),
                        isEnabled: router.isRunning,
                        helpText: "Changes EqualEase’s processing level while Active is on. Use Volume first; lower Preamp if boosted presets distort.",
                        hideAction: { model.hidePreampControls() }
                    )
                }
            }
        }
    }

    private func levelSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        percentage: Int,
        isEnabled: Bool,
        helpText: String,
        hideAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Button("Hide") {
                    hideAction()
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel("Hide \(title.lowercased()) controls")

                Spacer()
                Text("\(percentage)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)
                .tint(Color(red: 0.94, green: 0.39, blue: 0.11))
                .disabled(!isEnabled)
                .accessibilityLabel(title)

            Text(helpText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inputControls: some View {
        if model.showsInputSection {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Input Volume")
                        .font(.caption.weight(.semibold))
                    Button("Hide") {
                        model.hideInputVolumeControls()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Hide input volume controls")

                    Spacer()

                    Text(inputVolumeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: Binding(
                    get: { inputDeviceController.inputVolume },
                    set: { inputDeviceController.inputVolume = $0 }
                ), in: 0...1)
                .tint(Color(red: 0.94, green: 0.39, blue: 0.11))
                .disabled(!inputDeviceController.canSetInputVolume)
                .accessibilityLabel("Input Volume")

                Text(inputVolumeHelpText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(model.currentInputDeviceName, systemImage: "mic.fill")
                    .padding(.top, 3)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Current input device: \(model.currentInputDeviceName)")
            }
        }
    }

    private var inputVolumeSummary: String {
        inputDeviceController.canReadInputVolume
            ? "\(Int(inputDeviceController.inputVolume * 100))%"
            : "—"
    }

    private var inputVolumeHelpText: String {
        if inputDeviceController.canSetInputVolume {
            return "Convenience control for your Mac’s current microphone input level. It stays editable even while EqualEase is off."
        }
        if inputDeviceController.canReadInputVolume {
            return "EqualEase can read this input’s volume, but this device does not expose volume control."
        }
        return "This input does not expose volume control. Use System Settings or the device’s own controls if available."
    }

    private var outputDevicePicker: some View {
        Picker("", selection: Binding(
            get: { router.selectedOutputDeviceUID },
            set: { uid in
                router.selectOutputDevice(uid: uid)
            }
        )) {
            ForEach(router.outputDevices) { device in
                Label(device.name, systemImage: device.iconSystemName)
                    .tag(Optional(device.uid))
            }
        }
        .labelsHidden()
        .accessibilityLabel("Output device")
        .pickerStyle(.menu)
        .disabled(!router.isRunning || router.followsSystemOutput || router.isRoutingTransitioning)
    }

    private var presetMenu: some View {
        Menu {
            Section("Speech") {
                presetButtons(for: presets(named: ["Voice Boost", "Podcast"]))
            }

            Section("Music") {
                presetButtons(for: presets(named: ["Bass Boost", "Treble Boost", "Warm", "Loudness"]))
            }

            Section("Utility") {
                presetButtons(for: presets(named: ["Flat", "De-Mud", "Night Mode", "Small Speakers", "Reduce Rumble", "Muffled"]))
            }

            if !presetStore.customPresets.isEmpty {
                Section("Custom") {
                    presetButtons(for: presetStore.customPresets)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedPresetName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(presetMenuForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(presetMenuBackground)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 1, y: 1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func presetButtons(for presets: [EQPreset]) -> some View {
        ForEach(presets) { preset in
            Button(preset.name) {
                model.selectPreset(id: preset.id)
            }
        }
    }

    private func presets(named names: [String]) -> [EQPreset] {
        names.compactMap { name in
            presetStore.builtInPresets.first { $0.name == name }
        }
    }

    @ViewBuilder
    private var appVolumeSection: some View {
        if model.showsAppVolumeSection && model.isAppVolumeAvailable {
            VStack(alignment: .leading, spacing: 4) {
                if model.discoveredApps.isEmpty {
                    Text("No audio-emitting apps detected.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.discoveredApps, id: \.bundleID) { app in
                        appVolumeRow(app: app)
                    }
                }
            }
        }
    }

    private func appVolumeRow(app: AudioAppIdentity) -> some View {
        HStack(spacing: 6) {
            if let icon = icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 14, height: 14)
            }

            Text(app.displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)

            let mode = model.appVolumeStore.mode(for: app.bundleID)
            let isMuted = mode == .mute
            let underlyingMode = model.underlyingMode(for: app.bundleID)
            let isProcessing = underlyingMode == .on

            Slider(
                value: Binding(
                    get: { model.appVolumeStore.volume(for: app.bundleID) },
                    set: { model.setAppVolume($0, for: app.bundleID) }
                ),
                in: 0...1
            )
            .tint(Color(red: 0.94, green: 0.39, blue: 0.11))
            .disabled(isMuted || !isProcessing)
            .help("Per-app volume is attenuation only: 100% is normal volume. Use Preamp for global boost.")

            HStack(spacing: 4) {
                // Process/Bypass toggle
                Button(action: {
                    model.toggleAppProcessBypass(for: app.bundleID)
                }) {
                    Text(isProcessing ? "Process" : "Bypass")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(isProcessing ? .white : .secondary)
                        .frame(width: 58)
                        .padding(.vertical, 3)
                        .background(
                            isProcessing
                                ? Color(red: 0.94, green: 0.39, blue: 0.11)
                                : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .opacity(isMuted ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isMuted)

                // Mute toggle
                Button(action: {
                    model.toggleAppMute(for: app.bundleID)
                }) {
                    Text("Mute")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(isMuted ? .white : .secondary)
                        .frame(width: 44)
                        .padding(.vertical, 3)
                        .background(
                            isMuted
                                ? Color(red: 0.94, green: 0.39, blue: 0.11)
                                : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
            .help(isMuted
                ? "Muted: silence this app."
                : isProcessing
                    ? "Process: app volume then global EQ."
                    : "Bypass: pass through unprocessed.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.displayName) volume")
    }

    @ViewBuilder
    private var secondaryControls: some View {
        if model.showsRoutingSection {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Routing")
                        .font(.caption.weight(.semibold))
                    Button("Hide") {
                        model.hideRoutingControls()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityLabel("Hide routing controls")
                }

                Toggle("Follow system output", isOn: Binding(
                    get: { router.followsSystemOutput },
                    set: { router.followsSystemOutput = $0 }
                ))
                .controlSize(.small)
                .disabled(!router.isRunning || router.isRoutingTransitioning)

                outputDevicePicker

                Text("Choose where processed audio is sent. Follow system output keeps it matched to your Mac’s current output.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var appLearningPrompt: some View {
        if let suggestion = model.appLearningPrompt {
            VStack(alignment: .leading, spacing: 8) {
                Label(suggestion.title, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Remember") {
                        model.acceptAppPresetSuggestion()
                    }
                    .controlSize(.small)

                    Button("Not Now") {
                        model.dismissAppPresetSuggestion()
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func icon(for app: AudioAppIdentity) -> NSImage? {
        NSWorkspace.shared.runningApplications.first { runningApp in
            runningApp.processIdentifier == app.pid || runningApp.bundleIdentifier == app.bundleID
        }?.icon
    }

    private var footerActions: some View {
        HStack {
            if !model.shouldShowRoutingOnboarding {
                Toggle("Active", isOn: Binding(
                    get: { model.isActive },
                    set: { isActive in
                        model.setActive(isActive)
                    }
                ))
                .controlSize(.small)
                .disabled(router.isRoutingTransitioning)
                .help("When Active is off, EqualEase stops routing audio instead of only bypassing processing.")
            }

            Spacer()

            Menu {
                Button("About EqualEase") {
                    model.showAboutPanel()
                }

                Button("Settings") {
                    model.openSettingsWindow()
                }
                .keyboardShortcut(",")

                Divider()

                Button("Quit EqualEase") {
                    model.quit()
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.button)
            .help("More")
        }
        .controlSize(.small)
    }

    private var headerGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.48, blue: 0.12),
                Color(red: 0.94, green: 0.39, blue: 0.11),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var panelSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.14, green: 0.14, blue: 0.13)
            : Color(red: 0.98, green: 0.98, blue: 0.96)
    }

    private var presetMenuBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.19, blue: 0.17)
            : .white
    }

    private var presetMenuForeground: Color {
        colorScheme == .dark
            ? .white.opacity(0.92)
            : Color(red: 0.12, green: 0.08, blue: 0.05)
    }
}

private struct HeaderPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    let router = CoreAudioRouter()
    let presetStore = PresetStore()
    let foregroundAppObserver = ForegroundAppObserver()
    let activeContextResolver = ActiveContextPresetResolver()
    return ContentView(model: QuickPanelModel(
        router: router,
        inputDeviceController: InputDeviceController(),
        presetStore: presetStore,
        foregroundAppObserver: foregroundAppObserver,
        activeContextResolver: activeContextResolver,
        presentationState: QuickPanelPresentationState(),
        appVolumeStore: AppVolumeStore(),
        audioProcessDiscovery: AudioProcessDiscovery(pollingInterval: 60),
        actions: .noOp
    ))
}
