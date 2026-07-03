//
//  GeneralSettingsView.swift
//  EqualEase
//

import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class LaunchAtLoginSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var canChange = true
    @Published private(set) var needsSystemApproval = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var statusText = String(localized: "Launch at Login: Off", defaultValue: "Off", comment: "Launch-at-login status when EqualEase will not launch automatically.")
    @Published var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        canChange = status != .notFound
        needsSystemApproval = status == .requiresApproval
        isUnavailable = status == .notFound
        statusText = Self.description(for: status)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    private static func description(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return String(localized: "Launch at Login: On", defaultValue: "On", comment: "Launch-at-login status when EqualEase will launch automatically.")
        case .notRegistered:
            return String(localized: "Launch at Login: Off", defaultValue: "Off", comment: "Launch-at-login status when EqualEase will not launch automatically.")
        case .requiresApproval:
            return String(localized: "Needs approval", comment: "Launch-at-login status when macOS requires user approval in System Settings.")
        case .notFound:
            return String(localized: "Unavailable in this build", comment: "Launch-at-login status for development builds that cannot be registered as login items.")
        @unknown default:
            return String(localized: "Launch at Login: Unknown", defaultValue: "Unknown", comment: "Fallback status when launch-at-login state cannot be determined.")
        }
    }
}

struct GeneralSettingsView: View {
    @StateObject private var launchAtLogin = LaunchAtLoginSettings()
    @ObservedObject var inputDeviceController: InputDeviceController
    @ObservedObject var localNetworkControlServer: LocalNetworkControlServer
    @ObservedObject var localNetworkAuthStore: LocalNetworkAuthStore
    var setLocalNetworkControlEnabled: (Bool) -> Void
    @AppStorage(EqualEaseSettings.allowsExternalAutomationWritesKey) private var allowsExternalAutomationWrites = false
    @AppStorage(EqualEaseSettings.localNetworkRemoteEnabledKey) private var localNetworkRemoteEnabled = false
    @AppStorage(EqualEaseSettings.startAudioRoutingAtLaunchKey) private var startAudioRoutingAtLaunch = false
    @AppStorage(EqualEaseSettings.showsQuickPanelVolumeKey) private var showsQuickPanelVolume = true
    @AppStorage(EqualEaseSettings.showsQuickPanelPreampKey) private var showsQuickPanelPreamp = true
    @AppStorage(EqualEaseSettings.showsQuickPanelInputVolumeKey) private var showsQuickPanelInputVolume = true
    @AppStorage(EqualEaseSettings.showsQuickPanelRoutingKey) private var showsQuickPanelRouting = true
    @AppStorage(EqualEaseSettings.showsQuickPanelAppVolumeKey) private var showsQuickPanelAppVolume = true

    var body: some View {
        Form {
            Section("Login") {
                Toggle("Launch EqualEase when you log in", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .disabled(!launchAtLogin.canChange)

                LabeledContent("Status", value: launchAtLogin.statusText)

                if launchAtLogin.isUnavailable {
                    Text("macOS cannot register this build as a login item. Copy EqualEase to Applications or use a packaged build, then reopen Settings.")
                        .foregroundStyle(.secondary)
                }

                if launchAtLogin.needsSystemApproval {
                    Text("Approve EqualEase in System Settings > General > Login Items to finish enabling launch at login.")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Toggle("Start audio routing automatically after launch", isOn: $startAudioRoutingAtLaunch)

                Text("EqualEase can launch quietly in the menu bar. Audio routing stays off until you turn it on, unless you explicitly enable automatic routing here. Audio processing happens locally on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Section("Quick Panel") {
                Toggle("Show volume in the quick panel", isOn: $showsQuickPanelVolume)
                Toggle("Show preamp in the quick panel", isOn: $showsQuickPanelPreamp)
                Toggle("Show input volume in the quick panel", isOn: $showsQuickPanelInputVolume)
                Toggle("Show app volume in the quick panel", isOn: $showsQuickPanelAppVolume)
                Toggle("Show routing controls in the quick panel", isOn: $showsQuickPanelRouting)

                Text("When these are off, the quick panel hides the matching section and shrinks to fit. Diagnostics still shows routing, input state, and discovered app audio state.")
                    .foregroundStyle(.secondary)
            }

            Section("Low Microphone Volume Protection") {
                Toggle("Notify me when microphone input volume is low", isOn: Binding(
                    get: { inputDeviceController.protectionSettings.notificationsEnabled },
                    set: { inputDeviceController.protectionSettings.notificationsEnabled = $0 }
                ))

                HStack {
                    Slider(value: Binding(
                        get: { inputDeviceController.protectionSettings.threshold },
                        set: { inputDeviceController.protectionSettings.threshold = $0 }
                    ), in: 0...1)
                    Text("\(Int(inputDeviceController.protectionSettings.threshold * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                LabeledContent("Low-volume threshold") { EmptyView() }
                    .labelsHidden()

                Toggle("Automatically raise supported microphones to a minimum", isOn: Binding(
                    get: { inputDeviceController.protectionSettings.capEnabled },
                    set: { inputDeviceController.protectionSettings.capEnabled = $0 }
                ))

                HStack {
                    Slider(value: Binding(
                        get: { inputDeviceController.protectionSettings.capMinimum },
                        set: { inputDeviceController.protectionSettings.capMinimum = max($0, inputDeviceController.protectionSettings.threshold) }
                    ), in: inputDeviceController.protectionSettings.threshold...1)
                    Text("\(Int(inputDeviceController.protectionSettings.capMinimum * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                LabeledContent("Current status", value: inputDeviceController.lowVolumeProtectionStatus)
                LabeledContent("Notification permission", value: inputDeviceController.notificationAuthorizationStatus.summary)

                if inputDeviceController.notificationAuthorizationStatus == .notRequested {
                    Button("Allow Notifications…") {
                        inputDeviceController.requestNotificationPermission()
                    }
                }

                Text("Default threshold is 35% and default cap minimum is 50%. EqualEase only watches macOS input volume and posts local notifications on this Mac; it does not capture, route, process, boost, EQ, save, or upload microphone audio.")
                    .foregroundStyle(.secondary)
            }

            Section("Local Network Remote") {
                Toggle("Allow phone remote control on the local network", isOn: Binding(
                    get: { localNetworkRemoteEnabled },
                    set: { enabled in
                        localNetworkRemoteEnabled = enabled
                        setLocalNetworkControlEnabled(enabled)
                    }
                ))

                LabeledContent("Status", value: localNetworkControlServer.state.statusText)

                HStack {
                    Button("Pair New Remote…") {
                        _ = localNetworkAuthStore.beginPairing()
                    }
                    .disabled(!localNetworkRemoteEnabled)

                    if localNetworkAuthStore.pairingSession != nil {
                        Button("Cancel Pairing") {
                            localNetworkAuthStore.cancelPairing()
                        }
                    }

                    Spacer()

                    Button("Reset Pairings", role: .destructive) {
                        localNetworkAuthStore.reset()
                    }
                    .disabled(localNetworkAuthStore.clients.isEmpty && localNetworkAuthStore.pairingSession == nil)
                }

                if let session = localNetworkAuthStore.pairingSession {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.code)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Enter this code on the phone remote. It expires at \(session.expiresAt.formatted(date: .omitted, time: .shortened)) and is used only once.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if localNetworkAuthStore.clients.isEmpty {
                    Text("No paired remotes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localNetworkAuthStore.clients) { client in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading) {
                                Text(client.name)
                                Text("Paired \(client.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                localNetworkAuthStore.revoke(clientID: client.id)
                            }
                        }
                    }
                }

                Text("When enabled, EqualEase requires a paired remote before it sends detailed state or accepts control commands. Keep this for trusted local networks: traffic is same-LAN only and not internet-grade encrypted. Pairing codes and tokens are never exposed through /health, /info, logs, or Settings after initial pairing.")
                    .foregroundStyle(.secondary)
            }

            Section("External Automation") {
                Toggle("Allow automation to change sound settings", isOn: $allowsExternalAutomationWrites)

                Text("When this is off, equalease:// links and AppleScript can still read EqualEase state and select built-in presets, but they cannot change Active, Volume, Preamp, Bypass, whether app preset switching is paused, or custom presets.")
                    .foregroundStyle(.secondary)
            }

            Section("Support & Privacy") {
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
                Link("Support / Contact", destination: Self.supportURL)

                Text("EqualEase processes audio locally on this Mac. It does not record, save, upload, sell, or share audio.")
                    .foregroundStyle(.secondary)
            }

            Section("Version") {
                LabeledContent("Version", value: appVersionText)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 620, alignment: .leading)
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    private static let privacyPolicyURL = URL(string: "https://github.com/mblarsen/equalease/blob/main/docs/privacy.md")!
    private static let supportURL = URL(string: "https://github.com/mblarsen/equalease/issues")!

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return String(
                localized: "build \(build)",
                comment: "Version label when only the build number is known. Interpolation is CFBundleVersion."
            )
        default:
            return String(localized: "development build", comment: "Version label when no app version/build metadata is available.")
        }
    }
}

#Preview {
    let appModel = EqualEaseAppModel()
    GeneralSettingsView(
        inputDeviceController: appModel.inputDeviceController,
        localNetworkControlServer: appModel.localNetworkControlServer,
        localNetworkAuthStore: appModel.localNetworkControlServer.authStore,
        setLocalNetworkControlEnabled: appModel.setLocalNetworkControlEnabled
    )
    .padding()
}
