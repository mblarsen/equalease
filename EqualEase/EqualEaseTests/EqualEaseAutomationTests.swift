//
//  EqualEaseAutomationTests.swift
//  EqualEaseTests
//

import AppKit
import XCTest
@testable import EqualEase

@MainActor
final class EqualEaseAutomationTests: XCTestCase {
    func testURLCommandParsingSupportsDocumentedActions() throws {
        let harness = AutomationHarness()

        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///preset/Voice%20Boost")),
            .selectPreset(name: "Voice Boost")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///preamp/125%25")),
            .setPreamp(rawValue: "125%")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///volume/0.45")),
            .setOutputVolume(rawValue: "0.45")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///bypass/toggle")),
            .setBypass(rawValue: "toggle")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///active/on")),
            .setActive(rawValue: "on")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///active/off")),
            .setActive(rawValue: "off")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///active/toggle")),
            .setActive(rawValue: "toggle")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///lock/on/Warm")),
            .lockPreset(name: "Warm")
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///lock/on")),
            .lockPreset(name: nil)
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///lock/off")),
            .unlockPreset
        )
        XCTAssertEqual(
            try harness.module.command(for: url("equalease:///lock/toggle")),
            .togglePresetLock
        )
    }

    func testURLCommandExecutionSupportsPresetPreampVolumeBypassAndActive() throws {
        let harness = AutomationHarness()

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///preset/voice%20boost"))),
            .string("Voice Boost")
        )
        XCTAssertEqual(harness.target.selectedPresetID, "built-in-voice-boost")

        assertNumber(
            try harness.module.execute(try harness.module.command(for: url("equalease:///preamp/125%25"))),
            equals: 125
        )
        XCTAssertEqual(harness.target.automationPreamp, 1.25, accuracy: 0.0001)

        assertNumber(
            try harness.module.execute(try harness.module.command(for: url("equalease:///volume/45"))),
            equals: 45
        )
        XCTAssertEqual(harness.target.automationOutputVolume, 0.45, accuracy: 0.0001)

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///bypass/yes"))),
            .boolean(true)
        )
        XCTAssertTrue(harness.target.automationIsBypassed)

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///active/on"))),
            .boolean(true)
        )
        XCTAssertTrue(harness.target.automationIsActive)

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///active/toggle"))),
            .boolean(false)
        )
        XCTAssertFalse(harness.target.automationIsActive)
    }

    func testURLCommandExecutionSupportsPresetLock() throws {
        let harness = AutomationHarness()

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///lock/on/Warm"))),
            .boolean(true)
        )
        XCTAssertEqual(harness.target.lockedPresetID, "built-in-warm")

        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///lock/off"))),
            .boolean(false)
        )
        XCTAssertNil(harness.target.lockedPresetID)

        harness.target.selectedPresetID = "built-in-voice-boost"
        XCTAssertEqual(
            try harness.module.execute(try harness.module.command(for: url("equalease:///lock/on"))),
            .boolean(true)
        )
        XCTAssertEqual(harness.target.lockedPresetID, "built-in-voice-boost")
    }

    func testAppleScriptAdapterMapsCommandValuesToSharedCommands() throws {
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .selectPreset,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "Warm"))
            ),
            .selectPreset(name: "Warm")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .setPreamp,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "90%"))
            ),
            .setPreamp(rawValue: "90%")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .setOutputVolume,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "45"))
            ),
            .setOutputVolume(rawValue: "45")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .setBypass,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "no"))
            ),
            .setBypass(rawValue: "no")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .setActive,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "toggle"))
            ),
            .setActive(rawValue: "toggle")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .activeState,
                event: appleEvent()
            ),
            .activeState
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .toggleActive,
                event: appleEvent()
            ),
            .toggleActive
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .lockPreset,
                event: appleEvent(directObject: NSAppleEventDescriptor(string: "Warm"))
            ),
            .lockPreset(name: "Warm")
        )
        XCTAssertEqual(
            try EqualEaseAppleScriptAdapter.automationCommand(
                for: .lockPreset,
                event: appleEvent()
            ),
            .lockPreset(name: nil)
        )
    }

    func testURLAndAppleScriptStyleCommandsHaveEquivalentBehavior() throws {
        let urlHarness = AutomationHarness()
        let appleScriptHarness = AutomationHarness()

        let urlCommand = try urlHarness.module.command(for: url("equalease:///preamp/90"))
        let appleScriptCommand = try EqualEaseAppleScriptAdapter.automationCommand(
            for: .setPreamp,
            event: appleEvent(directObject: NSAppleEventDescriptor(string: "90"))
        )

        assertNumber(try urlHarness.module.execute(urlCommand), equals: 90)
        assertNumber(try appleScriptHarness.module.execute(appleScriptCommand), equals: 90)
        XCTAssertEqual(urlHarness.target.automationPreamp, appleScriptHarness.target.automationPreamp, accuracy: 0.0001)
    }

    func testLevelValuesNormalizeConsistently() throws {
        for rawValue in ["90", "0.9", "90%"] {
            let harness = AutomationHarness()

            assertNumber(try harness.module.execute(.setPreamp(rawValue: rawValue)), equals: 90)
            XCTAssertEqual(harness.target.automationPreamp, 0.9, accuracy: 0.0001)
        }
    }

    func testAutomationSafetyPolicyAllowsReadsAndBuiltInPresetWhenWritesAreDisabled() throws {
        let harness = AutomationHarness(writesAllowed: false)
        harness.target.automationPreamp = 0.8
        harness.target.automationOutputVolume = 0.4
        harness.target.automationIsBypassed = true
        harness.target.automationIsActive = true

        XCTAssertEqual(try harness.module.execute(.listPresets), .strings(harness.target.automationPresets.map(\.name)))
        XCTAssertEqual(try harness.module.execute(.currentPresetName), .string("Flat"))
        XCTAssertEqual(try harness.module.execute(.currentPreamp), .number(80))
        XCTAssertEqual(try harness.module.execute(.currentOutputVolume), .number(40))
        XCTAssertEqual(try harness.module.execute(.bypassState), .boolean(true))
        XCTAssertEqual(try harness.module.execute(.activeState), .boolean(true))
        XCTAssertEqual(try harness.module.execute(.presetLockState), .boolean(false))

        XCTAssertEqual(try harness.module.execute(.selectPreset(name: "Warm")), .string("Warm"))
        XCTAssertEqual(harness.target.selectedPresetID, "built-in-warm")
    }

    func testAutomationSafetyPolicyBlocksSoundWritesAndCustomPresetWhenWritesAreDisabled() throws {
        let harness = AutomationHarness(writesAllowed: false)

        assertThrowsAutomationError(
            try harness.module.execute(.setPreamp(rawValue: "90")),
            equals: .externalAutomationWritesDisabled("Preamp")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.setOutputVolume(rawValue: "45")),
            equals: .externalAutomationWritesDisabled("Volume")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.setBypass(rawValue: "yes")),
            equals: .externalAutomationWritesDisabled("Bypass")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.toggleBypass),
            equals: .externalAutomationWritesDisabled("Bypass")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.setActive(rawValue: "on")),
            equals: .externalAutomationWritesDisabled("Active")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.toggleActive),
            equals: .externalAutomationWritesDisabled("Active")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.selectPreset(name: "Custom Speech")),
            equals: .customPresetWritesDisabled("Custom Speech")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.lockPreset(name: nil)),
            equals: .externalAutomationWritesDisabled("Preset Lock")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.togglePresetLock),
            equals: .externalAutomationWritesDisabled("Preset Lock")
        )
    }

    func testInvalidLevelErrorsAreClear() throws {
        let harness = AutomationHarness()

        assertThrowsAutomationError(
            try harness.module.execute(.setPreamp(rawValue: "loud")),
            equals: .invalidLevel("loud")
        )
        assertThrowsAutomationError(
            try harness.module.execute(.setOutputVolume(rawValue: "quiet")),
            equals: .invalidLevel("quiet")
        )
    }

    func testInvalidBypassValuesRejectAmbiguousOnOff() throws {
        let harness = AutomationHarness()

        for value in ["on", "off", "true", "false", "1", "0"] {
            assertThrowsAutomationError(
                try harness.module.execute(.setBypass(rawValue: value)),
                equals: .invalidBypassValue(value)
            )
        }
    }

    func testInvalidActiveValuesAreClear() throws {
        let harness = AutomationHarness()

        for value in ["yes", "no", "true", "false", "1", "0"] {
            assertThrowsAutomationError(
                try harness.module.execute(.setActive(rawValue: value)),
                equals: .invalidActiveValue(value)
            )
        }
    }

    func testUnknownPresetErrorsAreClear() throws {
        let harness = AutomationHarness()

        assertThrowsAutomationError(
            try harness.module.execute(.selectPreset(name: "Not A Preset")),
            equals: .unknownPreset("Not A Preset")
        )
    }

    func testAppleScriptValidationErrorsUseClearErrorReplyRatherThanUnhandledEvent() {
        let replyEvent = appleEvent()
        EqualEaseAppleScriptAdapter.setError(EqualEaseAutomationError.invalidBypassValue("on"), on: replyEvent)

        XCTAssertEqual(replyEvent.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, -10000)
        XCTAssertEqual(
            replyEvent.paramDescriptor(forKeyword: keyErrorString)?.stringValue,
            EqualEaseAutomationError.invalidBypassValue("on").localizedDescription
        )
    }

    private func url(_ rawValue: String) throws -> URL {
        try XCTUnwrap(URL(string: rawValue))
    }

    private func assertNumber(
        _ result: EqualEaseAutomationResult,
        equals expectedValue: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .number(actualValue) = result else {
            XCTFail("Expected number result, got \(result)", file: file, line: line)
            return
        }

        XCTAssertEqual(actualValue, expectedValue, accuracy: 0.0001, file: file, line: line)
    }

    private func assertThrowsAutomationError(
        _ expression: @autoclosure () throws -> EqualEaseAutomationResult,
        equals expectedError: EqualEaseAutomationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? EqualEaseAutomationError, expectedError, file: file, line: line)
        }
    }

    private func appleEvent(directObject: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(Self.fourCharacterCode("EEqs")),
            eventID: AEEventID(Self.fourCharacterCode("Test")),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        if let directObject {
            event.setParam(directObject, forKeyword: keyDirectObject)
        }

        return event
    }

    private static func fourCharacterCode(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}

@MainActor
private struct AutomationHarness {
    let target: TestAutomationTarget
    let module: EqualEaseAutomationCommandModule

    init(writesAllowed: Bool = true) {
        let policy = AutomationWritePolicy(isAllowed: writesAllowed)
        let target = TestAutomationTarget()
        self.target = target
        self.module = EqualEaseAutomationCommandModule(
            target: target,
            allowsExternalAutomationWrites: { policy.isAllowed }
        )
    }
}

private final class AutomationWritePolicy {
    var isAllowed: Bool

    init(isAllowed: Bool) {
        self.isAllowed = isAllowed
    }
}

@MainActor
private final class TestAutomationTarget: EqualEaseAutomationCommandTarget {
    var automationPresets: [EQPreset] = [
        EQPreset(id: "built-in-flat", name: "Flat", source: .builtIn, bandGains: Array(repeating: 0, count: 10), outputGain: 1),
        EQPreset(id: "built-in-voice-boost", name: "Voice Boost", source: .builtIn, bandGains: Array(repeating: 1, count: 10), outputGain: 0.9),
        EQPreset(id: "built-in-warm", name: "Warm", source: .builtIn, bandGains: Array(repeating: 2, count: 10), outputGain: 0.95),
        EQPreset(id: "custom-speech", name: "Custom Speech", source: .custom, bandGains: Array(repeating: 3, count: 10), outputGain: 0.8),
    ]
    var selectedPresetID = "built-in-flat"
    var automationPreamp = 1.0
    var automationOutputVolume = 1.0
    var automationIsBypassed = false
    var automationIsActive = false
    var lockedPresetID: String?

    var automationCurrentPresetName: String {
        automationPresets.first { $0.id == selectedPresetID }?.name ?? ""
    }

    var automationIsPresetLocked: Bool {
        lockedPresetID != nil
    }

    func selectAutomationPreset(_ preset: EQPreset) {
        selectedPresetID = preset.id
    }

    func lockAutomationPreset(_ preset: EQPreset?) {
        lockedPresetID = preset?.id ?? selectedPresetID
    }

    func unlockAutomationPreset() {
        lockedPresetID = nil
    }

    func toggleAutomationPresetLock() -> Bool {
        if automationIsPresetLocked {
            unlockAutomationPreset()
        } else {
            lockAutomationPreset(nil)
        }
        return automationIsPresetLocked
    }
}
