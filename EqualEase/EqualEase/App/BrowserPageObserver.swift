//
//  BrowserPageObserver.swift
//  EqualEase
//

import AppKit
import Combine
import CoreServices
import Foundation

struct BrowserPageIdentity: Equatable {
    var browserBundleIdentifier: String
    var browserDisplayName: String
    var url: URL
    var siteKey: String
    var displayName: String
    var generation: Int = 0

    func matchesPage(_ other: BrowserPageIdentity?) -> Bool {
        guard let other else { return false }
        return browserBundleIdentifier == other.browserBundleIdentifier
            && browserDisplayName == other.browserDisplayName
            && url == other.url
            && siteKey == other.siteKey
            && displayName == other.displayName
    }
}

enum BrowserPageNormalizer {
    static func normalizedSiteKey(from url: URL) -> String? {
        normalizedSiteKey(from: url.absoluteString)
    }

    static func normalizedSiteKey(from rawURLString: String) -> String? {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else { return nil }

        let parseableURLString: String
        if trimmedURLString.contains("://") {
            parseableURLString = trimmedURLString
        } else {
            parseableURLString = "https://\(trimmedURLString)"
        }

        guard let components = URLComponents(string: parseableURLString),
              var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else { return nil }

        host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if host.hasPrefix("www."), host.count > 4 {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }
}

@MainActor
protocol ActiveBrowserPageProviding {
    var browserDisplayName: String { get }

    func supports(bundleIdentifier: String) -> Bool
    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity?
}

@MainActor
struct BrowserPageProviderRegistry {
    var providers: [ActiveBrowserPageProviding]

    static let `default` = BrowserPageProviderRegistry(providers: [
        SafariActivePageProvider(),
        GoogleChromeActivePageProvider()
    ])

    func provider(for foregroundApp: ForegroundAppIdentity?) -> ActiveBrowserPageProviding? {
        guard let foregroundApp else { return nil }
        return providers.first { $0.supports(bundleIdentifier: foregroundApp.bundleIdentifier) }
    }
}

@MainActor
struct ScriptedBrowserPageProvider: ActiveBrowserPageProviding {
    var browserBundleIdentifier: String
    var browserDisplayName: String
    var activePageURLScriptSource: String

    func supports(bundleIdentifier: String) -> Bool {
        bundleIdentifier == browserBundleIdentifier
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        guard supports(bundleIdentifier: foregroundApp.bundleIdentifier),
              BrowserAutomationPermission.hasPermission(
                  for: browserBundleIdentifier,
                  promptUserIfNeeded: promptsForPermission
              )
        else { return nil }

        guard let rawURLString = executeActivePageURLScript(),
              let url = URL(string: rawURLString),
              let siteKey = BrowserPageNormalizer.normalizedSiteKey(from: url)
        else { return nil }

        return BrowserPageIdentity(
            browserBundleIdentifier: browserBundleIdentifier,
            browserDisplayName: foregroundApp.displayName,
            url: url,
            siteKey: siteKey,
            displayName: siteKey
        )
    }

    private func executeActivePageURLScript() -> String? {
        var errorInfo: NSDictionary?
        return NSAppleScript(source: activePageURLScriptSource)?
            .executeAndReturnError(&errorInfo)
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

@MainActor
struct SafariActivePageProvider: ActiveBrowserPageProviding {
    static let safariBundleIdentifier = "com.apple.Safari"

    private let provider = ScriptedBrowserPageProvider(
        browserBundleIdentifier: safariBundleIdentifier,
        browserDisplayName: "Safari",
        activePageURLScriptSource: """
        tell application id "com.apple.Safari"
            if not (exists front document) then return ""
            set pageURL to URL of front document
            return pageURL
        end tell
        """
    )

    var browserDisplayName: String { provider.browserDisplayName }

    func supports(bundleIdentifier: String) -> Bool {
        provider.supports(bundleIdentifier: bundleIdentifier)
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        provider.activePage(for: foregroundApp, promptsForPermission: promptsForPermission)
    }
}

@MainActor
struct GoogleChromeActivePageProvider: ActiveBrowserPageProviding {
    static let chromeBundleIdentifier = "com.google.Chrome"

    private let provider = ScriptedBrowserPageProvider(
        browserBundleIdentifier: chromeBundleIdentifier,
        browserDisplayName: "Google Chrome",
        activePageURLScriptSource: """
        tell application id "com.google.Chrome"
            if not (exists front window) then return ""
            if not (exists active tab of front window) then return ""
            set pageURL to URL of active tab of front window
            return pageURL
        end tell
        """
    )

    var browserDisplayName: String { provider.browserDisplayName }

    func supports(bundleIdentifier: String) -> Bool {
        provider.supports(bundleIdentifier: bundleIdentifier)
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        provider.activePage(for: foregroundApp, promptsForPermission: promptsForPermission)
    }
}

private enum BrowserAutomationPermission {
    static func hasPermission(for bundleIdentifier: String, promptUserIfNeeded: Bool) -> Bool {
        guard var targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier).aeDesc?.pointee else {
            return false
        }
        defer { AEDisposeDesc(&targetDescriptor) }

        let status = AEDeterminePermissionToAutomateTarget(
            &targetDescriptor,
            typeWildCard,
            typeWildCard,
            promptUserIfNeeded
        )
        return status == noErr
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

@MainActor
final class BrowserPageObserver: ObservableObject {
    @Published private(set) var activePage: BrowserPageIdentity?
    @Published private(set) var pageGeneration = 0
    @Published private(set) var didFailLastUserRequest = false

    private let providerRegistry: BrowserPageProviderRegistry
    private var foregroundApp: ForegroundAppIdentity?
    private var automaticallyObservesActivePage = false
    private var automaticPermissionPromptedBundleIdentifiers: Set<String> = []
    private var refreshTimer: Timer?

    init() {
        self.providerRegistry = .default
    }

    init(provider: ActiveBrowserPageProviding) {
        self.providerRegistry = BrowserPageProviderRegistry(providers: [provider])
    }

    init(providerRegistry: BrowserPageProviderRegistry) {
        self.providerRegistry = providerRegistry
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var isSupportedBrowserForeground: Bool {
        currentProvider != nil
    }

    var supportedBrowserDisplayName: String? {
        currentProvider?.browserDisplayName
    }

    private var currentProvider: ActiveBrowserPageProviding? {
        providerRegistry.provider(for: foregroundApp)
    }

    func updateForegroundApp(_ foregroundApp: ForegroundAppIdentity?) {
        self.foregroundApp = foregroundApp
        didFailLastUserRequest = false

        guard isSupportedBrowserForeground else {
            stopPolling()
            updateActivePage(nil)
            return
        }

        if activePage?.browserBundleIdentifier != foregroundApp?.bundleIdentifier {
            updateActivePage(nil)
        }

        guard automaticallyObservesActivePage else { return }
        startPolling()
        refreshActivePage(
            promptsForPermission: shouldPromptForAutomaticPermission(),
            clearOnFailure: true
        )
    }

    func setAutomaticObservationEnabled(_ isEnabled: Bool) {
        guard automaticallyObservesActivePage != isEnabled else { return }
        automaticallyObservesActivePage = isEnabled

        if isEnabled, isSupportedBrowserForeground {
            startPolling()
            if activePage == nil {
                refreshActivePage(
                    promptsForPermission: shouldPromptForAutomaticPermission(),
                    clearOnFailure: true
                )
            }
        } else if !isEnabled {
            stopPolling()
        }
    }

    @discardableResult
    func requestActivePageFromUserAction() -> BrowserPageIdentity? {
        guard isSupportedBrowserForeground else {
            didFailLastUserRequest = true
            updateActivePage(nil)
            return nil
        }

        guard let foregroundApp, let provider = currentProvider else {
            didFailLastUserRequest = true
            updateActivePage(nil)
            return nil
        }

        automaticPermissionPromptedBundleIdentifiers.insert(foregroundApp.bundleIdentifier)
        let page = provider.activePage(for: foregroundApp, promptsForPermission: true)
        didFailLastUserRequest = page == nil
        updateActivePage(page)
        return page
    }

    func preserveUserRequestedPage(_ page: BrowserPageIdentity) {
        didFailLastUserRequest = false
        updateActivePage(page)
    }

    func refresh() {
        guard automaticallyObservesActivePage else { return }
        refreshActivePageWithoutPrompt(clearOnFailure: true)
    }

    func refreshActivePageWithoutPrompt(clearOnFailure: Bool = false) {
        refreshActivePage(promptsForPermission: false, clearOnFailure: clearOnFailure)
    }

    private func refreshActivePage(promptsForPermission: Bool, clearOnFailure: Bool = false) {
        guard let foregroundApp,
              let provider = currentProvider
        else {
            if clearOnFailure {
                updateActivePage(nil)
            }
            return
        }

        if let page = provider.activePage(for: foregroundApp, promptsForPermission: promptsForPermission) {
            updateActivePage(page)
        } else if clearOnFailure {
            updateActivePage(nil)
        }
    }

    private func shouldPromptForAutomaticPermission() -> Bool {
        guard let bundleIdentifier = foregroundApp?.bundleIdentifier,
              !automaticPermissionPromptedBundleIdentifiers.contains(bundleIdentifier)
        else { return false }
        automaticPermissionPromptedBundleIdentifiers.insert(bundleIdentifier)
        return true
    }

    private func startPolling() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateActivePage(_ nextPage: BrowserPageIdentity?) {
        if nextPage != nil {
            didFailLastUserRequest = false
        }
        guard !nextPage.matchesPage(activePage) else { return }

        pageGeneration += 1
        var generatedPage = nextPage
        generatedPage?.generation = pageGeneration
        activePage = generatedPage
    }
}

private extension Optional where Wrapped == BrowserPageIdentity {
    func matchesPage(_ other: BrowserPageIdentity?) -> Bool {
        switch (self, other) {
        case (.none, .none): true
        case let (.some(page), other): page.matchesPage(other)
        case (.none, .some): false
        }
    }
}
