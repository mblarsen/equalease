//
//  AudioAppIdentityDisplayTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class AudioAppIdentityDisplayTests: XCTestCase {
    func testSortedForDisplayKeepsDuplicateBundleRowsWithUniqueProcessIdentities() {
        let apps = [
            AudioAppIdentity(processObjectID: 30, pid: 300, bundleID: "com.example.Player", displayName: "Player"),
            AudioAppIdentity(processObjectID: 10, pid: 100, bundleID: "com.example.Player", displayName: "Player"),
            AudioAppIdentity(processObjectID: 20, pid: 200, bundleID: "com.example.Browser", displayName: "Browser"),
        ]

        let rows = AudioAppIdentity.sortedForDisplay(apps)

        XCTAssertEqual(rows.map(\.processObjectID), [20, 10, 30])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testUniqueBundleRepresentativesForDisplayUsesStableBundleIdentity() {
        let apps = [
            AudioAppIdentity(processObjectID: 30, pid: 300, bundleID: "com.example.Player", displayName: "Player"),
            AudioAppIdentity(processObjectID: 10, pid: 100, bundleID: "com.example.Player", displayName: "Player"),
            AudioAppIdentity(processObjectID: 20, pid: 200, bundleID: "com.example.Browser", displayName: "Browser"),
        ]

        let rows = AudioAppIdentity.uniqueBundleRepresentativesForDisplay(apps)

        XCTAssertEqual(rows.map(\.bundleID), ["com.example.Browser", "com.example.Player"])
        XCTAssertEqual(rows.map(\.processObjectID), [20, 10])
        XCTAssertEqual(Set(rows.map(\.bundleID)).count, rows.count)
    }
}
