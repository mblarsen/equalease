//
//  LocalNetworkControlModels.swift
//  EqualEase
//

import Foundation

struct LocalNetworkServerConfiguration: Equatable {
    var port: UInt16 = 8787
    var webSocketPath = "/ws"
    var protocolVersion = 1
}

enum LocalNetworkServerState: Equatable {
    case stopped
    case starting
    case running(port: UInt16, lanURLs: [String])
    case failed(String)

    var statusText: String {
        switch self {
        case .stopped:
            String(localized: "Local-network remote status: Stopped", defaultValue: "Stopped", comment: "Local-network remote status when the server is not running.")
        case .starting:
            String(localized: "Starting local-network remote control…", comment: "Local-network remote status while the server starts.")
        case let .running(port, lanURLs):
            lanURLs.isEmpty
                ? String(
                    localized: "Running on port \(port)",
                    comment: "Local-network remote status when running but no LAN URL is known. Interpolation is the TCP port."
                )
                : String(
                    localized: "Running at \(lanURLs.joined(separator: ", "))",
                    comment: "Local-network remote status with one or more LAN URLs. Interpolation is a comma-separated list of URLs for pairing."
                )
        case let .failed(message):
            String(
                localized: "Failed: \(message)",
                comment: "Local-network remote status when startup failed. Interpolation is the underlying error message."
            )
        }
    }
}

struct LocalNetworkServerInfo: Codable, Equatable {
    var appName: String
    var appVersion: String
    var protocolVersion: Int
    var webSocketPath: String
    var port: UInt16
    var instanceID: String
}

struct LocalNetworkHealth: Codable, Equatable {
    var status: String
    var app: String
    var protocolVersion: Int
}

struct LocalNetworkRemotePreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var source: String
}

struct LocalNetworkRemoteState: Codable, Equatable {
    var stateVersion: Int
    var outputVolume: Double
    var preamp: Double
    var activePresetID: String?
    var activePresetName: String
    var presets: [LocalNetworkRemotePreset]
    var isActive: Bool
    var isRoutingTransitioning: Bool
    var routingStatus: String
}

struct LocalNetworkOutboundEnvelope<Payload: Encodable>: Encodable {
    var type: String
    var id: String?
    var payload: Payload
}

struct LocalNetworkCommandResult: Codable, Equatable {
    var ok: Bool
    var message: String
    var stateVersion: Int?
}

struct LocalNetworkProtocolError: Codable, Equatable {
    var code: String
    var message: String
}

struct LocalNetworkAuthRequired: Codable, Equatable {
    var message: String
    var protocolVersion: Int
}

struct LocalNetworkAuthOK: Codable, Equatable {
    var clientID: String
    var clientName: String
    var token: String?
}

enum LocalNetworkRemoteCommand: Equatable {
    case setVolume(Double)
    case setPreamp(Double)
    case selectPreset(id: String?, name: String?)
}

enum LocalNetworkProtocolParser {
    static func parseEnvelope(_ data: Data) throws -> (type: String, id: String?, payload: [String: Any]) {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ParserError.invalidEnvelope(String(localized: "Envelope must be a JSON object.", comment: "Remote-control protocol error for malformed WebSocket JSON."))
        }
        guard let type = dictionary["type"] as? String, !type.isEmpty else {
            throw ParserError.invalidEnvelope(String(localized: "Envelope is missing a supported type.", comment: "Remote-control protocol error for missing message type."))
        }
        let id = dictionary["id"] as? String
        let payload = dictionary["payload"] as? [String: Any] ?? [:]
        return (type, id, payload)
    }

    static func parseAuth(payload: [String: Any]) throws -> (clientID: String, token: String) {
        let clientID = payload["clientID"] as? String ?? payload["clientId"] as? String ?? payload["id"] as? String
        let token = payload["token"] as? String
        guard let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty,
              let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else {
            throw ParserError.invalidCredentials(String(localized: "Auth payload must include clientID and token.", comment: "Remote-control protocol error for missing authentication fields."))
        }
        return (clientID, token)
    }

    static func parsePair(payload: [String: Any]) throws -> (code: String, clientName: String?) {
        let code = payload["code"] as? String ?? payload["pairingCode"] as? String
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            throw ParserError.invalidCredentials(String(localized: "Pair payload must include a pairing code.", comment: "Remote-control protocol error for missing pairing code."))
        }
        let clientName = payload["clientName"] as? String ?? payload["name"] as? String
        return (code, clientName)
    }

    static func parseCommand(payload: [String: Any]) throws -> LocalNetworkRemoteCommand {
        let rawName = (payload["command"] ?? payload["name"] ?? payload["action"]) as? String
        guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ParserError.invalidCommand(String(localized: "Command payload must include command/name/action.", comment: "Remote-control protocol error for missing command name."))
        }

        switch normalizedCommandName(name) {
        case "setvolume", "volume", "setoutputvolume":
            return .setVolume(try numericValue(from: payload, keys: ["value", "volume", "outputVolume"]))
        case "setpreamp", "preamp":
            return .setPreamp(try numericValue(from: payload, keys: ["value", "preamp"]))
        case "selectpreset", "preset", "switchpreset":
            let id = payload["presetID"] as? String ?? payload["presetId"] as? String ?? payload["id"] as? String
            let presetName = payload["presetName"] as? String ?? payload["name"] as? String ?? payload["value"] as? String
            guard id != nil || presetName != nil else {
                throw ParserError.invalidCommand(String(localized: "Preset command must include presetID or presetName.", comment: "Remote-control protocol error for selecting a preset without a preset identifier or name."))
            }
            return .selectPreset(id: id, name: presetName)
        default:
            throw ParserError.unsupportedCommand(name)
        }
    }

    private static func normalizedCommandName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
    }

    private static func numericValue(from payload: [String: Any], keys: [String]) throws -> Double {
        for key in keys {
            if let value = payload[key] as? Double { return value }
            if let value = payload[key] as? Int { return Double(value) }
            if let value = payload[key] as? String, let double = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return double
            }
        }
        throw ParserError.invalidCommand(String(localized: "Command payload is missing a numeric value.", comment: "Remote-control protocol error for volume/preamp commands without a number."))
    }

    enum ParserError: LocalizedError, Equatable {
        case invalidEnvelope(String)
        case invalidCommand(String)
        case invalidCredentials(String)
        case unsupportedCommand(String)

        var errorDescription: String? {
            switch self {
            case let .invalidEnvelope(message), let .invalidCommand(message), let .invalidCredentials(message):
                message
            case let .unsupportedCommand(command):
                String(
                    localized: "Unsupported remote command: \(command)",
                    comment: "Remote-control protocol error. Interpolation is the unsupported command name."
                )
            }
        }
    }
}

extension Encodable {
    func localNetworkJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
