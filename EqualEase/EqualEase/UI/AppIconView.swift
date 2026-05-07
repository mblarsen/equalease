//
//  AppIconView.swift
//  EqualEase
//

import AppKit
import SwiftUI

struct AppIconView: View {
    var bundleIdentifier: String?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        guard let bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: size, height: size)
        return icon
    }
}

#Preview {
    AppIconView(bundleIdentifier: "com.apple.Safari", size: 32)
        .padding()
}
