//
//  RulesSettingsView.swift
//  EqualEase
//

import SwiftUI

struct RulesSettingsView: View {
    @ObservedObject var router: CoreAudioRouter
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var foregroundAppObserver: ForegroundAppObserver
    @ObservedObject var browserPageObserver: BrowserPageObserver

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset Rules")
                .font(.title2.bold())
            Text("Rules temporarily switch EqualEase based on what you're focused on. Website rules apply when that website is the active tab in a supported browser. When no rule matches, EqualEase returns to the selected default preset.")
                .foregroundStyle(.secondary)

            currentFocusCard

            rulesSection
        }
        .task {
            await rulesActions.refreshBrowserPageForRulesScreen()
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rules")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            if websiteRuleRows.isEmpty && appRuleRows.isEmpty {
                Text("No preset rules yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                ForEach(websiteRuleRows) { row in
                    ruleRow(
                        icon: .website,
                        title: row.displayName,
                        subtitle: "Website",
                        presetID: row.presetID
                    ) {
                        rulesActions.clearWebsiteRule(siteKey: row.siteKey)
                    }

                    Divider()
                        .padding(.leading, 52)
                }

                ForEach(appRuleRows) { row in
                    ruleRow(
                        icon: .app(row.bundleIdentifier),
                        title: row.displayName,
                        subtitle: "Application",
                        presetID: row.presetID
                    ) {
                        rulesActions.clearAppRule(bundleIdentifier: row.bundleIdentifier)
                    }

                    Divider()
                        .padding(.leading, 52)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentFocusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current focus")
                .font(.headline)

            if let activeApp = foregroundAppObserver.activeApp {
                currentFocusRow(
                    icon: .app(activeApp.bundleIdentifier),
                    title: activeApp.displayName,
                    subtitle: "Active app"
                ) {
                    rulesActions.assignSelectedPreset(to: activeApp)
                }
            } else {
                Text("No active app detected.")
                    .foregroundStyle(.secondary)
            }

            if let activePage = browserPageObserver.activePage {
                currentFocusRow(
                    icon: .website,
                    title: activePage.displayName,
                    subtitle: "Active website",
                    buttonTitle: websiteRuleButtonTitle(for: activePage)
                ) {
                    rulesActions.assignSelectedPreset(to: activePage)
                }
            } else if browserPageObserver.isSupportedBrowserForeground {
                currentFocusRow(
                    icon: .website,
                    title: currentBrowserPageTitle,
                    subtitle: "Read the active page only when you choose it",
                    buttonTitle: "Use Preset"
                ) {
                    rulesActions.requestCurrentBrowserPageAndAssignSelectedPreset()
                }

                if browserPageObserver.didFailLastUserRequest {
                    Text("EqualEase couldn't read \(currentBrowserName)'s current page. Check macOS Automation permission for EqualEase, then try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var currentBrowserName: String {
        browserPageObserver.supportedBrowserDisplayName ?? "the browser"
    }

    private var currentBrowserPageTitle: String {
        if let browserDisplayName = browserPageObserver.supportedBrowserDisplayName {
            return "Current \(browserDisplayName) page"
        }
        return "Current web page"
    }

    private func websiteRuleButtonTitle(for activePage: BrowserPageIdentity) -> String {
        presetStore.websitePresetIDs[activePage.siteKey] == nil ? "Use Preset" : "Update Preset"
    }

    private var rulesActions: RulesSettingsActions {
        RulesSettingsActions(
            presetStore: presetStore,
            browserPageObserver: browserPageObserver
        )
    }

    private func currentFocusRow(icon: RuleIcon, title: String, subtitle: String, buttonTitle: String = "Use Preset", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            iconView(icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .controlSize(.small)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var websiteRuleRows: [WebsiteRuleRow] {
        presetStore.websitePresetIDs
            .map { siteKey, presetID in
                WebsiteRuleRow(
                    siteKey: siteKey,
                    displayName: websiteDisplayName(forSiteKey: siteKey),
                    presetID: presetID
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    private func websiteDisplayName(forSiteKey siteKey: String) -> String {
        if browserPageObserver.activePage?.siteKey == siteKey {
            return browserPageObserver.activePage?.displayName ?? siteKey
        }
        return presetStore.websiteDisplayNames[siteKey] ?? siteKey
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
        case .website:
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
        }
    }

    private enum RuleIcon {
        case app(String)
        case website
    }

    private struct WebsiteRuleRow: Identifiable {
        var id: String { siteKey }
        var siteKey: String
        var displayName: String
        var presetID: String
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
        foregroundAppObserver: ForegroundAppObserver(),
        browserPageObserver: BrowserPageObserver()
    )
    .padding()
}
