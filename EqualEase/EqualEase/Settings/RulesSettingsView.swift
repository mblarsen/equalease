//
//  RulesSettingsView.swift
//  EqualEase
//

import SwiftUI

struct RulesSettingsView: View {
    @ObservedObject var router: CoreAudioRouter
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var foregroundAppObserver: ForegroundAppObserver

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset Rules")
                .font(.title2.bold())
            Text("App rules temporarily switch EqualEase while that app is active. When no app rule matches, EqualEase returns to the selected default preset.")
                .foregroundStyle(.secondary)

            Form {
                Section("Create app rule") {
                    LabeledContent("Active app") {
                        HStack {
                            AppIconView(bundleIdentifier: foregroundAppObserver.activeApp?.bundleIdentifier, size: 18)
                            Text(foregroundAppObserver.activeApp?.displayName ?? "None")
                            Button("Use Selected Preset") {
                                presetStore.assignPreset(
                                    id: presetStore.selectedPresetID,
                                    toAppBundleIdentifier: foregroundAppObserver.activeApp?.bundleIdentifier,
                                    displayName: foregroundAppObserver.activeApp?.displayName
                                )
                            }
                            .disabled(foregroundAppObserver.activeApp == nil)
                        }
                    }
                }

            }
            .formStyle(.grouped)
            .frame(maxHeight: 110)

            List {
                Section("Active-app rules") {
                    if appRuleRows.isEmpty {
                        Text("No active-app rules yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appRuleRows) { row in
                            ruleRow(
                                icon: .app(row.bundleIdentifier),
                                title: row.displayName,
                                subtitle: row.bundleIdentifier,
                                presetID: row.presetID
                            ) {
                                presetStore.clearPreset(forAppBundleIdentifier: row.bundleIdentifier)
                            }
                        }
                    }
                }
            }
        }
    }

    private func ruleRow(icon: RuleIcon, title: String, subtitle: String, presetID: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            iconView(icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(presetStore.preset(id: presetID)?.name ?? "Missing preset")
                .foregroundStyle(presetStore.preset(id: presetID) == nil ? .red : .primary)
            Button("Clear", action: clear)
        }
    }

    private var appRuleRows: [AppRuleRow] {
        presetStore.appPresetIDs
            .map { bundleIdentifier, presetID in
                AppRuleRow(
                    bundleIdentifier: bundleIdentifier,
                    displayName: appDisplayName(forBundleIdentifier: bundleIdentifier),
                    presetID: presetID
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func appDisplayName(forBundleIdentifier bundleIdentifier: String) -> String {
        if foregroundAppObserver.activeApp?.bundleIdentifier == bundleIdentifier {
            return foregroundAppObserver.activeApp?.displayName ?? bundleIdentifier
        }
        return presetStore.appDisplayNames[bundleIdentifier] ?? bundleIdentifier
    }

    @ViewBuilder
    private func iconView(_ icon: RuleIcon) -> some View {
        switch icon {
        case let .app(bundleIdentifier):
            AppIconView(bundleIdentifier: bundleIdentifier)
        }
    }

    private enum RuleIcon {
        case app(String)
    }

    private struct AppRuleRow: Identifiable {
        var id: String { bundleIdentifier }
        var bundleIdentifier: String
        var displayName: String
        var presetID: String
    }
}

#Preview {
    RulesSettingsView(
        router: CoreAudioRouter(),
        presetStore: PresetStore(),
        foregroundAppObserver: ForegroundAppObserver()
    )
    .padding()
}
