//
//  EqualizerSlidersView.swift
//  EqualEase
//

import SwiftUI

struct EqualizerSlidersView<Router: AudioRoutingBackend>: View {
    @ObservedObject var router: Router
    var showsEnableToggle = true
    var showsPreampHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsEnableToggle {
                Toggle("Enable 10-band EQ", isOn: Binding(
                    get: { router.equalizerEnabled },
                    set: { router.equalizerEnabled = $0 }
                ))
            }

            HStack {
                Text("Preamp")
                Slider(
                    value: Binding(
                        get: { router.outputGain },
                        set: { router.outputGain = $0 }
                    ),
                    in: 0...2,
                    step: 0.05
                )
                Text("\(Int(router.outputGain * 100))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            if showsPreampHelp {
                Text("Saved with the preset. Lower it if boosted bands distort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(equaleaseEQBandLabels.enumerated()), id: \.offset) { index, label in
                HStack {
                    Text(label)
                        .frame(width: 48, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { router.bandGains[index] },
                            set: { router.setBandGain($0, at: index) }
                        ),
                        in: -12...12,
                        step: 0.5
                    )
                    Text("\(router.bandGains[index], specifier: "%.1f") dB")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    EqualizerSlidersView(router: CoreAudioRouter())
        .padding()
}
