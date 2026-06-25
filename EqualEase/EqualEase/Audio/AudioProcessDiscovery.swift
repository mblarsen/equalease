//
//  AudioProcessDiscovery.swift
//  EqualEase
//

import AppKit
import Combine
import CoreAudio
import Foundation

/// Identity of an audio-emitting app discovered via CoreAudio process objects.
struct AudioAppIdentity: Identifiable, Equatable, Sendable {
    /// The CoreAudio process object ID (stable within a boot session).
    let processObjectID: AudioObjectID
    /// The Unix process ID.
    let pid: pid_t
    /// The app's bundle identifier (e.g. "com.apple.Safari").
    let bundleID: String
    /// Human-readable display name resolved via NSWorkspace.
    let displayName: String

    var id: AudioObjectID { processObjectID }

    static func sortedForDisplay(_ apps: [AudioAppIdentity]) -> [AudioAppIdentity] {
        apps.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            let bundleOrder = lhs.bundleID.localizedCaseInsensitiveCompare(rhs.bundleID)
            if bundleOrder != .orderedSame {
                return bundleOrder == .orderedAscending
            }

            if lhs.pid != rhs.pid {
                return lhs.pid < rhs.pid
            }

            return lhs.processObjectID < rhs.processObjectID
        }
    }

    static func uniqueBundleRepresentativesForDisplay(_ apps: [AudioAppIdentity]) -> [AudioAppIdentity] {
        var seenBundleIDs: Set<String> = []
        return sortedForDisplay(apps).filter { app in
            seenBundleIDs.insert(app.bundleID).inserted
        }
    }
}

@MainActor
protocol AudioProcessDiscovering: AnyObject {
    /// Currently discovered audio-emitting apps, excluding EqualEase's own process.
    var discoveredApps: [AudioAppIdentity] { get }
    /// Start polling for audio processes. Called when routing starts.
    func startPolling()
    /// Stop polling. Called when routing stops.
    func stopPolling()
}

@MainActor
final class AudioProcessDiscovery: AudioProcessDiscovering, ObservableObject {
    @Published private(set) var discoveredApps: [AudioAppIdentity] = []

    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval
    private let ownPID: pid_t

    init(pollingInterval: TimeInterval = 2.0) {
        self.pollingInterval = pollingInterval
        self.ownPID = getpid()
    }

    func startPolling() {
        guard pollingTimer == nil else { return }
        refresh()
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        discoveredApps = []
    }

    // MARK: - Internal

    private func refresh() {
        var apps: [AudioAppIdentity] = []
        do {
            let processObjectIDs = try readAudioObjectIDs(
                selector: kAudioHardwarePropertyProcessObjectList
            )
            for processObjectID in processObjectIDs {
                guard let app = try? makeAppIdentity(processObjectID: processObjectID) else { continue }
                guard app.pid != ownPID else { continue }
                apps.append(app)
            }
        } catch {
            NSLog("EqualEase audio-process discovery failed: %@", error.localizedDescription)
        }
        if apps != discoveredApps {
            discoveredApps = apps
        }
    }

    private func makeAppIdentity(processObjectID: AudioObjectID) throws -> AudioAppIdentity {
        let pid = try readAudioObjectPID(objectID: processObjectID)

        // Read bundle ID — skip processes without one (system-level audio helpers).
        guard let bundleID = try? readAudioObjectString(
            objectID: processObjectID,
            selector: kAudioProcessPropertyBundleID
        ), !bundleID.isEmpty else {
            throw CoreAudioRoutingError.propertyReadFailed("kAudioProcessPropertyBundleID", -1)
        }

        // Check isRunningOutput — only include apps actually emitting audio.
        let isRunningOutput = (try? readAudioObjectUInt32(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput
        )) == 1

        guard isRunningOutput else {
            throw CoreAudioRoutingError.propertyReadFailed("kAudioProcessPropertyIsRunningOutput", -1)
        }

        let displayName = resolveDisplayName(pid: pid, bundleID: bundleID)

        return AudioAppIdentity(
            processObjectID: processObjectID,
            pid: pid,
            bundleID: bundleID,
            displayName: displayName
        )
    }

    private func resolveDisplayName(pid: pid_t, bundleID: String) -> String {
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier == pid {
            if let localizedName = cleanedDisplayName(app.localizedName), localizedName != "main" {
                return localizedName
            }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: appURL) {
            let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            if let name = cleanedDisplayName(displayName ?? bundleName), name != "main" {
                return name
            }
        }

        return bundleID
    }

    private func cleanedDisplayName(_ name: String?) -> String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? nil : trimmedName
    }
}