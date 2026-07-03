//
//  LocalNetworkControlServer.swift
//  EqualEase
//

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import SystemConfiguration

@MainActor
final class LocalNetworkControlServer: NSObject, ObservableObject {
    @Published private(set) var state: LocalNetworkServerState = .stopped

    private let configuration: LocalNetworkServerConfiguration
    private let bridge: LocalNetworkControlBridge
    let authStore: LocalNetworkAuthStore
    private let queue = DispatchQueue(label: "boutique.code.EqualEase.local-network")
    private let instanceID = UUID().uuidString
    private var listener: NWListener?
    private var pendingHTTPConnections: [UUID: LocalNetworkPendingHTTPConnection] = [:]
    private var clients: [UUID: LocalNetworkWebSocketClient] = [:]
    private var heartbeatTimer: Timer?

    convenience init(bridge: LocalNetworkControlBridge) {
        self.init(configuration: LocalNetworkServerConfiguration(), bridge: bridge, authStore: LocalNetworkAuthStore())
    }

    init(configuration: LocalNetworkServerConfiguration, bridge: LocalNetworkControlBridge, authStore: LocalNetworkAuthStore) {
        self.configuration = configuration
        self.bridge = bridge
        self.authStore = authStore
    }

    var info: LocalNetworkServerInfo {
        LocalNetworkServerInfo(
            appName: "EqualEase",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            protocolVersion: configuration.protocolVersion,
            webSocketPath: configuration.webSocketPath,
            port: configuration.port,
            instanceID: instanceID
        )
    }

    func start() {
        guard listener == nil else { return }
        state = .starting

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: configuration.port) ?? 8787
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor in
                    self?.handle(listenerState)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("EqualEase local network: failed to start: %@", error.localizedDescription)
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        clients.values.forEach { $0.close() }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    func broadcastStatePatch() {
        guard case .running = state, !clients.isEmpty else { return }
        let snapshot = bridge.snapshot()
        broadcast(type: "state_patch", payload: snapshot)
    }

    private func accept(_ connection: NWConnection) {
        let pending = LocalNetworkPendingHTTPConnection(connection: connection, server: self)
        pendingHTTPConnections[pending.id] = pending
        connection.stateUpdateHandler = { [weak pending] connectionState in
            Task { @MainActor in
                switch connectionState {
                case .ready:
                    pending?.receiveRequest()
                case .failed, .cancelled:
                    pending?.finish()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func handle(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            startHeartbeat()
            let lanURLs = Self.lanIPAddresses().map { "http://\($0):\(configuration.port)" }
            state = .running(port: configuration.port, lanURLs: lanURLs)
            let httpURLs = lanURLs.isEmpty ? ["http://<mac-lan-ip>:\(configuration.port)"] : lanURLs
            let wsURLs = httpURLs.map { $0.replacingOccurrences(of: "http://", with: "ws://") + configuration.webSocketPath }
            NSLog("EqualEase local network remote HTTP: %@", httpURLs.joined(separator: ", "))
            NSLog("EqualEase local network remote WebSocket: %@", wsURLs.joined(separator: ", "))
        case let .failed(error):
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            clients.values.forEach { $0.close() }
            clients.removeAll()
            listener = nil
            state = .failed(error.localizedDescription)
            NSLog("EqualEase local network: listener failed: %@", error.localizedDescription)
        case .cancelled:
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            clients.values.forEach { $0.close() }
            clients.removeAll()
            listener = nil
            state = .stopped
        default:
            break
        }
    }

    fileprivate func finishPendingConnection(id: UUID) {
        pendingHTTPConnections.removeValue(forKey: id)
    }

    fileprivate func handle(request: LocalNetworkHTTPRequest, on connection: NWConnection) {
        if request.path == configuration.webSocketPath, request.isWebSocketUpgrade {
            upgrade(request: request, on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let health = LocalNetworkHealth(status: "ok", app: "EqualEase", protocolVersion: configuration.protocolVersion)
            sendJSON(health, status: "200 OK", on: connection, closeAfterSend: true)
        case ("GET", "/info"):
            sendJSON(info, status: "200 OK", on: connection, closeAfterSend: true)
        case ("GET", "/favicon.png"), ("GET", "/favicon.ico"):
            sendIconPNG(size: 32, on: connection)
        case ("GET", "/apple-touch-icon.png"):
            sendAppleTouchIconPNG(on: connection)
        case ("GET", "/"), ("GET", "/remote"):
            sendHTML(Self.remoteHTML(webSocketPath: configuration.webSocketPath), on: connection)
        default:
            let error = LocalNetworkProtocolError(code: "not_found", message: "Endpoint not found.")
            sendJSON(error, status: "404 Not Found", on: connection, closeAfterSend: true)
        }
    }

    private func upgrade(request: LocalNetworkHTTPRequest, on connection: NWConnection) {
        guard let key = request.headers["sec-websocket-key"] else {
            sendHTTP(status: "400 Bad Request", contentType: "text/plain", body: Data("Missing Sec-WebSocket-Key".utf8), on: connection, closeAfterSend: true)
            return
        }

        let accept = Self.webSocketAcceptValue(for: key)
        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard error == nil, let self else { return }
                self.installWebSocket(connection)
            }
        })
    }

    private func installWebSocket(_ connection: NWConnection) {
        let client = LocalNetworkWebSocketClient(connection: connection, server: self)
        clients[client.id] = client
        client.send(
            type: "auth_required",
            id: nil,
            payload: LocalNetworkAuthRequired(
                message: String(localized: "Pair or authenticate before using remote control.", comment: "Remote-control message shown before the phone has paired or authenticated."),
                protocolVersion: configuration.protocolVersion
            )
        )
        client.receiveNextFrame()
    }

    fileprivate func removeClient(id: UUID) {
        clients[id]?.close()
        clients.removeValue(forKey: id)
    }

    fileprivate func handleWebSocketText(_ text: String, from client: LocalNetworkWebSocketClient) {
        guard let data = text.data(using: .utf8) else {
            client.sendError(code: "invalid_text", message: String(localized: "WebSocket messages must be UTF-8 JSON.", comment: "Remote-control protocol error for non-JSON WebSocket text."), id: nil)
            return
        }

        do {
            let envelope = try LocalNetworkProtocolParser.parseEnvelope(data)
            switch envelope.type {
            case "ping":
                client.markAlive()
                client.send(type: "pong", id: envelope.id, payload: ["ok": true])
            case "auth":
                let auth = try LocalNetworkProtocolParser.parseAuth(payload: envelope.payload)
                guard let pairedClient = authStore.authenticate(clientID: auth.clientID, token: auth.token) else {
                    client.clearAuthentication()
                    client.sendAuthError(code: "invalid_credentials", message: String(localized: "Remote credentials were not recognized. Pair this device again from EqualEase Settings.", comment: "Remote-control authentication error when stored phone credentials are invalid or revoked."), id: envelope.id)
                    return
                }
                client.markAuthenticated(clientID: pairedClient.id)
                client.send(type: "auth_ok", id: envelope.id, payload: LocalNetworkAuthOK(clientID: pairedClient.id, clientName: pairedClient.name, token: nil))
                client.send(type: "state_snapshot", id: nil, payload: bridge.snapshot())
            case "pair":
                let pair = try LocalNetworkProtocolParser.parsePair(payload: envelope.payload)
                do {
                    let credential = try authStore.pair(code: pair.code, clientName: pair.clientName)
                    client.markAuthenticated(clientID: credential.clientID)
                    client.send(type: "auth_ok", id: envelope.id, payload: LocalNetworkAuthOK(clientID: credential.clientID, clientName: credential.clientName, token: credential.token))
                    client.send(type: "state_snapshot", id: nil, payload: bridge.snapshot())
                } catch LocalNetworkAuthStore.AuthError.pairingUnavailable {
                    client.sendAuthError(code: "pairing_unavailable", message: String(localized: "Pairing is not active. Start pairing from EqualEase Settings.", comment: "Local-network remote pairing error when no temporary pairing session exists."), id: envelope.id)
                } catch LocalNetworkAuthStore.AuthError.pairingRateLimited {
                    client.sendAuthError(code: "pairing_rate_limited", message: String(localized: "Too many pairing attempts. Wait a few minutes before trying again.", comment: "Local-network remote pairing error after too many failed six-digit code attempts."), id: envelope.id)
                } catch LocalNetworkAuthStore.AuthError.invalidPairingCode {
                    client.sendAuthError(code: "invalid_pairing_code", message: String(localized: "The pairing code is invalid or expired.", comment: "Local-network remote pairing error for a wrong or expired six-digit code."), id: envelope.id)
                }
            case "get_state":
                guard requireAuthentication(for: client, id: envelope.id) else { return }
                client.send(type: "state_snapshot", id: envelope.id, payload: bridge.snapshot())
            case "subscribe":
                guard requireAuthentication(for: client, id: envelope.id) else { return }
                client.isSubscribed = true
                client.send(type: "state_snapshot", id: envelope.id, payload: bridge.snapshot())
            case "unsubscribe":
                guard requireAuthentication(for: client, id: envelope.id) else { return }
                client.isSubscribed = false
                client.send(type: "command_result", id: envelope.id, payload: LocalNetworkCommandResult(ok: true, message: "unsubscribed", stateVersion: nil))
            case "command":
                guard requireAuthentication(for: client, id: envelope.id) else { return }
                let command = try LocalNetworkProtocolParser.parseCommand(payload: envelope.payload)
                let state = try bridge.handle(command)
                client.send(type: "command_result", id: envelope.id, payload: LocalNetworkCommandResult(ok: true, message: "ok", stateVersion: state.stateVersion))
                broadcast(type: "state_patch", payload: state)
            default:
                client.sendError(code: "unsupported_type", message: String(localized: "Unsupported message type: \(envelope.type)", comment: "Remote-control protocol error. Interpolation is the unsupported WebSocket message type."), id: envelope.id)
            }
        } catch {
            client.sendError(code: "protocol_error", message: error.localizedDescription, id: nil)
        }
    }

    private func requireAuthentication(for client: LocalNetworkWebSocketClient, id: String?) -> Bool {
        guard client.isAuthenticated, authStore.containsClient(id: client.authenticatedClientID) else {
            client.clearAuthentication()
            client.sendAuthError(code: "authentication_required", message: String(localized: "Pair or authenticate before using remote control.", comment: "Remote-control message shown before the phone has paired or authenticated."), id: id)
            return false
        }
        return true
    }

    private func broadcast<Payload: Encodable>(type: String, payload: Payload) {
        for client in clients.values where client.isSubscribed && client.isAuthenticated && authStore.containsClient(id: client.authenticatedClientID) {
            client.send(type: type, id: nil, payload: payload)
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHeartbeat()
            }
        }
    }

    private func runHeartbeat() {
        let now = Date()
        for client in clients.values {
            if now.timeIntervalSince(client.lastSeen) > 45 {
                removeClient(id: client.id)
            } else {
                client.send(type: "event", id: nil, payload: ["name": "heartbeat", "serverTime": ISO8601DateFormatter().string(from: now)])
            }
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, status: String, on connection: NWConnection, closeAfterSend: Bool) {
        do {
            try sendHTTP(status: status, contentType: "application/json; charset=utf-8", body: value.localNetworkJSONData(), on: connection, closeAfterSend: closeAfterSend)
        } catch {
            sendHTTP(status: "500 Internal Server Error", contentType: "text/plain", body: Data(error.localizedDescription.utf8), on: connection, closeAfterSend: true)
        }
    }

    private func sendHTML(_ html: String, on connection: NWConnection) {
        sendHTTP(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), on: connection, closeAfterSend: true)
    }

    private func sendIconPNG(size: Int, on connection: NWConnection) {
        guard let data = Self.remoteIconPNG(size: size) else {
            sendHTTP(status: "500 Internal Server Error", contentType: "text/plain", body: Data("Unable to render icon.".utf8), on: connection, closeAfterSend: true)
            return
        }
        sendHTTP(status: "200 OK", contentType: "image/png", body: data, on: connection, closeAfterSend: true)
    }

    private func sendAppleTouchIconPNG(on connection: NWConnection) {
        guard let data = Self.remoteAppleTouchIconPNG(size: 180) else {
            sendHTTP(status: "500 Internal Server Error", contentType: "text/plain", body: Data("Unable to render icon.".utf8), on: connection, closeAfterSend: true)
            return
        }
        sendHTTP(status: "200 OK", contentType: "image/png", body: data, on: connection, closeAfterSend: true)
    }

    private func sendHTTP(status: String, contentType: String, body: Data, on connection: NWConnection, closeAfterSend: Bool) {
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            if closeAfterSend {
                connection.cancel()
            }
        })
    }

    static func webSocketAcceptValue(for key: String) -> String {
        let magic = key.trimmingCharacters(in: .whitespacesAndNewlines) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    static func lanIPAddresses() -> [String] {
        guard let address = primaryLANIPAddress() else { return [] }
        return [address]
    }

    static func primaryLANIPAddress() -> String? {
        let candidates = lanIPv4AddressCandidates()
        if let primaryInterfaceName = primaryIPv4InterfaceName(),
           let primary = candidates.first(where: { $0.interfaceName == primaryInterfaceName }) {
            return primary.address
        }
        return candidates.first?.address
    }

    static func isUsableLANIPv4Address(_ address: String) -> Bool {
        var ipv4Address = in_addr()
        guard inet_pton(AF_INET, address, &ipv4Address) == 1 else { return false }

        let value = UInt32(bigEndian: ipv4Address.s_addr)
        let firstOctet = UInt8((value >> 24) & 0xff)
        let secondOctet = UInt8((value >> 16) & 0xff)

        guard value != 0 else { return false }
        guard firstOctet != 127 else { return false }
        guard !(firstOctet == 169 && secondOctet == 254) else { return false }
        guard firstOctet < 224 else { return false }
        guard value != UInt32.max else { return false }

        return true
    }

    static func isPhoneReachableInterfaceName(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("en")
    }

    private static func primaryIPv4InterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "EqualEase" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interfaceName = value["PrimaryInterface"] as? String,
              !interfaceName.isEmpty
        else { return nil }
        return interfaceName
    }

    private static func lanIPv4AddressCandidates() -> [(interfaceName: String, address: String)] {
        var addresses: [(interfaceName: String, address: String)] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0
            else { continue }

            let interfaceName = String(cString: interface.ifa_name)
            guard isPhoneReachableInterfaceName(interfaceName) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: hostname)
            guard isUsableLANIPv4Address(address) else { continue }
            addresses.append((interfaceName: interfaceName, address: address))
        }

        return addresses.sorted { lhs, rhs in
            if lhs.interfaceName == rhs.interfaceName { return lhs.address < rhs.address }
            return lhs.interfaceName.localizedStandardCompare(rhs.interfaceName) == .orderedAscending
        }
    }
}

private struct LocalNetworkHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.localizedLowercase == "websocket"
    }

    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n")
        else { return nil }
        let headerText = String(text[..<headerEnd.lowerBound])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }
        method = requestParts[0]
        path = URLComponents(string: requestParts[1])?.path ?? requestParts[1]
        headers = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
    }
}

@MainActor
private final class LocalNetworkPendingHTTPConnection {
    let id = UUID()

    private let connection: NWConnection
    private weak var server: LocalNetworkControlServer?
    private var buffer = Data()

    init(connection: NWConnection, server: LocalNetworkControlServer) {
        self.connection = connection
        self.server = server
    }

    func finish() {
        server?.finishPendingConnection(id: id)
    }

    func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let error {
                    NSLog("EqualEase local network: request receive failed: %@", error.localizedDescription)
                    self.finish()
                    self.connection.cancel()
                    return
                }
                if let request = LocalNetworkHTTPRequest(data: self.buffer) {
                    self.finish()
                    self.server?.handle(request: request, on: self.connection)
                } else if isComplete || self.buffer.count > 16_384 {
                    self.finish()
                    self.connection.cancel()
                } else {
                    self.receiveRequest()
                }
            }
        }
    }
}

@MainActor
private final class LocalNetworkWebSocketClient {
    let id = UUID()
    var isSubscribed = false
    private(set) var lastSeen = Date()
    private(set) var authenticatedClientID: String?

    var isAuthenticated: Bool {
        authenticatedClientID != nil
    }

    private let connection: NWConnection
    private weak var server: LocalNetworkControlServer?

    init(connection: NWConnection, server: LocalNetworkControlServer) {
        self.connection = connection
        self.server = server
    }

    func markAlive() {
        lastSeen = Date()
    }

    func markAuthenticated(clientID: String) {
        authenticatedClientID = clientID
        isSubscribed = true
        markAlive()
    }

    func clearAuthentication() {
        authenticatedClientID = nil
        isSubscribed = false
    }

    func receiveNextFrame() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.markAlive()
                    do {
                        for frame in try LocalNetworkWebSocketFrameCodec.decodeFrames(data) {
                            switch frame.opcode {
                            case .text:
                                if let text = String(data: frame.payload, encoding: .utf8) {
                                    self.server?.handleWebSocketText(text, from: self)
                                } else {
                                    self.sendError(code: "invalid_utf8", message: "Text frames must be UTF-8 JSON.", id: nil)
                                }
                            case .close:
                                self.server?.removeClient(id: self.id)
                                return
                            case .ping:
                                self.sendFrame(opcode: .pong, payload: frame.payload)
                            case .pong:
                                self.markAlive()
                            case .binary:
                                break
                            }
                        }
                    } catch {
                        self.sendError(code: "frame_error", message: error.localizedDescription, id: nil)
                    }
                }
                if isComplete || error != nil {
                    self.server?.removeClient(id: self.id)
                } else {
                    self.receiveNextFrame()
                }
            }
        }
    }

    func send<Payload: Encodable>(type: String, id: String?, payload: Payload) {
        do {
            let envelope = LocalNetworkOutboundEnvelope(type: type, id: id, payload: payload)
            sendFrame(opcode: .text, payload: try envelope.localNetworkJSONData())
        } catch {
            NSLog("EqualEase local network: failed to encode %@: %@", type, error.localizedDescription)
        }
    }

    func sendError(code: String, message: String, id: String?) {
        send(type: "error", id: id, payload: LocalNetworkProtocolError(code: code, message: message))
    }

    func sendAuthError(code: String, message: String, id: String?) {
        send(type: "auth_error", id: id, payload: LocalNetworkProtocolError(code: code, message: message))
    }

    func close() {
        sendFrame(opcode: .close, payload: Data())
        connection.cancel()
    }

    private func sendFrame(opcode: LocalNetworkWebSocketOpcode, payload: Data) {
        let data = LocalNetworkWebSocketFrameCodec.encodeFrame(opcode: opcode, payload: payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

enum LocalNetworkWebSocketOpcode: UInt8 {
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct LocalNetworkWebSocketFrame: Equatable {
    var opcode: LocalNetworkWebSocketOpcode
    var payload: Data
}

enum LocalNetworkWebSocketFrameCodec {
    static func encodeFrame(opcode: LocalNetworkWebSocketOpcode, payload: Data) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= UInt16.max {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(payload)
        return frame
    }

    static func decodeFrames(_ data: Data) throws -> [LocalNetworkWebSocketFrame] {
        var offset = 0
        var frames: [LocalNetworkWebSocketFrame] = []
        let bytes = [UInt8](data)

        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw CodecError.incompleteFrame }
            let first = bytes[offset]
            let second = bytes[offset + 1]
            offset += 2

            let opcodeValue = first & 0x0f
            guard let opcode = LocalNetworkWebSocketOpcode(rawValue: opcodeValue) else { throw CodecError.unsupportedOpcode(opcodeValue) }
            let masked = (second & 0x80) != 0
            var length = Int(second & 0x7f)

            if length == 126 {
                guard bytes.count - offset >= 2 else { throw CodecError.incompleteFrame }
                length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
            } else if length == 127 {
                guard bytes.count - offset >= 8 else { throw CodecError.incompleteFrame }
                var longLength: UInt64 = 0
                for _ in 0..<8 {
                    longLength = (longLength << 8) | UInt64(bytes[offset])
                    offset += 1
                }
                guard longLength <= UInt64(Int.max) else { throw CodecError.frameTooLarge }
                length = Int(longLength)
            }

            var mask: [UInt8] = []
            if masked {
                guard bytes.count - offset >= 4 else { throw CodecError.incompleteFrame }
                mask = Array(bytes[offset..<(offset + 4)])
                offset += 4
            }

            guard bytes.count - offset >= length else { throw CodecError.incompleteFrame }
            var payload = Array(bytes[offset..<(offset + length)])
            offset += length

            if masked {
                for index in payload.indices {
                    payload[index] ^= mask[index % 4]
                }
            }
            frames.append(LocalNetworkWebSocketFrame(opcode: opcode, payload: Data(payload)))
        }

        return frames
    }

    enum CodecError: LocalizedError, Equatable {
        case incompleteFrame
        case unsupportedOpcode(UInt8)
        case frameTooLarge

        var errorDescription: String? {
            switch self {
            case .incompleteFrame:
                "Incomplete WebSocket frame."
            case let .unsupportedOpcode(opcode):
                "Unsupported WebSocket opcode: \(opcode)"
            case .frameTooLarge:
                "WebSocket frame is too large."
            }
        }
    }
}

extension LocalNetworkControlServer {
    private static let remoteIconBackgroundColor = NSColor(deviceRed: 249.0 / 255.0, green: 115.0 / 255.0, blue: 22.0 / 255.0, alpha: 1)

    static func remoteAppleTouchIconPNG(size: Int, source: NSImage? = nil) -> Data? {
        remoteIconPNG(size: size, source: source, backgroundColor: remoteIconBackgroundColor)
    }

    static func remoteIconPNG(size: Int, source: NSImage? = nil, backgroundColor: NSColor? = nil) -> Data? {
        guard let image = source ?? NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage else { return nil }

        let side = max(size, 1)
        let targetSize = NSSize(width: side, height: side)
        let targetRect = NSRect(origin: .zero, size: targetSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        (backgroundColor ?? .clear).setFill()
        targetRect.fill()
        image.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func javaScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

    static func remoteHTML(webSocketPath: String) -> String {
        let languageCode = htmlEscaped(Locale.current.language.languageCode?.identifier ?? "en")
        let title = htmlEscaped(String(localized: "EqualEase Remote", comment: "Browser title for the paired phone web remote."))
        let connecting = htmlEscaped(String(localized: "Connecting…", comment: "Phone web remote connection status before WebSocket connects."))
        let pairRemoteLabel = htmlEscaped(String(localized: "Pair remote", comment: "Accessibility label for the phone web remote pairing section."))
        let pairingInstructions = htmlEscaped(String(localized: "Start pairing in EqualEase Settings > General > Local Network Remote, then enter the six-digit code shown on your Mac.", comment: "Phone web remote pairing instructions. The code is displayed in the Mac Settings window."))
        let remoteNamePlaceholder = htmlEscaped(String(localized: "Remote name", comment: "Placeholder for naming a paired phone remote."))
        let phoneRemoteName = htmlEscaped(String(localized: "Phone Remote", comment: "Default display name for a newly paired local-network remote client."))
        let pairButtonTitle = htmlEscaped(String(localized: "Pair Remote", comment: "Button title for submitting the six-digit phone remote pairing code."))
        let volumeLabel = htmlEscaped(String(localized: "Remote control label: Volume", defaultValue: "Volume", comment: "Phone web remote card label for Mac output volume."))
        let preampLabel = htmlEscaped(String(localized: "Remote control label: Preamp", defaultValue: "Preamp", comment: "Phone web remote card label for EqualEase preamp/output gain."))
        let presetsLabel = htmlEscaped(String(localized: "Remote control label: Presets", defaultValue: "Presets", comment: "Phone web remote preset button section accessibility label."))
        let footer = htmlEscaped(String(localized: "Paired access protects remote control on your trusted local network. Traffic stays local but is not internet-grade encrypted.", comment: "Phone web remote footer explaining same-LAN pairing security."))
        let connectedAuthenticating = javaScriptEscaped(String(localized: "Connected — authenticating…", comment: "Phone web remote status after WebSocket connects while auth is pending."))
        let enterCode = javaScriptEscaped(String(localized: "Enter the code from your Mac to pair this remote.", comment: "Phone web remote prompt shown when pairing is required."))
        let disconnectedRetrying = javaScriptEscaped(String(localized: "Disconnected — retrying…", comment: "Phone web remote status while reconnecting after WebSocket close."))
        let connectionError = javaScriptEscaped(String(localized: "Connection error", comment: "Phone web remote status when WebSocket reports an error."))
        let pairedAs = javaScriptEscaped(String(localized: "Paired as", comment: "Phone web remote status prefix before the paired client name."))
        let pairingFailed = javaScriptEscaped(String(localized: "Pairing or authentication failed.", comment: "Phone web remote fallback error when pairing/authentication fails without a specific message."))
        let pairingRequired = javaScriptEscaped(String(localized: "Pairing required", comment: "Phone web remote status when the client must pair again."))
        let protocolError = javaScriptEscaped(String(localized: "Protocol error", comment: "Phone web remote fallback status when the server returns a protocol error without a message."))
        let pairBeforeChanging = javaScriptEscaped(String(localized: "Pair this remote before changing EqualEase.", comment: "Phone web remote prompt when an unauthenticated client tries to change Volume, Preamp, or Preset."))
        let activeStatus = javaScriptEscaped(String(localized: "Remote routing status: Active", defaultValue: "Active", comment: "Phone web remote routing status when EqualEase is active."))
        let offStatus = javaScriptEscaped(String(localized: "Remote routing status: Off", defaultValue: "Off", comment: "Phone web remote routing status when EqualEase is off."))
        let sixDigitCodePrompt = javaScriptEscaped(String(localized: "Enter the six-digit code shown on your Mac.", comment: "Phone web remote validation message for an incomplete pairing code."))
        let phoneRemoteNameJS = javaScriptEscaped(String(localized: "Phone Remote", comment: "Default display name for a newly paired local-network remote client."))

        return """
        <!doctype html>
        <html lang="\(languageCode)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="apple-mobile-web-app-title" content="\(title)">
          <meta name="theme-color" content="#f97316">
          <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
          <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; background: #15120f; color: #fff7ed; }
            * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
            html, body { margin: 0; min-height: 100%; overscroll-behavior: none; touch-action: manipulation; }
            body { display: grid; place-items: stretch; padding: max(14px, env(safe-area-inset-top)) 14px max(14px, env(safe-area-inset-bottom)); }
            main { max-width: 460px; width: 100%; margin: 0 auto; min-height: calc(100vh - 28px); display: grid; grid-template-rows: auto auto auto 1fr auto; gap: 14px; }
            header { background: linear-gradient(135deg, #f97316, #ff9f1c); color: #211006; border-radius: 28px; padding: 18px; box-shadow: 0 18px 45px rgba(0,0,0,.35); }
            h1 { margin: 0; font-size: 28px; letter-spacing: -.04em; }
            #status { margin-top: 6px; font-weight: 700; opacity: .78; }
            .pairing { background: #241d18; border: 1px solid rgba(255,255,255,.1); border-radius: 24px; padding: 16px; display: grid; gap: 10px; }
            .pairing.hidden, .controls.hidden, #presets.hidden { display: none; }
            .pairing p { margin: 0; color: rgba(255,247,237,.72); line-height: 1.35; }
            .pairing input { width: 100%; border: 1px solid rgba(255,255,255,.14); border-radius: 16px; background: #15120f; color: #fff7ed; padding: 14px; font-size: 18px; font-weight: 800; }
            #pairingCode { text-align: center; letter-spacing: .22em; font-size: 28px; font-variant-numeric: tabular-nums; }
            .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
            .card { background: #241d18; border: 1px solid rgba(255,255,255,.08); border-radius: 24px; padding: 16px; box-shadow: inset 0 1px rgba(255,255,255,.06); touch-action: none; user-select: none; cursor: ew-resize; }
            .label { color: #ffcc99; font-size: 12px; font-weight: 800; text-transform: uppercase; letter-spacing: .08em; }
            .value { font-size: 34px; font-weight: 900; letter-spacing: -.05em; margin: 4px 0 12px; }
            input[type=range] { width: 100%; height: 44px; touch-action: none; accent-color: #fb923c; }
            #presets { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; align-content: start; overflow: hidden; }
            button { border: 0; border-radius: 22px; padding: 18px 12px; min-height: 64px; background: #2d251f; color: #fff7ed; font-size: 17px; font-weight: 800; touch-action: manipulation; }
            button.primary { background: #f97316; color: #211006; box-shadow: 0 12px 28px rgba(249,115,22,.28); }
            button.active { background: #f97316; color: #211006; box-shadow: 0 12px 28px rgba(249,115,22,.28); }
            footer { color: rgba(255,247,237,.62); font-size: 12px; text-align: center; }
          </style>
        </head>
        <body>
          <main>
            <header><h1>EqualEase</h1><div id="status">\(connecting)</div></header>
            <section id="pairing" class="pairing hidden" aria-label="\(pairRemoteLabel)">
              <p>\(pairingInstructions)</p>
              <input id="clientName" autocomplete="off" placeholder="\(remoteNamePlaceholder)" value="\(phoneRemoteName)">
              <input id="pairingCode" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="one-time-code" placeholder="••••••">
              <button id="pairButton" class="primary" type="button">\(pairButtonTitle)</button>
              <p id="authMessage"></p>
            </section>
            <section id="controls" class="cards controls hidden">
              <div id="volumeCard" class="card"><div class="label">\(volumeLabel)</div><div class="value"><span id="volumeValue">--</span>%</div><input id="volume" type="range" min="0" max="100" value="100"></div>
              <div id="preampCard" class="card"><div class="label">\(preampLabel)</div><div class="value"><span id="preampValue">--</span>%</div><input id="preamp" type="range" min="0" max="200" value="100"></div>
            </section>
            <section id="presets" class="hidden" aria-label="\(presetsLabel)"></section>
            <footer>\(footer)</footer>
          </main>
          <script>
            const STORAGE_KEY = 'equalEaseRemoteCredentialV1';
            const statusEl = document.getElementById('status');
            const presetsEl = document.getElementById('presets');
            const pairingEl = document.getElementById('pairing');
            const controlsEl = document.getElementById('controls');
            const authMessage = document.getElementById('authMessage');
            const pairingCode = document.getElementById('pairingCode');
            const clientName = document.getElementById('clientName');
            const pairButton = document.getElementById('pairButton');
            const volume = document.getElementById('volume');
            const preamp = document.getElementById('preamp');
            const volumeValue = document.getElementById('volumeValue');
            const preampValue = document.getElementById('preampValue');
            let ws, state, authenticated = false;
            let recentPresetPresses = new Map();
            function loadCredential() {
              try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null'); } catch { return null; }
            }
            function saveCredential(credential) { localStorage.setItem(STORAGE_KEY, JSON.stringify(credential)); }
            function clearCredential() { localStorage.removeItem(STORAGE_KEY); }
            function showPairing(message = '') {
              authenticated = false;
              pairingEl.classList.remove('hidden');
              controlsEl.classList.add('hidden');
              presetsEl.classList.add('hidden');
              authMessage.textContent = message;
            }
            function showControls() {
              authenticated = true;
              pairingEl.classList.add('hidden');
              controlsEl.classList.remove('hidden');
              presetsEl.classList.remove('hidden');
            }
            function connect() {
              const url = `ws://${location.host}${'\(webSocketPath)'}`;
              ws = new WebSocket(url);
              ws.onopen = () => {
                statusEl.textContent = '\(connectedAuthenticating)';
                const credential = loadCredential();
                if (credential && credential.clientID && credential.token) {
                  send('auth', { clientID: credential.clientID, token: credential.token }, 'auth');
                } else {
                  showPairing('\(enterCode)');
                }
              };
              ws.onclose = () => { statusEl.textContent = '\(disconnectedRetrying)'; setTimeout(connect, 1200); };
              ws.onerror = () => { statusEl.textContent = '\(connectionError)'; };
              ws.onmessage = event => {
                const message = JSON.parse(event.data);
                if (message.type === 'auth_required') showPairing('\(enterCode)');
                if (message.type === 'auth_ok') {
                  if (message.payload.token) saveCredential({ clientID: message.payload.clientID, clientName: message.payload.clientName, token: message.payload.token });
                  showControls();
                  statusEl.textContent = `\(pairedAs) ${message.payload.clientName}`;
                }
                if (message.type === 'auth_error') {
                  if (message.payload.code === 'invalid_credentials') clearCredential();
                  showPairing(message.payload.message || '\(pairingFailed)');
                  statusEl.textContent = '\(pairingRequired)';
                }
                if (message.type === 'state_snapshot' || message.type === 'state_patch') render(message.payload);
                if (message.type === 'error') statusEl.textContent = message.payload.message || '\(protocolError)';
              };
            }
            function requestId() {
              if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') return globalThis.crypto.randomUUID();
              return `req-${Date.now()}-${Math.random().toString(16).slice(2)}`;
            }
            function send(type, payload = {}, id = requestId()) {
              if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type, id, payload }));
            }
            function command(payload) {
              if (!authenticated) { showPairing('\(pairBeforeChanging)'); return; }
              send('command', payload);
            }
            function pressPreset(event, preset) {
              event.preventDefault();
              const now = Date.now();
              const lastPress = recentPresetPresses.get(preset.id) || 0;
              if (now - lastPress < 250) return;
              recentPresetPresses.set(preset.id, now);
              command({ command: 'select_preset', presetID: preset.id });
            }
            function render(next) {
              state = next;
              showControls();
              statusEl.textContent = `${next.activePresetName} • ${next.isActive ? '\(activeStatus)' : '\(offStatus)'}`;
              volume.value = Math.round(next.outputVolume * 100); volumeValue.textContent = volume.value;
              preamp.value = Math.round(next.preamp * 100); preampValue.textContent = preamp.value;
              presetsEl.innerHTML = '';
              next.presets.slice(0, 12).forEach(preset => {
                const button = document.createElement('button');
                button.type = 'button';
                button.textContent = preset.name;
                button.className = preset.id === next.activePresetID ? 'active' : '';
                button.addEventListener('pointerup', event => pressPreset(event, preset));
                button.addEventListener('touchend', event => pressPreset(event, preset), { passive: false });
                button.addEventListener('click', event => pressPreset(event, preset));
                presetsEl.appendChild(button);
              });
            }
            function setControlFromCardPointer(event, control, valueElement, commandName, divisor) {
              const rect = event.currentTarget.getBoundingClientRect();
              const ratio = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
              const min = Number(control.min || 0);
              const max = Number(control.max || 100);
              control.value = Math.round(min + ratio * (max - min));
              valueElement.textContent = control.value;
              command({ command: commandName, value: Number(control.value) / divisor });
            }
            function bindCardSlider(cardId, control, valueElement, commandName, divisor) {
              const card = document.getElementById(cardId);
              card.addEventListener('pointerdown', event => {
                event.preventDefault();
                card.setPointerCapture(event.pointerId);
                setControlFromCardPointer(event, control, valueElement, commandName, divisor);
              });
              card.addEventListener('pointermove', event => {
                if (event.buttons !== 1) return;
                event.preventDefault();
                setControlFromCardPointer(event, control, valueElement, commandName, divisor);
              });
            }
            pairButton.addEventListener('click', () => {
              const code = pairingCode.value.replace(/\\D/g, '');
              if (code.length !== 6) { authMessage.textContent = '\(sixDigitCodePrompt)'; return; }
              send('pair', { code, clientName: clientName.value || '\(phoneRemoteNameJS)' }, 'pair');
            });
            for (const control of [volume, preamp]) {
              control.addEventListener('touchmove', event => event.preventDefault(), { passive: false });
            }
            bindCardSlider('volumeCard', volume, volumeValue, 'set_volume', 100);
            bindCardSlider('preampCard', preamp, preampValue, 'set_preamp', 100);
            volume.oninput = () => { volumeValue.textContent = volume.value; command({ command: 'set_volume', value: Number(volume.value) / 100 }); };
            preamp.oninput = () => { preampValue.textContent = preamp.value; command({ command: 'set_preamp', value: Number(preamp.value) / 100 }); };
            connect();
          </script>
        </body>
        </html>
        """
    }
}
