//
//  InputVolumeProtection.swift
//  EqualEase
//

import Foundation
import UserNotifications

struct InputVolumeProtectionSettings: Equatable {
    var threshold: Double
    var capMinimum: Double
    var notificationsEnabled: Bool
    var capEnabled: Bool

    static let defaults = InputVolumeProtectionSettings(
        threshold: 0.35,
        capMinimum: 0.5,
        notificationsEnabled: false,
        capEnabled: false
    )

    var normalized: InputVolumeProtectionSettings {
        let threshold = min(max(threshold, 0), 1)
        let capMinimum = min(max(max(capMinimum, threshold), 0), 1)
        return InputVolumeProtectionSettings(
            threshold: threshold,
            capMinimum: capMinimum,
            notificationsEnabled: notificationsEnabled,
            capEnabled: capEnabled
        )
    }
}

enum InputVolumeProtectionSettingsStore {
    static let thresholdKey = "inputVolumeProtectionThreshold"
    static let capMinimumKey = "inputVolumeProtectionCapMinimum"
    static let notificationsEnabledKey = "inputVolumeProtectionNotificationsEnabled"
    static let capEnabledKey = "inputVolumeProtectionCapEnabled"

    static func load(userDefaults: UserDefaults = .standard) -> InputVolumeProtectionSettings {
        let defaults = InputVolumeProtectionSettings.defaults
        let threshold = userDefaults.object(forKey: thresholdKey) as? Double ?? defaults.threshold
        let capMinimum = userDefaults.object(forKey: capMinimumKey) as? Double ?? defaults.capMinimum
        let notificationsEnabled = userDefaults.object(forKey: notificationsEnabledKey) as? Bool ?? defaults.notificationsEnabled
        let capEnabled = userDefaults.object(forKey: capEnabledKey) as? Bool ?? defaults.capEnabled
        return InputVolumeProtectionSettings(
            threshold: threshold,
            capMinimum: capMinimum,
            notificationsEnabled: notificationsEnabled,
            capEnabled: capEnabled
        ).normalized
    }

    static func save(_ settings: InputVolumeProtectionSettings, userDefaults: UserDefaults = .standard) {
        let normalized = settings.normalized
        userDefaults.set(normalized.threshold, forKey: thresholdKey)
        userDefaults.set(normalized.capMinimum, forKey: capMinimumKey)
        userDefaults.set(normalized.notificationsEnabled, forKey: notificationsEnabledKey)
        userDefaults.set(normalized.capEnabled, forKey: capEnabledKey)
    }
}

enum InputVolumeProtectionNotificationStatus: Equatable {
    case notRequested
    case authorized
    case denied
    case unavailable

    var summary: String {
        switch self {
        case .notRequested: "Not requested"
        case .authorized: "Allowed"
        case .denied: "Denied in macOS"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor
protocol InputVolumeProtectionNotifying: AnyObject {
    func refreshAuthorizationStatus() async -> InputVolumeProtectionNotificationStatus
    func requestAuthorization() async -> InputVolumeProtectionNotificationStatus
    func postLowInputVolumeNotification(deviceName: String, volume: Double, threshold: Double) async -> Bool
}

@MainActor
final class UserNotificationInputVolumeProtectionNotifier: InputVolumeProtectionNotifying {
    func refreshAuthorizationStatus() async -> InputVolumeProtectionNotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notRequested
        @unknown default:
            return .unavailable
        }
    }

    func requestAuthorization() async -> InputVolumeProtectionNotificationStatus {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            return .unavailable
        }
    }

    func postLowInputVolumeNotification(deviceName: String, volume: Double, threshold: Double) async -> Bool {
        var status = await refreshAuthorizationStatus()
        if status == .notRequested {
            status = await requestAuthorization()
        }
        guard status == .authorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Microphone input volume is low"
        content.body = "\(deviceName) is at \(Int(volume * 100))%, below your \(Int(threshold * 100))% low-volume threshold."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "equalease-low-input-volume-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}
