//
//  AppVolumeStoreTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class AppVolumeStoreTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: AppVolumeStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppVolumeStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let persistenceURL = tempDirectory.appendingPathComponent("app-volumes.json")
        store = AppVolumeStore(persistenceURL: persistenceURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultVolumeIsUnity() {
        XCTAssertEqual(store.volume(for: "com.example.App"), 1.0)
    }

    func testDefaultBypassIsFalse() {
        XCTAssertFalse(store.isBypassed("com.example.App"))
    }

    // MARK: - Volume

    func testSetVolumePersists() {
        store.setVolume(1.5, for: "com.example.App")
        XCTAssertEqual(store.volume(for: "com.example.App"), 1.5)
    }

    func testSetVolumeClampsToRange() {
        store.setVolume(3.0, for: "com.example.App")
        XCTAssertEqual(store.volume(for: "com.example.App"), 2.0)

        store.setVolume(-0.5, for: "com.example.App2")
        XCTAssertEqual(store.volume(for: "com.example.App2"), 0.0)
    }

    func testSetVolumeToUnityRemovesEntry() {
        store.setVolume(1.5, for: "com.example.App")
        store.setVolume(1.0, for: "com.example.App")
        XCTAssertNil(store.appVolumes["com.example.App"])
        XCTAssertEqual(store.volume(for: "com.example.App"), 1.0)
    }

    // MARK: - Bypass

    func testSetBypassed() {
        store.setBypassed(true, for: "com.example.App")
        XCTAssertTrue(store.isBypassed("com.example.App"))

        store.setBypassed(false, for: "com.example.App")
        XCTAssertFalse(store.isBypassed("com.example.App"))
    }

    // MARK: - Pruning

    func testPruneStaleApps() {
        store.setVolume(1.5, for: "com.example.Active")
        store.setVolume(0.8, for: "com.example.Stale")
        store.setBypassed(true, for: "com.example.Stale")
        store.setBypassed(true, for: "com.example.AlsoStale")

        store.pruneStaleApps(keeping: ["com.example.Active"])

        XCTAssertEqual(store.volume(for: "com.example.Active"), 1.5)
        XCTAssertEqual(store.volume(for: "com.example.Stale"), 1.0) // default
        XCTAssertFalse(store.isBypassed("com.example.Stale"))
        XCTAssertFalse(store.isBypassed("com.example.AlsoStale"))
    }

    // MARK: - Persistence

    func testPersistenceRoundTrip() {
        let persistenceURL = tempDirectory.appendingPathComponent("roundtrip-app-volumes.json")
        let original = AppVolumeStore(persistenceURL: persistenceURL)
        original.setVolume(1.5, for: "com.example.App1")
        original.setVolume(0.3, for: "com.example.App2")
        original.setBypassed(true, for: "com.example.App2")

        let loaded = AppVolumeStore(persistenceURL: persistenceURL)
        XCTAssertEqual(loaded.volume(for: "com.example.App1"), 1.5)
        XCTAssertEqual(loaded.volume(for: "com.example.App2"), 0.3)
        XCTAssertTrue(loaded.isBypassed("com.example.App2"))
        XCTAssertEqual(loaded.volume(for: "com.example.Unknown"), 1.0)
    }

    func testPersistenceWithMissingFile() {
        let persistenceURL = tempDirectory.appendingPathComponent("nonexistent.json")
        let store = AppVolumeStore(persistenceURL: persistenceURL)
        XCTAssertEqual(store.volume(for: "com.example.App"), 1.0)
        XCTAssertFalse(store.isBypassed("com.example.App"))
    }
}