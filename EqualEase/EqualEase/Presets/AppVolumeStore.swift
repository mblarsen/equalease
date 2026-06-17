//
//  AppVolumeStore.swift
//  EqualEase
//

import Combine
import Foundation

enum AppAudioMode: String, Codable, CaseIterable, Sendable {
    case on
    case off
    case mute

    var label: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        case .mute: "Mute"
        }
    }
}

/// Persists per-app volume and routing mode preferences keyed by bundle ID.
@MainActor
final class AppVolumeStore: ObservableObject {
    @Published private(set) var appVolumes: [String: Double]
    @Published private(set) var appModes: [String: AppAudioMode]

    private let persistenceURL: URL

    init(fileManager: FileManager = .default) {
        self.persistenceURL = Self.persistenceURL(fileManager: fileManager)
        let persisted = Self.loadPersistedState(from: persistenceURL)
        appVolumes = persisted?.appVolumes ?? [:]
        appModes = persisted?.appModes ?? [:]
    }

    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        let persisted = Self.loadPersistedState(from: persistenceURL)
        appVolumes = persisted?.appVolumes ?? [:]
        appModes = persisted?.appModes ?? [:]
    }

    /// Returns the app volume multiplier, defaulting to 1.0 (normal/full volume).
    func volume(for bundleID: String) -> Double {
        appVolumes[bundleID] ?? 1.0
    }

    /// Sets the app volume multiplier (clamped to 0–1; 1.0 = normal/full volume).
    func setVolume(_ volume: Double, for bundleID: String) {
        let clamped = min(max(volume, 0), 1)
        if clamped == 1.0 {
            appVolumes.removeValue(forKey: bundleID)
        } else {
            appVolumes[bundleID] = clamped
        }
        save()
    }

    /// Returns the app mode. `.on` means normal processing, `.off` means verbatim pass-through, `.mute` means silence.
    func mode(for bundleID: String) -> AppAudioMode {
        appModes[bundleID] ?? .on
    }

    /// Sets the app mode. `.on` is the default and is not persisted.
    func setMode(_ mode: AppAudioMode, for bundleID: String) {
        if mode == .on {
            appModes.removeValue(forKey: bundleID)
        } else {
            appModes[bundleID] = mode
        }
        save()
    }

    /// Legacy compatibility for older UI/tests: bypass maps to mode `.off`.
    func isBypassed(_ bundleID: String) -> Bool {
        mode(for: bundleID) == .off
    }

    /// Legacy compatibility for older UI/tests: bypass maps to mode `.off`.
    func setBypassed(_ bypassed: Bool, for bundleID: String) {
        setMode(bypassed ? .off : .on, for: bundleID)
    }

    /// Removes stored preferences for apps no longer in the given active set.
    func pruneStaleApps(keeping activeBundleIDs: Set<String>) {
        let volumeKeysToRemove = Set(appVolumes.keys).subtracting(activeBundleIDs)
        let modeKeysToRemove = Set(appModes.keys).subtracting(activeBundleIDs)
        guard !volumeKeysToRemove.isEmpty || !modeKeysToRemove.isEmpty else { return }
        for key in volumeKeysToRemove { appVolumes.removeValue(forKey: key) }
        for key in modeKeysToRemove { appModes.removeValue(forKey: key) }
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let state = PersistedState(
                appVolumes: appVolumes,
                appModes: appModes
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("EqualEase app-volumes: could not save: %@", error.localizedDescription)
        }
    }

    private static func loadPersistedState(from url: URL) -> PersistedState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            NSLog("EqualEase app-volumes: could not load: %@", error.localizedDescription)
            return nil
        }
    }

    private static func persistenceURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("EqualEase", isDirectory: true)
            .appendingPathComponent("app-volumes.json")
    }

    private struct PersistedState: Codable {
        var appVolumes: [String: Double]
        var appModes: [String: AppAudioMode]

        init(appVolumes: [String: Double] = [:], appModes: [String: AppAudioMode] = [:]) {
            self.appVolumes = appVolumes
            self.appModes = appModes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appVolumes = try container.decodeIfPresent([String: Double].self, forKey: .appVolumes) ?? [:]
            if let decodedModes = try container.decodeIfPresent([String: AppAudioMode].self, forKey: .appModes) {
                appModes = decodedModes
            } else {
                let legacyBypassedApps = try container.decodeIfPresent(Set<String>.self, forKey: .bypassedApps) ?? []
                appModes = Dictionary(uniqueKeysWithValues: legacyBypassedApps.map { ($0, .off) })
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(appVolumes, forKey: .appVolumes)
            try container.encode(appModes, forKey: .appModes)
        }

        private enum CodingKeys: String, CodingKey {
            case appVolumes
            case appModes
            case bypassedApps
        }
    }
}
