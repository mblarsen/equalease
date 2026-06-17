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
    /// Mode an app was in before it was muted, persisted so unmuting restores it across launches.
    @Published private(set) var preMuteModes: [String: AppAudioMode]

    private let persistenceURL: URL

    convenience init(fileManager: FileManager = .default) {
        self.init(persistenceURL: Self.persistenceURL(fileManager: fileManager))
    }

    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        let persisted = Self.loadPersistedState(from: persistenceURL)
        appVolumes = persisted?.appVolumes ?? [:]
        appModes = persisted?.appModes ?? [:]
        preMuteModes = persisted?.preMuteModes ?? [:]
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

    /// Returns the mode that will be active when the app is not muted.
    func nonMuteMode(for bundleID: String) -> AppAudioMode {
        if mode(for: bundleID) == .mute {
            return preMuteModes[bundleID] ?? .on
        }
        return mode(for: bundleID)
    }

    /// Mute or unmute an app without changing its Process/Bypass state.
    /// The pre-mute mode is persisted so it survives app restarts.
    func setMuted(_ muted: Bool, for bundleID: String) {
        let current = mode(for: bundleID)
        if muted {
            if current != .mute {
                preMuteModes[bundleID] = current
                setMode(.mute, for: bundleID)
            }
        } else {
            let restore = preMuteModes.removeValue(forKey: bundleID) ?? .on
            setMode(restore, for: bundleID)
        }
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
        let preMuteKeysToRemove = Set(preMuteModes.keys).subtracting(activeBundleIDs)
        guard !volumeKeysToRemove.isEmpty || !modeKeysToRemove.isEmpty || !preMuteKeysToRemove.isEmpty else { return }
        for key in volumeKeysToRemove { appVolumes.removeValue(forKey: key) }
        for key in modeKeysToRemove { appModes.removeValue(forKey: key) }
        for key in preMuteKeysToRemove { preMuteModes.removeValue(forKey: key) }
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
                appModes: appModes,
                preMuteModes: preMuteModes
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
        var preMuteModes: [String: AppAudioMode]

        init(appVolumes: [String: Double] = [:], appModes: [String: AppAudioMode] = [:], preMuteModes: [String: AppAudioMode] = [:]) {
            self.appVolumes = appVolumes
            self.appModes = appModes
            self.preMuteModes = preMuteModes
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
            preMuteModes = try container.decodeIfPresent([String: AppAudioMode].self, forKey: .preMuteModes) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(appVolumes, forKey: .appVolumes)
            try container.encode(appModes, forKey: .appModes)
            try container.encode(preMuteModes, forKey: .preMuteModes)
        }

        private enum CodingKeys: String, CodingKey {
            case appVolumes
            case appModes
            case preMuteModes
            case bypassedApps
        }
    }
}
