//
//  LocalNetworkControlTests.swift
//  EqualEaseTests
//

import XCTest
@testable import EqualEase

final class LocalNetworkControlTests: XCTestCase {
    func testWebSocketAcceptValueMatchesRFCExample() {
        XCTAssertEqual(
            LocalNetworkControlServer.webSocketAcceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testServerStateStatusUsesSingleLANURL() {
        let state = LocalNetworkServerState.running(port: 8787, lanURLs: ["http://192.168.100.26:8787"])

        XCTAssertEqual(state.statusText, "Running at http://192.168.100.26:8787")
    }

    func testUsableLANIPv4AddressRejectsNonDeviceReachableAddresses() {
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("169.254.61.196"))
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("127.0.0.1"))
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("0.0.0.0"))
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("224.0.0.1"))
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("255.255.255.255"))
        XCTAssertFalse(LocalNetworkControlServer.isUsableLANIPv4Address("not-an-ip"))
        XCTAssertTrue(LocalNetworkControlServer.isUsableLANIPv4Address("192.168.100.26"))
    }

    func testPhoneReachableInterfaceNamesRejectVirtualAdapters() {
        XCTAssertTrue(LocalNetworkControlServer.isPhoneReachableInterfaceName("en0"))
        XCTAssertTrue(LocalNetworkControlServer.isPhoneReachableInterfaceName("en10"))
        XCTAssertFalse(LocalNetworkControlServer.isPhoneReachableInterfaceName("bridge100"))
        XCTAssertFalse(LocalNetworkControlServer.isPhoneReachableInterfaceName("utun8"))
        XCTAssertFalse(LocalNetworkControlServer.isPhoneReachableInterfaceName("awdl0"))
        XCTAssertFalse(LocalNetworkControlServer.isPhoneReachableInterfaceName("lo0"))
    }

    func testLANIPAddressesExposeAtMostOnePrimaryURLAddress() {
        XCTAssertLessThanOrEqual(LocalNetworkControlServer.lanIPAddresses().count, 1)
    }

    func testProtocolParserAcceptsEnvelopeAndCommands() throws {
        let data = Data(#"{"type":"command","id":"req-1","payload":{"command":"set_volume","value":0.42}}"#.utf8)
        let envelope = try LocalNetworkProtocolParser.parseEnvelope(data)

        XCTAssertEqual(envelope.type, "command")
        XCTAssertEqual(envelope.id, "req-1")
        XCTAssertEqual(try LocalNetworkProtocolParser.parseCommand(payload: envelope.payload), .setVolume(0.42))
    }

    func testProtocolParserSupportsPresetByIDOrName() throws {
        XCTAssertEqual(
            try LocalNetworkProtocolParser.parseCommand(payload: ["command": "select_preset", "presetID": "built-in-flat"]),
            .selectPreset(id: "built-in-flat", name: nil)
        )
        XCTAssertEqual(
            try LocalNetworkProtocolParser.parseCommand(payload: ["command": "preset", "presetName": "Voice Boost"]),
            .selectPreset(id: nil, name: "Voice Boost")
        )
    }

    func testProtocolParserAcceptsAuthAndPairPayloads() throws {
        let auth = try LocalNetworkProtocolParser.parseAuth(payload: ["clientId": "client-1", "token": "secret"])
        XCTAssertEqual(auth.clientID, "client-1")
        XCTAssertEqual(auth.token, "secret")

        let pair = try LocalNetworkProtocolParser.parsePair(payload: ["pairingCode": "123456", "clientName": "iPhone"])
        XCTAssertEqual(pair.code, "123456")
        XCTAssertEqual(pair.clientName, "iPhone")
    }

    @MainActor
    func testAuthStorePairsPersistsAuthenticatesAndRevokesClients() throws {
        let url = temporaryAuthURL()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = LocalNetworkAuthStore(persistenceURL: url, now: { now })
        let session = store.beginPairing()

        let credential = try store.pair(code: session.code, clientName: "Living Room Phone")

        XCTAssertNil(store.pairingSession)
        XCTAssertEqual(store.clients.map(\.name), ["Living Room Phone"])
        XCTAssertEqual(store.authenticate(clientID: credential.clientID, token: "wrong"), nil)
        XCTAssertNotNil(store.authenticate(clientID: credential.clientID, token: credential.token))

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(persisted.contains(credential.token))
        XCTAssertFalse(persisted.contains(session.code))

        now = Date(timeIntervalSinceReferenceDate: 200)
        let reloaded = LocalNetworkAuthStore(persistenceURL: url, now: { now })
        XCTAssertNotNil(reloaded.authenticate(clientID: credential.clientID, token: credential.token))

        reloaded.revoke(clientID: credential.clientID)
        XCTAssertNil(reloaded.authenticate(clientID: credential.clientID, token: credential.token))
    }

    @MainActor
    func testAuthStoreExpiresPairingAndResetClearsClients() throws {
        let url = temporaryAuthURL()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = LocalNetworkAuthStore(persistenceURL: url, now: { now })
        let session = store.beginPairing()
        now = session.expiresAt.addingTimeInterval(1)

        XCTAssertThrowsError(try store.pair(code: session.code, clientName: "Old Phone"))
        XCTAssertNil(store.pairingSession)

        let fresh = store.beginPairing()
        let credential = try store.pair(code: fresh.code, clientName: "Phone")
        XCTAssertNotNil(store.authenticate(clientID: credential.clientID, token: credential.token))

        _ = store.beginPairing()
        store.reset()
        XCTAssertTrue(store.clients.isEmpty)
        XCTAssertNil(store.pairingSession)
        XCTAssertNil(store.authenticate(clientID: credential.clientID, token: credential.token))
    }

    func testProtocolParserRejectsInvalidEnvelope() {
        XCTAssertThrowsError(try LocalNetworkProtocolParser.parseEnvelope(Data(#"{"payload":{}}"#.utf8)))
    }

    func testWebSocketFrameCodecDecodesMaskedClientTextFrame() throws {
        let payload = [UInt8]("hello".utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        let maskedPayload = payload.enumerated().map { index, byte in byte ^ mask[index % 4] }
        var frame = Data([0x81, 0x80 | UInt8(payload.count)])
        frame.append(contentsOf: mask)
        frame.append(contentsOf: maskedPayload)

        let frames = try LocalNetworkWebSocketFrameCodec.decodeFrames(frame)

        XCTAssertEqual(frames, [LocalNetworkWebSocketFrame(opcode: .text, payload: Data(payload))])
    }

    func testWebSocketFrameCodecEncodesServerTextFrame() throws {
        let payload = Data("ok".utf8)
        let frame = LocalNetworkWebSocketFrameCodec.encodeFrame(opcode: .text, payload: payload)

        XCTAssertEqual([UInt8](frame), [0x81, 0x02, 0x6f, 0x6b])
    }

    private func temporaryAuthURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("local-network-auth.json")
    }
}
