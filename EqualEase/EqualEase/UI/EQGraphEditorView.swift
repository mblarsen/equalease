//
//  EQGraphEditorView.swift
//  EqualEase
//

import CoreGraphics
import SwiftUI

struct EQGraphValueMapper: Equatable {
    static let gainRange: ClosedRange<Double> = -12...12
    static let step: Double = 0.5

    var plotRect: CGRect
    var bandCount: Int = 10

    func x(forBand index: Int) -> CGFloat {
        guard bandCount > 1 else { return plotRect.midX }
        let clampedIndex = min(max(index, 0), bandCount - 1)
        let progress = CGFloat(clampedIndex) / CGFloat(bandCount - 1)
        return plotRect.minX + (plotRect.width * progress)
    }

    func y(forGain gain: Double) -> CGFloat {
        let clampedGain = Self.clamped(gain)
        let normalized = (clampedGain - Self.gainRange.lowerBound) / (Self.gainRange.upperBound - Self.gainRange.lowerBound)
        return plotRect.maxY - (plotRect.height * CGFloat(normalized))
    }

    func steppedGain(forY y: CGFloat) -> Double {
        guard plotRect.height > 0 else { return 0 }
        let clampedY = min(max(y, plotRect.minY), plotRect.maxY)
        let normalized = Double((plotRect.maxY - clampedY) / plotRect.height)
        let rawGain = Self.gainRange.lowerBound + normalized * (Self.gainRange.upperBound - Self.gainRange.lowerBound)
        return Self.stepped(rawGain)
    }

    static func stepped(_ gain: Double) -> Double {
        let steppedGain = (gain / step).rounded() * step
        return clamped(steppedGain)
    }

    static func clamped(_ gain: Double) -> Double {
        min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }
}

struct EQGraphEditorView<Router: AudioRoutingBackend>: View {
    @ObservedObject var router: Router
    @Binding var selectedBandIndex: Int?

    @Environment(\.colorScheme) private var colorScheme

    private let graphHeight: CGFloat = 280
    private let coordinateSpaceName = "EqualEaseEQGraph"

    var body: some View {
        GeometryReader { proxy in
            let plotRect = Self.plotRect(in: proxy.size)
            let mapper = EQGraphValueMapper(plotRect: plotRect, bandCount: equaleaseEQBandLabels.count)
            let appearance = EQGraphAppearance(colorScheme: colorScheme)
            let gains = normalizedBandGains
            let points = gains.enumerated().map { index, gain in
                CGPoint(x: mapper.x(forBand: index), y: mapper.y(forGain: gain))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(appearance.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(appearance.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture {
                        selectedBandIndex = nil
                    }

                grid(in: plotRect, mapper: mapper, appearance: appearance)
                    .allowsHitTesting(false)

                fillPath(points: points, zeroY: mapper.y(forGain: 0))
                    .fill(
                        LinearGradient(
                            colors: [appearance.fillStart, appearance.fillEnd],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .allowsHitTesting(false)

                curvePath(points: points)
                    .stroke(appearance.curve, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    let isSelected = selectedBandIndex == index
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: mapper.y(forGain: 0)))
                        path.addLine(to: point)
                    }
                    .stroke(isSelected ? appearance.selectedStem : appearance.stem, style: StrokeStyle(lineWidth: isSelected ? 2 : 1.25, lineCap: .round))
                    .allowsHitTesting(false)
                }

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    EQBandKnob(
                        label: equaleaseEQBandLabels[index],
                        gain: gains[index],
                        isSelected: selectedBandIndex == index,
                        appearance: appearance,
                        increment: { adjustBand(index, by: EQGraphValueMapper.step) },
                        decrement: { adjustBand(index, by: -EQGraphValueMapper.step) }
                    )
                    .position(point)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
                            .onChanged { value in
                                selectedBandIndex = index
                                setLiveBandGain(mapper.steppedGain(forY: value.location.y), at: index)
                            }
                    )
                    .onTapGesture {
                        selectedBandIndex = index
                    }
                }

                bandLabels(in: plotRect, appearance: appearance)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: coordinateSpaceName)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("10-band equalizer graph")
        }
        .frame(minHeight: graphHeight)
    }

    private var normalizedBandGains: [Double] {
        let padded = router.bandGains + Array(repeating: 0, count: max(0, equaleaseEQBandLabels.count - router.bandGains.count))
        return Array(padded.prefix(equaleaseEQBandLabels.count)).map(EQGraphValueMapper.clamped)
    }

    private static func plotRect(in size: CGSize) -> CGRect {
        let leftInset: CGFloat = 34
        let rightInset: CGFloat = 28
        let topInset: CGFloat = 18
        let bottomInset: CGFloat = 42
        return CGRect(
            x: leftInset,
            y: topInset,
            width: max(1, size.width - leftInset - rightInset),
            height: max(1, size.height - topInset - bottomInset)
        )
    }

    private func grid(in rect: CGRect, mapper: EQGraphValueMapper, appearance: EQGraphAppearance) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([-12.0, -6.0, 0.0, 6.0, 12.0], id: \.self) { gain in
                let y = mapper.y(forGain: gain)
                Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                .stroke(gain == 0 ? appearance.zeroAxis : appearance.grid, lineWidth: gain == 0 ? 1.4 : 1)

                Text(gainLabel(gain))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(appearance.secondaryText)
                    .position(x: rect.minX - 18, y: y)
            }
        }
    }

    private func bandLabels(in rect: CGRect, appearance: EQGraphAppearance) -> some View {
        ForEach(Array(equaleaseEQBandLabels.enumerated()), id: \.offset) { index, label in
            Text(label)
                .font(.caption2.weight(selectedBandIndex == index ? .semibold : .regular))
                .foregroundStyle(selectedBandIndex == index ? appearance.selectedText : appearance.secondaryText)
                .position(
                    x: EQGraphValueMapper(plotRect: rect, bandCount: equaleaseEQBandLabels.count).x(forBand: index),
                    y: rect.maxY + 22
                )
        }
    }

    private func curvePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let firstPoint = points.first else { return }
            path.move(to: firstPoint)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func fillPath(points: [CGPoint], zeroY: CGFloat) -> Path {
        Path { path in
            guard let firstPoint = points.first, let lastPoint = points.last else { return }
            path.move(to: CGPoint(x: firstPoint.x, y: zeroY))
            path.addLine(to: firstPoint)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: lastPoint.x, y: zeroY))
            path.closeSubpath()
        }
    }

    private func adjustBand(_ index: Int, by delta: Double) {
        guard normalizedBandGains.indices.contains(index) else { return }
        selectedBandIndex = index
        let nextGain = EQGraphValueMapper.stepped(normalizedBandGains[index] + delta)
        setLiveBandGain(nextGain, at: index)
    }

    private func setLiveBandGain(_ gain: Double, at index: Int) {
        router.setBandGain(gain, at: index)
        if abs(gain) > 0.001, !router.equalizerEnabled {
            router.equalizerEnabled = true
        }
    }

    private func gainLabel(_ gain: Double) -> String {
        if gain > 0 { return "+\(Int(gain))" }
        return "\(Int(gain))"
    }
}

private struct EQBandKnob: View {
    var label: String
    var gain: Double
    var isSelected: Bool
    var appearance: EQGraphAppearance
    var increment: () -> Void
    var decrement: () -> Void

    var body: some View {
        Circle()
            .fill(isSelected ? appearance.selectedKnobFill : appearance.knobFill)
            .frame(width: isSelected ? 18 : 15, height: isSelected ? 18 : 15)
            .overlay(
                Circle()
                    .stroke(isSelected ? appearance.selectedKnobStroke : appearance.knobStroke, lineWidth: isSelected ? 3 : 2)
            )
            .shadow(color: appearance.knobShadow, radius: isSelected ? 5 : 3, x: 0, y: 1)
            .contentShape(Rectangle().inset(by: -8))
            .accessibilityElement()
            .accessibilityLabel("\(label) hertz band")
            .accessibilityValue("\(String(format: "%.1f", gain)) decibels")
            .accessibilityHint("Swipe up or down with VoiceOver to adjust in half-decibel steps.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    increment()
                case .decrement:
                    decrement()
                @unknown default:
                    break
                }
            }
    }
}

private struct EQGraphAppearance {
    var background: Color
    var border: Color
    var grid: Color
    var zeroAxis: Color
    var stem: Color
    var selectedStem: Color
    var curve: Color
    var fillStart: Color
    var fillEnd: Color
    var knobFill: Color
    var knobStroke: Color
    var selectedKnobFill: Color
    var selectedKnobStroke: Color
    var knobShadow: Color
    var secondaryText: Color
    var selectedText: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            background = Color(nsColor: .controlBackgroundColor).opacity(0.78)
            border = Color.white.opacity(0.12)
            grid = Color.white.opacity(0.10)
            zeroAxis = Color.white.opacity(0.26)
            stem = Color.white.opacity(0.22)
            selectedStem = Color(red: 1.0, green: 0.62, blue: 0.25).opacity(0.82)
            curve = Color(red: 1.0, green: 0.58, blue: 0.18)
            fillStart = Color(red: 1.0, green: 0.54, blue: 0.16).opacity(0.36)
            fillEnd = Color(red: 1.0, green: 0.30, blue: 0.06).opacity(0.04)
            knobFill = Color(nsColor: .windowBackgroundColor)
            knobStroke = Color(red: 1.0, green: 0.55, blue: 0.18)
            selectedKnobFill = Color(red: 1.0, green: 0.52, blue: 0.14)
            selectedKnobStroke = Color.white.opacity(0.92)
            knobShadow = Color.black.opacity(0.34)
            secondaryText = Color.white.opacity(0.54)
            selectedText = Color(red: 1.0, green: 0.68, blue: 0.30)
        default:
            background = Color(nsColor: .textBackgroundColor).opacity(0.92)
            border = Color.black.opacity(0.10)
            grid = Color.black.opacity(0.08)
            zeroAxis = Color.black.opacity(0.22)
            stem = Color.black.opacity(0.18)
            selectedStem = Color(red: 0.94, green: 0.36, blue: 0.05).opacity(0.82)
            curve = Color(red: 0.94, green: 0.35, blue: 0.04)
            fillStart = Color(red: 1.0, green: 0.48, blue: 0.11).opacity(0.30)
            fillEnd = Color(red: 1.0, green: 0.74, blue: 0.32).opacity(0.03)
            knobFill = Color(nsColor: .windowBackgroundColor)
            knobStroke = Color(red: 0.92, green: 0.34, blue: 0.03)
            selectedKnobFill = Color(red: 0.96, green: 0.39, blue: 0.06)
            selectedKnobStroke = Color(nsColor: .windowBackgroundColor)
            knobShadow = Color.black.opacity(0.18)
            secondaryText = Color(nsColor: .secondaryLabelColor)
            selectedText = Color(red: 0.82, green: 0.28, blue: 0.02)
        }
    }
}

#Preview {
    EQGraphEditorView(router: CoreAudioRouter(), selectedBandIndex: .constant(nil))
        .padding()
        .frame(width: 520, height: 320)
}
