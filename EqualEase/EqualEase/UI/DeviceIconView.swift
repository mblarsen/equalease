//
//  DeviceIconView.swift
//  EqualEase
//

import SwiftUI

struct DeviceIconView: View {
    var systemName: String
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview {
    DeviceIconView(systemName: "speaker.wave.2.fill", size: 32)
        .padding()
}
