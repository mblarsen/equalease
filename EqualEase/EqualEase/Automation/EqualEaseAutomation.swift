//
//  EqualEaseAutomation.swift
//  EqualEase
//

import Foundation

enum EqualEaseAutomationError: LocalizedError, Equatable {
    case appModelUnavailable
    case invalidURL(String)
    case unsupportedURLAction(String)
    case missingValue(String)
    case unknownPreset(String)
    case invalidLevel(String)
    case invalidBypassValue(String)
    case invalidActiveValue(String)
    case invalidPresetLockValue(String)
    case externalAutomationWritesDisabled(String)
    case customPresetWritesDisabled(String)

    var errorDescription: String? {
        switch self {
        case .appModelUnavailable:
            "EqualEase is not ready yet."
        case let .invalidURL(url):
            "Invalid EqualEase URL: \(url)"
        case let .unsupportedURLAction(action):
            "Unsupported EqualEase URL action: \(action)"
        case let .missingValue(action):
            "Missing value for EqualEase action: \(action)"
        case let .unknownPreset(name):
            "Unknown EqualEase preset: \(name)"
        case let .invalidLevel(level):
            "Invalid EqualEase level: \(level)"
        case let .invalidBypassValue(value):
            "Invalid EqualEase bypass value: \(value)"
        case let .invalidActiveValue(value):
            "Invalid EqualEase active value: \(value)"
        case let .invalidPresetLockValue(value):
            "Invalid EqualEase preset lock value: \(value)"
        case let .externalAutomationWritesDisabled(action):
            "External automation is not allowed to change EqualEase \(action). Enable it in Settings > General."
        case let .customPresetWritesDisabled(name):
            "External automation can only select built-in presets while sound-setting changes are disabled. Enable it in Settings > General to select custom preset: \(name)"
        }
    }
}

enum EqualEaseAutomationCommand: Equatable {
    case listPresets
    case selectPreset(name: String)
    case currentPresetName
    case setPreamp(rawValue: String)
    case currentPreamp
    case setOutputVolume(rawValue: String)
    case currentOutputVolume
    case setBypass(rawValue: String)
    case bypassState
    case toggleBypass
    case setActive(rawValue: String)
    case activeState
    case toggleActive
    case lockPreset(name: String?)
    case unlockPreset
    case presetLockState
    case togglePresetLock
}

enum EqualEaseAutomationResult: Equatable {
    case strings([String])
    case string(String)
    case number(Double)
    case boolean(Bool)
}

@MainActor
protocol EqualEaseAutomationCommandTarget: AnyObject {
    var automationPresets: [EQPreset] { get }
    var automationCurrentPresetName: String { get }
    var automationPreamp: Double { get set }
    var automationOutputVolume: Double { get set }
    var automationIsBypassed: Bool { get set }
    var automationIsActive: Bool { get set }
    var automationIsPresetLocked: Bool { get }

    func selectAutomationPreset(_ preset: EQPreset)
    func lockAutomationPreset(_ preset: EQPreset?)
    func unlockAutomationPreset()
    func toggleAutomationPresetLock() -> Bool
}

@MainActor
final class EqualEaseAutomationCommandModule {
    private let target: any EqualEaseAutomationCommandTarget
    private let allowsExternalAutomationWrites: () -> Bool

    init(
        target: any EqualEaseAutomationCommandTarget,
        allowsExternalAutomationWrites: @escaping () -> Bool = { EqualEaseSettings.allowsExternalAutomationWrites }
    ) {
        self.target = target
        self.allowsExternalAutomationWrites = allowsExternalAutomationWrites
    }

    func command(for url: URL) throws -> EqualEaseAutomationCommand {
        guard url.scheme?.localizedLowercase == "equalease" else {
            throw EqualEaseAutomationError.invalidURL(url.absoluteString)
        }

        let segments = urlSegments(from: url)
        guard let action = segments.first?.localizedLowercase else {
            throw EqualEaseAutomationError.invalidURL(url.absoluteString)
        }

        let value = segments.dropFirst().joined(separator: "/")
        switch action {
        case "preset":
            guard !value.isEmpty else { throw EqualEaseAutomationError.missingValue(action) }
            return .selectPreset(name: value)
        case "preamp":
            guard !value.isEmpty else { throw EqualEaseAutomationError.missingValue(action) }
            return .setPreamp(rawValue: value)
        case "volume":
            guard !value.isEmpty else { throw EqualEaseAutomationError.missingValue(action) }
            return .setOutputVolume(rawValue: value)
        case "bypass":
            guard !value.isEmpty else { throw EqualEaseAutomationError.missingValue(action) }
            return .setBypass(rawValue: value)
        case "active":
            guard !value.isEmpty else { throw EqualEaseAutomationError.missingValue(action) }
            return .setActive(rawValue: value)
        case "lock":
            guard segments.count >= 2 else { throw EqualEaseAutomationError.missingValue(action) }
            let lockValue = segments[1].localizedLowercase
            let presetName = segments.dropFirst(2).joined(separator: "/")
            switch lockValue {
            case "on", "yes":
                return .lockPreset(name: presetName.isEmpty ? nil : presetName)
            case "off", "no":
                return .unlockPreset
            case "toggle":
                return .togglePresetLock
            default:
                throw EqualEaseAutomationError.invalidPresetLockValue(segments[1])
            }
        default:
            throw EqualEaseAutomationError.unsupportedURLAction(action)
        }
    }

    func execute(_ command: EqualEaseAutomationCommand) throws -> EqualEaseAutomationResult {
        switch command {
        case .listPresets:
            return .strings(target.automationPresets.map(\.name))
        case let .selectPreset(name):
            let preset = try preset(named: name)
            try ensurePresetWriteAllowed(preset)
            target.selectAutomationPreset(preset)
            return .string(preset.name)
        case .currentPresetName:
            return .string(target.automationCurrentPresetName)
        case let .setPreamp(rawValue):
            try ensureSoundSettingWriteAllowed("Preamp")
            let normalized = try normalizedLevel(rawValue, upperBound: 2)
            target.automationPreamp = normalized
            return .number(target.automationPreamp * 100)
        case .currentPreamp:
            return .number(target.automationPreamp * 100)
        case let .setOutputVolume(rawValue):
            try ensureSoundSettingWriteAllowed("Volume")
            let normalized = try normalizedLevel(rawValue, upperBound: 1)
            target.automationOutputVolume = normalized
            return .number(target.automationOutputVolume * 100)
        case .currentOutputVolume:
            return .number(target.automationOutputVolume * 100)
        case let .setBypass(rawValue):
            try ensureSoundSettingWriteAllowed("Bypass")
            switch try normalizedBypassValue(rawValue) {
            case .yes:
                target.automationIsBypassed = true
            case .no:
                target.automationIsBypassed = false
            case .toggle:
                target.automationIsBypassed.toggle()
            }
            return .boolean(target.automationIsBypassed)
        case .bypassState:
            return .boolean(target.automationIsBypassed)
        case .toggleBypass:
            try ensureSoundSettingWriteAllowed("Bypass")
            target.automationIsBypassed.toggle()
            return .boolean(target.automationIsBypassed)
        case let .setActive(rawValue):
            try ensureSoundSettingWriteAllowed("Active")
            switch try normalizedActiveValue(rawValue) {
            case .on:
                target.automationIsActive = true
            case .off:
                target.automationIsActive = false
            case .toggle:
                target.automationIsActive.toggle()
            }
            return .boolean(target.automationIsActive)
        case .activeState:
            return .boolean(target.automationIsActive)
        case .toggleActive:
            try ensureSoundSettingWriteAllowed("Active")
            target.automationIsActive.toggle()
            return .boolean(target.automationIsActive)
        case let .lockPreset(name):
            try ensureSoundSettingWriteAllowed("Preset Lock")
            target.lockAutomationPreset(try optionalPreset(named: name))
            return .boolean(target.automationIsPresetLocked)
        case .unlockPreset:
            try ensureSoundSettingWriteAllowed("Preset Lock")
            target.unlockAutomationPreset()
            return .boolean(target.automationIsPresetLocked)
        case .presetLockState:
            return .boolean(target.automationIsPresetLocked)
        case .togglePresetLock:
            try ensureSoundSettingWriteAllowed("Preset Lock")
            return .boolean(target.toggleAutomationPresetLock())
        }
    }

    private enum BypassValue {
        case yes
        case no
        case toggle
    }

    private enum ActiveValue {
        case on
        case off
        case toggle
    }

    private func ensureSoundSettingWriteAllowed(_ action: String) throws {
        guard allowsExternalAutomationWrites() else {
            throw EqualEaseAutomationError.externalAutomationWritesDisabled(action)
        }
    }

    private func ensurePresetWriteAllowed(_ preset: EQPreset) throws {
        guard allowsExternalAutomationWrites() || preset.source == .builtIn else {
            throw EqualEaseAutomationError.customPresetWritesDisabled(preset.name)
        }
    }

    private func optionalPreset(named name: String?) throws -> EQPreset? {
        guard let name else { return nil }
        return try preset(named: name)
    }

    private func preset(named name: String) throws -> EQPreset {
        let normalizedName = normalizedPresetName(name)
        if let preset = target.automationPresets.first(where: { normalizedPresetName($0.name) == normalizedName })
            ?? target.automationPresets.first(where: { normalizedPresetName($0.id) == normalizedName }) {
            return preset
        }
        throw EqualEaseAutomationError.unknownPreset(name)
    }

    private func normalizedPresetName(_ name: String) -> String {
        name.removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            ?? name.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }

    private func normalizedLevel(_ rawValue: String, upperBound: Double) throws -> Double {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPercent = trimmed.hasSuffix("%")
        let numericText = hasPercent ? String(trimmed.dropLast()) : trimmed
        guard let value = Double(numericText) else {
            throw EqualEaseAutomationError.invalidLevel(rawValue)
        }

        let normalized = hasPercent || value > upperBound ? value / 100 : value
        return min(max(normalized, 0), upperBound)
    }

    private func normalizedBypassValue(_ rawValue: String) throws -> BypassValue {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
        case "yes":
            return .yes
        case "no":
            return .no
        case "toggle":
            return .toggle
        default:
            throw EqualEaseAutomationError.invalidBypassValue(rawValue)
        }
    }

    private func normalizedActiveValue(_ rawValue: String) throws -> ActiveValue {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
        case "on":
            return .on
        case "off":
            return .off
        case "toggle":
            return .toggle
        default:
            throw EqualEaseAutomationError.invalidActiveValue(rawValue)
        }
    }

    private func urlSegments(from url: URL) -> [String] {
        var components: [String] = []
        if let host = url.host, !host.isEmpty {
            components.append(host)
        }
        components.append(contentsOf: url.path.split(separator: "/").map(String.init))
        return components.map { segment in
            (segment.removingPercentEncoding ?? segment).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

@MainActor
final class EqualEaseAutomation {
    static let shared = EqualEaseAutomation()

    private weak var target: (any EqualEaseAutomationCommandTarget)?

    private init() {}

    func configure(appModel: EqualEaseAppModel) {
        target = appModel
    }

    var presetNames: [String] {
        (try? execute(.listPresets).stringsValue) ?? []
    }

    var currentPresetName: String {
        get { (try? execute(.currentPresetName).stringValue) ?? "" }
        set { _ = try? selectPreset(named: newValue) }
    }

    var preampPercent: Double {
        get { (try? execute(.currentPreamp).numberValue) ?? 0 }
        set { _ = try? setPreamp(String(newValue)) }
    }

    var outputVolumePercent: Double {
        get { (try? execute(.currentOutputVolume).numberValue) ?? 0 }
        set { _ = try? setOutputVolume(String(newValue)) }
    }

    var isBypassed: Bool {
        get { (try? execute(.bypassState).booleanValue) ?? false }
        set { _ = try? setBypass(newValue ? "yes" : "no") }
    }

    var isActive: Bool {
        get { (try? execute(.activeState).booleanValue) ?? false }
        set { _ = try? setActive(newValue ? "on" : "off") }
    }

    func command(for url: URL) throws -> EqualEaseAutomationCommand {
        try commandModule().command(for: url)
    }

    @discardableResult
    func execute(_ command: EqualEaseAutomationCommand) throws -> EqualEaseAutomationResult {
        try commandModule().execute(command)
    }

    @discardableResult
    func selectPreset(named name: String) throws -> String {
        try execute(.selectPreset(name: name)).stringValue
    }

    @discardableResult
    func setPreamp(_ value: String) throws -> Double {
        try execute(.setPreamp(rawValue: value)).numberValue
    }

    @discardableResult
    func setOutputVolume(_ value: String) throws -> Double {
        try execute(.setOutputVolume(rawValue: value)).numberValue
    }

    @discardableResult
    func setBypass(_ value: String) throws -> Bool {
        try execute(.setBypass(rawValue: value)).booleanValue
    }

    @discardableResult
    func toggleBypass() throws -> Bool {
        try execute(.toggleBypass).booleanValue
    }

    @discardableResult
    func setActive(_ value: String) throws -> Bool {
        try execute(.setActive(rawValue: value)).booleanValue
    }

    @discardableResult
    func toggleActive() throws -> Bool {
        try execute(.toggleActive).booleanValue
    }

    var isPresetLocked: Bool {
        get { (try? execute(.presetLockState).booleanValue) ?? false }
        set { _ = try? execute(newValue ? .lockPreset(name: nil) : .unlockPreset) }
    }

    @discardableResult
    func lockPreset(named name: String? = nil) throws -> Bool {
        try execute(.lockPreset(name: name)).booleanValue
    }

    @discardableResult
    func unlockPreset() throws -> Bool {
        try execute(.unlockPreset).booleanValue
    }

    @discardableResult
    func togglePresetLock() throws -> Bool {
        try execute(.togglePresetLock).booleanValue
    }

    func handle(url: URL) throws {
        try execute(command(for: url))
    }

    private func commandModule() throws -> EqualEaseAutomationCommandModule {
        guard let target else { throw EqualEaseAutomationError.appModelUnavailable }
        return EqualEaseAutomationCommandModule(target: target)
    }
}

@MainActor
extension EqualEaseAppModel: EqualEaseAutomationCommandTarget {
    var automationPresets: [EQPreset] {
        presetStore.presets
    }

    var automationCurrentPresetName: String {
        activeContext?.preset.name ?? ""
    }

    var automationPreamp: Double {
        get { router.outputGain }
        set { router.outputGain = min(max(newValue, 0), 2) }
    }

    var automationOutputVolume: Double {
        get { router.outputVolume }
        set { router.outputVolume = min(max(newValue, 0), 1) }
    }

    var automationIsBypassed: Bool {
        get { router.isBypassed }
        set { router.isBypassed = newValue }
    }

    var automationIsActive: Bool {
        get { router.isRunning }
        set {
            if newValue {
                router.start()
            } else {
                router.stop()
            }
        }
    }

    var automationIsPresetLocked: Bool {
        EqualEaseSettings.isPresetLocked
    }

    func selectAutomationPreset(_ preset: EQPreset) {
        selectPreset(id: preset.id)
    }

    func lockAutomationPreset(_ preset: EQPreset?) {
        if let preset {
            lockPreset(id: preset.id)
        } else {
            lockCurrentPreset()
        }
    }

    func unlockAutomationPreset() {
        unlockPreset()
    }

    func toggleAutomationPresetLock() -> Bool {
        togglePresetLock()
    }
}

private extension EqualEaseAutomationResult {
    var stringsValue: [String] {
        get throws {
            guard case let .strings(value) = self else { throw EqualEaseAutomationError.appModelUnavailable }
            return value
        }
    }

    var stringValue: String {
        get throws {
            guard case let .string(value) = self else { throw EqualEaseAutomationError.appModelUnavailable }
            return value
        }
    }

    var numberValue: Double {
        get throws {
            guard case let .number(value) = self else { throw EqualEaseAutomationError.appModelUnavailable }
            return value
        }
    }

    var booleanValue: Bool {
        get throws {
            guard case let .boolean(value) = self else { throw EqualEaseAutomationError.appModelUnavailable }
            return value
        }
    }
}
