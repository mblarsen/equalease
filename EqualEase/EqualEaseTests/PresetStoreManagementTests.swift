//
//  PresetStoreManagementTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

@MainActor
final class PresetStoreManagementTests: XCTestCase {
    func testBuiltInPresetsRemainImmutable() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let builtInPreset = try XCTUnwrap(store.builtInPresets.first)

        store.renameCustomPreset(id: builtInPreset.id, name: "Renamed Flat")
        let updatedBuiltIn = store.updateCustomPreset(
            id: builtInPreset.id,
            bandGains: Array(repeating: 12, count: 10),
            outputGain: 2
        )
        store.deleteCustomPreset(id: builtInPreset.id)

        XCTAssertNil(updatedBuiltIn)
        XCTAssertEqual(store.preset(id: builtInPreset.id), builtInPreset)
        XCTAssertTrue(store.builtInPresets.contains(builtInPreset))
    }

    func testCustomPresetCanBeRenamedUpdatedDuplicatedAndDeleted() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())
        let customPreset = store.saveCurrentPreset(
            bandGains: Array(repeating: 1, count: 10),
            outputGain: 0.8
        )

        store.renameCustomPreset(id: customPreset.id, name: "Desk Voice")
        let updatedPreset = try XCTUnwrap(store.updateCustomPreset(
            id: customPreset.id,
            bandGains: [-20, -10, -5, 0, 2.25, 4, 8, 12, 20, 3, 99],
            outputGain: 3
        ))
        let duplicate = try XCTUnwrap(store.duplicatePreset(id: customPreset.id))
        store.deleteCustomPreset(id: customPreset.id)

        XCTAssertEqual(updatedPreset.name, "Desk Voice")
        XCTAssertEqual(updatedPreset.bandGains, [-12, -10, -5, 0, 2.25, 4, 8, 12, 12, 3])
        XCTAssertEqual(updatedPreset.outputGain, 2)
        XCTAssertEqual(duplicate.source, .custom)
        XCTAssertEqual(duplicate.name, "Desk Voice Copy")
        XCTAssertNil(store.preset(id: customPreset.id))
        XCTAssertNotNil(store.preset(id: duplicate.id))
    }

    func testSaveCurrentAsCustomNormalizesBandCountAndGainRange() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())

        let preset = store.saveCurrentPreset(
            bandGains: [-14, -1, 1],
            outputGain: -1
        )

        XCTAssertEqual(preset.name, "Flat Copy")
        XCTAssertEqual(preset.bandGains, [-12, -1, 1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(preset.outputGain, 0)
        XCTAssertEqual(store.selectedPresetID, preset.id)
    }

    func testSaveCurrentAsCustomUsesProvidedNameAndSuggestsAvailableCopyName() throws {
        let store = PresetStore(persistenceURL: temporaryPresetURL())

        XCTAssertEqual(store.suggestedCopyName(for: "Flat"), "Flat Copy")

        let preset = store.saveCurrentPreset(
            name: "  Flat Copy  ",
            bandGains: Array(repeating: 0, count: 10),
            outputGain: 1
        )

        XCTAssertEqual(preset.name, "Flat Copy")
        XCTAssertEqual(store.suggestedCopyName(for: "Flat"), "Flat Copy 2")
    }

    private func temporaryPresetURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EqualEaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("presets.json")
    }
}
