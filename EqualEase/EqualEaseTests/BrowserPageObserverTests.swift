//
//  BrowserPageObserverTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class BrowserPageNormalizerTests: XCTestCase {
    func testSiteKeyNormalizationLowercasesHostAndStripsWWW() {
        XCTAssertEqual(
            BrowserPageNormalizer.normalizedSiteKey(from: "https://WWW.Meet.Google.com/foo?bar=baz#fragment"),
            "meet.google.com"
        )
    }

    func testSiteKeyNormalizationIgnoresPathQueryFragmentAndScheme() {
        XCTAssertEqual(
            BrowserPageNormalizer.normalizedSiteKey(from: "http://youtube.com/watch?v=abc#comments"),
            "youtube.com"
        )
    }

    func testSiteKeyNormalizationAcceptsBareHost() {
        XCTAssertEqual(
            BrowserPageNormalizer.normalizedSiteKey(from: "www.example.com/path"),
            "example.com"
        )
    }

    func testSiteKeyNormalizationRejectsEmptyInput() {
        XCTAssertNil(BrowserPageNormalizer.normalizedSiteKey(from: "  "))
    }
}

@MainActor
final class BrowserPageObserverTests: XCTestCase {
    func testForegroundSafariDoesNotQueryPageBeforeUserActionOrAutomaticObservation() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(observer.pageGeneration, 0)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testUserActionRequestsSafariPageAndIncrementsGeneration() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()

        XCTAssertEqual(observer.supportedBrowserDisplayName, "Safari")
        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [true])
        XCTAssertFalse(observer.didFailLastUserRequest)
    }

    func testAutomaticObservationPublishesSafariPageAfterOptIn() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.setAutomaticObservationEnabled(true)

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [false])

        provider.page = youtube
        observer.refresh()

        XCTAssertEqual(observer.activePage?.siteKey, youtube.siteKey)
        XCTAssertEqual(observer.pageGeneration, 2)
    }

    func testAutomaticObservationDoesNotPromptForPermissionWhenReadIsDenied() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet
        provider.allowsNonPromptedRead = false

        observer.updateForegroundApp(safari)
        observer.setAutomaticObservationEnabled(true)

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(observer.pageGeneration, 0)
        XCTAssertEqual(provider.permissionPromptRequests, [false])

        observer.requestActivePageFromUserAction()

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [false, true])
    }

    func testEnablingAutomaticObservationDoesNotClearFreshUserRequestedPage() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet
        provider.allowsNonPromptedRead = false

        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        observer.setAutomaticObservationEnabled(true)

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [true])
    }

    func testFailedAutomaticRefreshClearsCurrentPage() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        observer.setAutomaticObservationEnabled(true)

        provider.page = nil
        observer.refresh()

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(observer.pageGeneration, 2)
        XCTAssertEqual(provider.permissionPromptRequests, [true, false])
    }

    func testRulesViewRefreshDoesNotClearCurrentPageWhenReadFails() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()

        provider.page = nil
        observer.refreshActivePageWithoutPrompt()

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [true, false])
    }

    func testAutomaticObservationClearsCurrentPageWhenPermissionWasRevoked() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.requestActivePageFromUserAction()
        observer.setAutomaticObservationEnabled(true)

        provider.allowsNonPromptedRead = false
        observer.refresh()

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(observer.pageGeneration, 2)
        XCTAssertEqual(provider.permissionPromptRequests, [true, false])
    }

    func testDisablingAutomaticObservationStopsPollingWithoutClearingCurrentPage() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet
        observer.updateForegroundApp(safari)
        observer.setAutomaticObservationEnabled(true)
        provider.requestCount = 0

        observer.setAutomaticObservationEnabled(false)
        observer.refresh()

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testRulesViewRefreshCanReadCurrentPageWithoutAutomaticObservation() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.refreshActivePageWithoutPrompt()

        XCTAssertEqual(observer.activePage?.siteKey, meet.siteKey)
        XCTAssertEqual(observer.pageGeneration, 1)
        XCTAssertEqual(provider.permissionPromptRequests, [false])
    }

    func testObserverClearsPageWhenForegroundAppIsNotSafari() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet
        observer.updateForegroundApp(safari)
        observer.setAutomaticObservationEnabled(true)

        observer.updateForegroundApp(terminal)

        XCTAssertNil(observer.activePage)
        XCTAssertEqual(observer.pageGeneration, 2)
    }

    func testObserverDoesNotIncrementGenerationForSamePage() {
        let provider = FakeBrowserPageProvider()
        let observer = BrowserPageObserver(provider: provider)
        provider.page = meet

        observer.updateForegroundApp(safari)
        observer.setAutomaticObservationEnabled(true)
        observer.refresh()

        XCTAssertEqual(observer.pageGeneration, 1)
    }

    private var safari: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
    }

    private var terminal: ForegroundAppIdentity {
        ForegroundAppIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
    }

    private var meet: BrowserPageIdentity {
        BrowserPageIdentity(
            browserBundleIdentifier: safari.bundleIdentifier,
            browserDisplayName: safari.displayName,
            url: URL(string: "https://meet.google.com/")!,
            siteKey: "meet.google.com",
            displayName: "meet.google.com"
        )
    }

    private var youtube: BrowserPageIdentity {
        BrowserPageIdentity(
            browserBundleIdentifier: safari.bundleIdentifier,
            browserDisplayName: safari.displayName,
            url: URL(string: "https://youtube.com/watch?v=abc")!,
            siteKey: "youtube.com",
            displayName: "youtube.com"
        )
    }
}

@MainActor
private final class FakeBrowserPageProvider: ActiveBrowserPageProviding {
    var browserDisplayName = "Safari"
    var page: BrowserPageIdentity?
    var requestCount = 0
    var allowsNonPromptedRead = true
    var permissionPromptRequests: [Bool] = []

    func supports(bundleIdentifier: String) -> Bool {
        bundleIdentifier == SafariActivePageProvider.safariBundleIdentifier
    }

    func activePage(for foregroundApp: ForegroundAppIdentity, promptsForPermission: Bool) -> BrowserPageIdentity? {
        requestCount += 1
        permissionPromptRequests.append(promptsForPermission)
        guard supports(bundleIdentifier: foregroundApp.bundleIdentifier),
              promptsForPermission || allowsNonPromptedRead
        else { return nil }
        return page
    }
}
