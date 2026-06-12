//
//  ForegroundAppObserverTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class ForegroundAppObserverTests: XCTestCase {
    func testIgnoresUserNotificationCenterPermissionPromptApp() {
        XCTAssertTrue(
            ForegroundAppObserver.shouldIgnoreApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
        )
    }

    func testDoesNotIgnoreRegularApps() {
        XCTAssertFalse(
            ForegroundAppObserver.shouldIgnoreApplication(bundleIdentifier: "com.apple.Safari")
        )
    }

    func testTerminatingPreservedActiveAppClearsIt() {
        let observer = ForegroundAppObserver(
            initialActiveApp: ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        )

        observer.applicationDidTerminate(bundleIdentifier: "com.apple.Safari")

        XCTAssertNil(observer.activeApp)
        XCTAssertEqual(observer.activationGeneration, 1)
    }

    func testTerminatingDifferentAppDoesNotClearPreservedActiveApp() {
        let observer = ForegroundAppObserver(
            initialActiveApp: ForegroundAppIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        )

        observer.applicationDidTerminate(bundleIdentifier: "com.apple.Terminal")

        XCTAssertEqual(observer.activeApp?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(observer.activationGeneration, 0)
    }
}
