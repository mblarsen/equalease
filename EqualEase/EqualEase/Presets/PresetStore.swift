//
//  PresetStore.swift
//  EqualEase
//

import Combine
import Foundation

struct EQPreset: Identifiable, Codable, Equatable {
    enum Source: String, Codable {
        case builtIn
        case custom
    }

    var id: String
    var name: String
    var source: Source
    var bandGains: [Double]
    var outputGain: Double

    var isFlat: Bool {
        bandGains.allSatisfy { abs($0) < 0.001 } && abs(outputGain - 1.0) < 0.001
    }
}

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var builtInPresets: [EQPreset]
    @Published private(set) var customPresets: [EQPreset]
    @Published var selectedPresetID: String {
        didSet { save() }
    }
    @Published private(set) var devicePresetIDs: [String: String]
    @Published private(set) var appPresetIDs: [String: String]
    @Published private(set) var deviceDisplayNames: [String: String]
    @Published private(set) var appDisplayNames: [String: String]

    var presets: [EQPreset] {
        builtInPresets + customPresets
    }

    private let persistenceURL: URL

    init(fileManager: FileManager = .default) {
        self.builtInPresets = Self.defaultBuiltInPresets
        self.persistenceURL = Self.persistenceURL(fileManager: fileManager)

        let persisted = Self.loadPersistedState(from: persistenceURL)
        customPresets = persisted?.customPresets ?? []
        selectedPresetID = persisted?.selectedPresetID ?? Self.defaultBuiltInPresets[0].id
        devicePresetIDs = persisted?.devicePresetIDs ?? [:]
        appPresetIDs = persisted?.appPresetIDs ?? [:]
        deviceDisplayNames = persisted?.deviceDisplayNames ?? [:]
        appDisplayNames = persisted?.appDisplayNames ?? [:]
    }

    init(persistenceURL: URL) {
        self.builtInPresets = Self.defaultBuiltInPresets
        self.persistenceURL = persistenceURL

        let persisted = Self.loadPersistedState(from: persistenceURL)
        customPresets = persisted?.customPresets ?? []
        selectedPresetID = persisted?.selectedPresetID ?? Self.defaultBuiltInPresets[0].id
        devicePresetIDs = persisted?.devicePresetIDs ?? [:]
        appPresetIDs = persisted?.appPresetIDs ?? [:]
        deviceDisplayNames = persisted?.deviceDisplayNames ?? [:]
        appDisplayNames = persisted?.appDisplayNames ?? [:]
    }

    func preset(id: String) -> EQPreset? {
        presets.first { $0.id == id }
    }

    func selectPreset(id: String) -> EQPreset? {
        guard let preset = preset(id: id) else { return nil }
        selectedPresetID = id
        return preset
    }

    func isCustomPreset(id: String) -> Bool {
        customPresets.contains { $0.id == id }
    }

    func renameCustomPreset(id: String, name: String) {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        customPresets[index].name = trimmedName
        save()
    }

    func updateCustomPreset(id: String, bandGains: [Double], outputGain: Double) -> EQPreset? {
        guard let index = customPresets.firstIndex(where: { $0.id == id }) else { return nil }
        customPresets[index].bandGains = Self.normalizedBandGains(bandGains)
        customPresets[index].outputGain = min(max(outputGain, 0), 2)
        save()
        return customPresets[index]
    }

    func duplicatePreset(id: String) -> EQPreset? {
        guard let sourcePreset = preset(id: id) else { return nil }
        let duplicate = EQPreset(
            id: "custom-\(UUID().uuidString)",
            name: nextDuplicateName(for: sourcePreset.name),
            source: .custom,
            bandGains: sourcePreset.bandGains,
            outputGain: sourcePreset.outputGain
        )
        customPresets.append(duplicate)
        selectedPresetID = duplicate.id
        save()
        return duplicate
    }

    @discardableResult
    func deleteSelectedCustomPreset() -> EQPreset? {
        deleteCustomPreset(id: selectedPresetID)
        return preset(id: selectedPresetID)
    }

    func presetForDevice(uid: String?) -> EQPreset? {
        guard let uid, let presetID = devicePresetIDs[uid] else { return nil }
        return preset(id: presetID)
    }

    func presetForApp(bundleIdentifier: String?) -> EQPreset? {
        guard let bundleIdentifier, let presetID = appPresetIDs[bundleIdentifier] else { return nil }
        return preset(id: presetID)
    }

    func assignPreset(id presetID: String, toDeviceUID uid: String?, deviceName: String? = nil) {
        guard let uid, preset(id: presetID) != nil else { return }
        devicePresetIDs[uid] = presetID
        if let deviceName = cleanedDisplayName(deviceName) {
            deviceDisplayNames[uid] = deviceName
        }
        save()
    }

    func assignSelectedPreset(toDeviceUID uid: String?) {
        assignPreset(id: selectedPresetID, toDeviceUID: uid)
    }

    func clearPreset(forDeviceUID uid: String?) {
        guard let uid else { return }
        devicePresetIDs.removeValue(forKey: uid)
        deviceDisplayNames.removeValue(forKey: uid)
        save()
    }

    func assignPreset(id presetID: String, toAppBundleIdentifier bundleIdentifier: String?, displayName: String? = nil) {
        guard let bundleIdentifier, preset(id: presetID) != nil else { return }
        appPresetIDs[bundleIdentifier] = presetID
        if let displayName = cleanedDisplayName(displayName) {
            appDisplayNames[bundleIdentifier] = displayName
        }
        save()
    }

    func assignSelectedPreset(toAppBundleIdentifier bundleIdentifier: String?) {
        assignPreset(id: selectedPresetID, toAppBundleIdentifier: bundleIdentifier)
    }

    func clearPreset(forAppBundleIdentifier bundleIdentifier: String?) {
        guard let bundleIdentifier else { return }
        appPresetIDs.removeValue(forKey: bundleIdentifier)
        appDisplayNames.removeValue(forKey: bundleIdentifier)
        save()
    }

    func suggestedCopyName(for presetName: String) -> String {
        nextDuplicateName(for: presetName)
    }

    func saveCurrentPreset(name: String, bandGains: [Double], outputGain: Double) -> EQPreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = EQPreset(
            id: "custom-\(UUID().uuidString)",
            name: trimmedName.isEmpty ? suggestedCopyName(for: "Preset") : trimmedName,
            source: .custom,
            bandGains: Self.normalizedBandGains(bandGains),
            outputGain: min(max(outputGain, 0), 2)
        )
        customPresets.append(preset)
        selectedPresetID = preset.id
        save()
        return preset
    }

    func saveCurrentPreset(bandGains: [Double], outputGain: Double) -> EQPreset {
        saveCurrentPreset(
            name: suggestedCopyName(for: preset(id: selectedPresetID)?.name ?? "Preset"),
            bandGains: bandGains,
            outputGain: outputGain
        )
    }

    func deleteCustomPreset(id: String) {
        customPresets.removeAll { $0.id == id }
        devicePresetIDs = devicePresetIDs.filter { $0.value != id }
        appPresetIDs = appPresetIDs.filter { $0.value != id }
        deviceDisplayNames = deviceDisplayNames.filter { devicePresetIDs[$0.key] != nil }
        appDisplayNames = appDisplayNames.filter { appPresetIDs[$0.key] != nil }
        if selectedPresetID == id {
            selectedPresetID = Self.defaultBuiltInPresets[0].id
        }
        save()
    }

    private func nextDuplicateName(for name: String) -> String {
        let baseName = "\(name) Copy"
        let existingNames = Set(presets.map(\.name))
        guard existingNames.contains(baseName) else { return baseName }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = PersistedState(
                selectedPresetID: selectedPresetID,
                customPresets: customPresets,
                devicePresetIDs: devicePresetIDs,
                appPresetIDs: appPresetIDs,
                deviceDisplayNames: deviceDisplayNames,
                appDisplayNames: appDisplayNames
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("EqualEase presets: could not save presets: %@", error.localizedDescription)
        }
    }

    private static func loadPersistedState(from url: URL) -> PersistedState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            NSLog("EqualEase presets: could not load presets: %@", error.localizedDescription)
            return nil
        }
    }

    private static func persistenceURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("EqualEase", isDirectory: true).appendingPathComponent("presets.json")
    }

    private static func normalizedBandGains(_ gains: [Double]) -> [Double] {
        let padded = gains + Array(repeating: 0, count: max(0, 10 - gains.count))
        return Array(padded.prefix(10)).map { min(max($0, -12), 12) }
    }

    private func cleanedDisplayName(_ displayName: String?) -> String? {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? nil : trimmedName
    }

    private struct PersistedState: Codable {
        var selectedPresetID: String
        var customPresets: [EQPreset]
        var devicePresetIDs: [String: String] = [:]
        var appPresetIDs: [String: String] = [:]
        var deviceDisplayNames: [String: String] = [:]
        var appDisplayNames: [String: String] = [:]
    }

    private static let defaultBuiltInPresets: [EQPreset] = [
        EQPreset(
            id: "built-in-flat",
            name: "Flat",
            source: .builtIn,
            bandGains: Array(repeating: 0, count: 10),
            outputGain: 1.0
        ),
        EQPreset(
            id: "built-in-voice-boost",
            name: "Voice Boost",
            source: .builtIn,
            bandGains: [-5, -4, -2, 0, 2, 3.5, 4, 2, -1, -3],
            outputGain: 0.9
        ),
        EQPreset(
            id: "built-in-podcast",
            name: "Podcast",
            source: .builtIn,
            bandGains: [-4, -3, -1, 1, 2, 2.5, 3, 1.5, -1, -3],
            outputGain: 0.9
        ),
        EQPreset(
            id: "built-in-de-mud",
            name: "De-Mud",
            source: .builtIn,
            bandGains: [-2, -3, -5, -4, -2, 1, 2, 1, 0, -1],
            outputGain: 0.95
        ),
        EQPreset(
            id: "built-in-bass-boost",
            name: "Bass Boost",
            source: .builtIn,
            bandGains: [5, 4, 3, 1.5, 0, 0, -1, -1.5, -2, -2],
            outputGain: 0.85
        ),
        EQPreset(
            id: "built-in-treble-boost",
            name: "Treble Boost",
            source: .builtIn,
            bandGains: [-2, -2, -1, 0, 0, 1, 2.5, 4, 5, 5],
            outputGain: 0.85
        ),
        EQPreset(
            id: "built-in-loudness",
            name: "Loudness",
            source: .builtIn,
            bandGains: [4, 3, 2, 0, -1, -1, 0, 2, 3, 3],
            outputGain: 0.85
        ),
        EQPreset(
            id: "built-in-night-mode",
            name: "Night Mode",
            source: .builtIn,
            bandGains: [-5, -4, -3, -1, 1, 2, 1, -2, -5, -6],
            outputGain: 0.75
        ),
        EQPreset(
            id: "built-in-small-speakers",
            name: "Small Speakers",
            source: .builtIn,
            bandGains: [-4, -2, 2, 3, 1, 0, 1, 2, 1, -1],
            outputGain: 0.9
        ),
        EQPreset(
            id: "built-in-reduce-rumble",
            name: "Reduce Rumble",
            source: .builtIn,
            bandGains: [-12, -10, -7, -3, 0, 0, 0, 0, 0, 0],
            outputGain: 0.95
        ),
        EQPreset(
            id: "built-in-warm",
            name: "Warm",
            source: .builtIn,
            bandGains: [2, 2.5, 2, 1, 0, -0.5, -1, -1.5, -2, -2],
            outputGain: 0.95
        ),
        EQPreset(
            id: "built-in-muffled",
            name: "Muffled",
            source: .builtIn,
            bandGains: [0, 0, -1, -2, -4, -6, -8, -10, -12, -12],
            outputGain: 0.5
        ),
    ]
}
