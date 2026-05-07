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

    init() {
        refresh()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
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

    private func updateActiveApp(from application: NSRunningApplication?) {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier
        else {
            activeApp = nil
            return
        }

        guard bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        activeApp = ForegroundAppIdentity(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier
        )
    }
}
