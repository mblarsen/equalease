//
//  ForegroundAppObserver.swift
//  EqualEase
//

import AppKit
import Combine
import Foundation

struct ForegroundAppIdentity: Equatable {
    var bundleIdentifier: String
    var displayName: String
}

@MainActor
final class ForegroundAppObserver: ObservableObject {
    @Published private(set) var activeApp: ForegroundAppIdentity?
    @Published private(set) var activationGeneration = 0

    private static let ignoredBundleIdentifiers: Set<String> = [
        "com.apple.UserNotificationCenter",
    ]

    init() {
        refresh()
        observeWorkspaceNotifications()
    }

    init(initialActiveApp: ForegroundAppIdentity?) {
        activeApp = initialActiveApp
    }

    private func observeWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidTerminateApplication(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func refresh() {
        updateActiveApp(from: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func workspaceDidActivateApplication(_ notification: Notification) {
        activationGeneration += 1
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateActiveApp(from: application ?? NSWorkspace.shared.frontmostApplication)
    }

    @objc private func workspaceDidTerminateApplication(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        applicationDidTerminate(bundleIdentifier: application?.bundleIdentifier)
    }

    func applicationDidTerminate(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              activeApp?.bundleIdentifier == bundleIdentifier
        else { return }

        activationGeneration += 1
        activeApp = nil
    }

    private func updateActiveApp(from application: NSRunningApplication?) {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier
        else {
            activeApp = nil
            return
        }

        guard !Self.shouldIgnoreApplication(bundleIdentifier: bundleIdentifier) else {
            return
        }

        activeApp = ForegroundAppIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier
        )
    }

    static func shouldIgnoreApplication(bundleIdentifier: String) -> Bool {
        bundleIdentifier == Bundle.main.bundleIdentifier
            || ignoredBundleIdentifiers.contains(bundleIdentifier)
    }
}
