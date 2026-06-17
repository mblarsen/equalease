//
//  AppVolumeStore.swift
//  EqualEase
//

import Combine
import Foundation

/// Persists per-app volume gain and bypass preferences keyed by bundle ID.
@MainActor
final class AppVolumeStore: ObservableObject {
    @Published private(set) var appVolumes: [String: Double]
    @Published private(set) var bypassedApps: Set<String>

    private let persistenceURL: URL

    init(fileManager: FileManager = .default) {
        self.persistenceURL = Self.persistenceURL(fileManager: fileManager)
        let persisted = Self.loadPersistedState(from: persistenceURL)
        appVolumes = persisted?.appVolumes ?? [:]
        bypassedApps = persisted?.bypassedApps ?? []
    }

    init(persistenceURL: URL) {
        self.persistenceURL = persistenceURL
        let persisted = Self.loadPersistedState(from: persistenceURL)
        appVolumes = persisted?.appVolumes ?? [:]
        bypassedApps = persisted?.bypassedApps ?? []
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

    /// Whether an app is in bypass mode (verbatim pass-through, no EQ/gain).
    func isBypassed(_ bundleID: String) -> Bool {
        bypassedApps.contains(bundleID)
    }

    /// Sets bypass mode for an app. Bypassed apps are tapped but their audio
    /// is copied verbatim to the output — no gain, no EQ, no preamp, no clamping.
    func setBypassed(_ bypassed: Bool, for bundleID: String) {
        if bypassed {
            bypassedApps.insert(bundleID)
        } else {
            bypassedApps.remove(bundleID)
        }
        save()
    }

    /// Removes stored preferences for apps no longer in the given active set.
    func pruneStaleApps(keeping activeBundleIDs: Set<String>) {
        let volumeKeysToRemove = Set(appVolumes.keys).subtracting(activeBundleIDs)
        let bypassKeysToRemove = bypassedApps.subtracting(activeBundleIDs)
        guard !volumeKeysToRemove.isEmpty || !bypassKeysToRemove.isEmpty else { return }
        for key in volumeKeysToRemove { appVolumes.removeValue(forKey: key) }
        bypassedApps.subtract(bypassKeysToRemove)
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
                bypassedApps: bypassedApps
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
        var bypassedApps: Set<String>

        init(appVolumes: [String: Double] = [:], bypassedApps: Set<String> = []) {
            self.appVolumes = appVolumes
            self.bypassedApps = bypassedApps
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            appVolumes = try container.decodeIfPresent([String: Double].self, forKey: .appVolumes) ?? [:]
            bypassedApps = try container.decodeIfPresent(Set<String>.self, forKey: .bypassedApps) ?? []
        }
    }
}