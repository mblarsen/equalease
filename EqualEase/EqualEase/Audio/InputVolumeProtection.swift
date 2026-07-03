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
        case .notRequested:
            String(localized: "Not requested", comment: "Notification permission status before EqualEase has asked macOS for permission.")
        case .authorized:
            String(localized: "Allowed", comment: "Notification permission status when macOS allows EqualEase notifications.")
        case .denied:
            String(localized: "Denied in macOS", comment: "Notification permission status when macOS notification permission has been denied.")
        case .unavailable:
            String(localized: "Notification permission: Unavailable", defaultValue: "Unavailable", comment: "Notification permission status when EqualEase cannot read notification permission.")
        }
    }
}

@MainActor
protocol InputVolumeProtectionNotifying: AnyObject {
    func refreshAuthorizationStatus() async -> InputVolumeProtectionNotificationStatus
    func requestAuthorization() async -> InputVolumeProtectionNotificationStatus
    func postLowInputVolumeNotification(deviceName: String, volume: Double, threshold: Double) async -> Bool
}

struct InputVolumeProtectionNotificationPolicy {
    let initialBackoff: TimeInterval
    let maximumBackoff: TimeInterval
    let recoveryGracePeriod: TimeInterval

    private(set) var lastNotificationDate: Date?
    private(set) var nextNotificationInterval: TimeInterval = 0
    private(set) var healthySince: Date?

    static let `default` = InputVolumeProtectionNotificationPolicy(
        initialBackoff: 5,
        maximumBackoff: 60,
        recoveryGracePeriod: 5 * 60
    )

    mutating func recordLowVolume(at date: Date) {
        if let healthySince, date.timeIntervalSince(healthySince) >= recoveryGracePeriod {
            reset()
        }
        healthySince = nil
    }

    mutating func recordHealthyVolume(at date: Date) {
        healthySince = healthySince ?? date
    }

    func shouldNotify(at date: Date) -> Bool {
        guard let lastNotificationDate else { return true }
        return date.timeIntervalSince(lastNotificationDate) >= nextNotificationInterval
    }

    mutating func recordNotificationSent(at date: Date) {
        lastNotificationDate = date
        healthySince = nil
        nextNotificationInterval = nextNotificationInterval > 0
            ? min(nextNotificationInterval * 2, maximumBackoff)
            : initialBackoff
    }

    mutating func reset() {
        lastNotificationDate = nil
        nextNotificationInterval = 0
        healthySince = nil
    }
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
        content.title = String(localized: "Microphone input volume is low", comment: "Local notification title for low microphone input volume.")
        content.body = String(
            localized: "\(deviceName) is at \(Int(volume * 100))%, below your \(Int(threshold * 100))% low-volume threshold.",
            comment: "Local notification body. Interpolations are input device name, current input volume percentage, and configured low-volume threshold percentage."
        )
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
