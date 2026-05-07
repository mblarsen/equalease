//
//  LocalNetworkAuthStoreRateLimitTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class LocalNetworkAuthStoreRateLimitTests: XCTestCase {
    @MainActor
    func testPairingRejectsTooManyInvalidCodeAttempts() throws {
        let url = temporaryAuthURL()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = LocalNetworkAuthStore(persistenceURL: url, now: { now })
        let session = store.beginPairing()

        let wrongCode = wrongPairingCode(avoiding: session.code)
        for _ in 1...4 {
            XCTAssertThrowsError(try store.pair(code: wrongCode, clientName: "Phone")) { error in
                XCTAssertEqual(error as? LocalNetworkAuthStore.AuthError, .invalidPairingCode)
            }
        }

        XCTAssertThrowsError(try store.pair(code: wrongCode, clientName: "Phone")) { error in
            XCTAssertEqual(error as? LocalNetworkAuthStore.AuthError, .pairingRateLimited)
        }
        XCTAssertThrowsError(try store.pair(code: session.code, clientName: "Phone")) { error in
            XCTAssertEqual(error as? LocalNetworkAuthStore.AuthError, .pairingRateLimited)
        }

        now = now.addingTimeInterval(5 * 60 + 1)
        let fresh = store.beginPairing()
        XCTAssertNoThrow(try store.pair(code: fresh.code, clientName: "Phone"))
    }

    @MainActor
    func testPairingAllowsCorrectCodeBeforeRateLimit() throws {
        let store = LocalNetworkAuthStore(persistenceURL: temporaryAuthURL())
        let session = store.beginPairing()

        let wrongCode = wrongPairingCode(avoiding: session.code)
        for _ in 1...4 {
            XCTAssertThrowsError(try store.pair(code: wrongCode, clientName: "Phone")) { error in
                XCTAssertEqual(error as? LocalNetworkAuthStore.AuthError, .invalidPairingCode)
            }
        }

        let credential = try store.pair(code: session.code, clientName: "Phone")
        XCTAssertEqual(credential.clientName, "Phone")
    }

    private func wrongPairingCode(avoiding code: String) -> String {
        code == "000000" ? "111111" : "000000"
    }

    private func temporaryAuthURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("local-network-auth.json")
    }
}
