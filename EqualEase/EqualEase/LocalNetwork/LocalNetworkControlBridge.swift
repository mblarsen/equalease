//
//  LocalNetworkControlBridge.swift
//  EqualEase
//

import Combine
import Foundation

@MainActor
final class LocalNetworkControlBridge {
    private unowned let appModel: EqualEaseAppModel
    private var stateVersion = 0

    init(appModel: EqualEaseAppModel) {
        self.appModel = appModel
    }

    func snapshot() -> LocalNetworkRemoteState {
        stateVersion += 1
        return LocalNetworkRemoteState(
            stateVersion: stateVersion,
            outputVolume: clamped(appModel.router.outputVolume, lowerBound: 0, upperBound: 1),
            preamp: clamped(appModel.router.outputGain, lowerBound: 0, upperBound: 2),
            activePresetID: appModel.activeContext?.preset.id,
            activePresetName: appModel.activeContext?.preset.name ?? "Unknown",
            presets: appModel.presetStore.presets.map { preset in
                LocalNetworkRemotePreset(id: preset.id, name: preset.name, source: preset.source.rawValue)
            },
            isActive: appModel.router.isRunning,
            isRoutingTransitioning: appModel.router.isRoutingTransitioning,
            routingStatus: appModel.router.statusText
        )
    }

    func handle(_ command: LocalNetworkRemoteCommand) throws -> LocalNetworkRemoteState {
        switch command {
        case let .setVolume(value):
            appModel.router.outputVolume = clamped(value, lowerBound: 0, upperBound: 1)
        case let .setPreamp(value):
            appModel.router.outputGain = clamped(value, lowerBound: 0, upperBound: 2)
        case let .selectPreset(id, name):
            guard let preset = preset(id: id, name: name) else {
                throw BridgeError.unknownPreset(id ?? name ?? "")
            }
            appModel.selectPreset(id: preset.id)
        }

        return snapshot()
    }

    private func preset(id: String?, name: String?) -> EQPreset? {
        if let id, let preset = appModel.presetStore.preset(id: id) {
            return preset
        }
        guard let name else { return nil }
        let normalizedName = normalize(name)
        return appModel.presetStore.presets.first { normalize($0.name) == normalizedName || normalize($0.id) == normalizedName }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func clamped(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        min(max(value, lowerBound), upperBound)
    }

    enum BridgeError: LocalizedError, Equatable {
        case unknownPreset(String)

        var errorDescription: String? {
            switch self {
            case let .unknownPreset(value):
                "Unknown preset: \(value)"
            }
        }
    }
}
