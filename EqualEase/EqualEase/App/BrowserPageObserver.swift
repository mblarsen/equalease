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

    static let `default` = BrowserPageProviderRegistry(providers: [SafariActivePageProvider()])

    func provider(for foregroundApp: ForegroundAppIdentity?) -> ActiveBrowserPageProviding? {
        guard let foregroundApp else { return nil }
        return providers.first { $0.supports(bundleIdentifier: foregroundApp.bundleIdentifier) }
    }
}

@MainActor
struct SafariActivePageProvider: ActiveBrowserPageProviding {
    static let safariBundleIdentifier = "com.apple.Safari"

    var browserDisplayName: String { "Safari" }

    func supports(bundleIdentifier: String) -> Bool {
        bundleIdentifier == Self.safariBundleIdentifier
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        guard supports(bundleIdentifier: foregroundApp.bundleIdentifier),
              hasAutomationPermission(promptUserIfNeeded: promptsForPermission)
        else { return nil }

        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: """
        tell application id "com.apple.Safari"
            if not (exists front document) then return ""
            set pageURL to URL of front document
            return pageURL
        end tell
        """)

        guard let rawURLString = script?.executeAndReturnError(&errorInfo).stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURLString.isEmpty,
              let url = URL(string: rawURLString),
              let siteKey = BrowserPageNormalizer.normalizedSiteKey(from: url)
        else { return nil }

        return BrowserPageIdentity(
            browserBundleIdentifier: Self.safariBundleIdentifier,
            browserDisplayName: foregroundApp.displayName,
            url: url,
            siteKey: siteKey,
            displayName: siteKey
        )
    }

    private func hasAutomationPermission(promptUserIfNeeded: Bool) -> Bool {
        guard var targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: Self.safariBundleIdentifier).aeDesc?.pointee else {
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

@MainActor
final class BrowserPageObserver: ObservableObject {
    @Published private(set) var activePage: BrowserPageIdentity?
    @Published private(set) var pageGeneration = 0
    @Published private(set) var didFailLastUserRequest = false

    private let providerRegistry: BrowserPageProviderRegistry
    private var foregroundApp: ForegroundAppIdentity?
    private var automaticallyObservesActivePage = false
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

        guard automaticallyObservesActivePage else { return }
        startPolling()
        refresh()
    }

    func setAutomaticObservationEnabled(_ isEnabled: Bool) {
        guard automaticallyObservesActivePage != isEnabled else { return }
        automaticallyObservesActivePage = isEnabled

        if isEnabled, isSupportedBrowserForeground {
            startPolling()
            if activePage == nil {
                refresh()
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
        guard let foregroundApp,
              let provider = currentProvider
        else {
            if clearOnFailure {
                updateActivePage(nil)
            }
            return
        }

        if let page = provider.activePage(for: foregroundApp, promptsForPermission: false) {
            updateActivePage(page)
        } else if clearOnFailure {
            updateActivePage(nil)
        }
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
