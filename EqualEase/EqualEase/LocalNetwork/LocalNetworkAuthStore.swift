//
//  LocalNetworkAuthStore.swift
//  EqualEase
//

import Combine
import CryptoKit
import Foundation
import Security

struct LocalNetworkPairedClient: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var pairedAt: Date
    var lastAuthenticatedAt: Date?
}

struct LocalNetworkPairingSession: Equatable {
    var code: String
    var expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

struct LocalNetworkAuthCredential: Codable, Equatable {
    var clientID: String
    var clientName: String
    var token: String
}

@MainActor
final class LocalNetworkAuthStore: ObservableObject {
    @Published private(set) var clients: [LocalNetworkPairedClient] = []
    @Published private(set) var pairingSession: LocalNetworkPairingSession?

    private var persistedClients: [PersistedClient]
    private let persistenceURL: URL
    private let now: () -> Date
    private var pairingExpiryTimer: Timer?
    private var failedPairingAttemptDates: [Date] = []
    private var pairingRateLimitedUntil: Date?

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.persistenceURL = Self.persistenceURL(fileManager: fileManager)
        self.now = now
        self.persistedClients = Self.loadPersistedClients(from: persistenceURL)
        self.clients = persistedClients.map(\.publicClient)
    }

    init(persistenceURL: URL, now: @escaping () -> Date = Date.init) {
        self.persistenceURL = persistenceURL
        self.now = now
        self.persistedClients = Self.loadPersistedClients(from: persistenceURL)
        self.clients = persistedClients.map(\.publicClient)
    }

    deinit {
        pairingExpiryTimer?.invalidate()
    }

    @discardableResult
    func beginPairing() -> LocalNetworkPairingSession {
        prunePairingRateLimit(now: now())
        let session = LocalNetworkPairingSession(
            code: Self.generatePairingCode(),
            expiresAt: now().addingTimeInterval(5 * 60)
        )
        pairingSession = session
        schedulePairingExpiry(for: session)
        return session
    }

    func cancelPairing() {
        pairingExpiryTimer?.invalidate()
        pairingExpiryTimer = nil
        pairingSession = nil
    }

    func pair(code rawCode: String, clientName rawClientName: String?) throws -> LocalNetworkAuthCredential {
        pruneExpiredPairingSession()
        guard let session = pairingSession else {
            throw AuthError.pairingUnavailable
        }
        guard !isPairingRateLimited(now: now()) else {
            throw AuthError.pairingRateLimited
        }
        guard Self.normalizedPairingCode(rawCode) == session.code else {
            recordFailedPairingAttempt()
            throw isPairingRateLimited(now: now()) ? AuthError.pairingRateLimited : AuthError.invalidPairingCode
        }

        clearPairingFailures()
        let token = Self.generateToken()
        let salt = Self.randomData(byteCount: 16)
        let now = now()
        let clientName = Self.cleanedClientName(rawClientName)
        let persisted = PersistedClient(
            id: UUID().uuidString,
            name: clientName,
            pairedAt: now,
            lastAuthenticatedAt: now,
            salt: salt.base64EncodedString(),
            tokenHash: Self.hash(token: token, salt: salt)
        )
        persistedClients.append(persisted)
        clients = persistedClients.map(\.publicClient)
        save()
        cancelPairing()

        return LocalNetworkAuthCredential(clientID: persisted.id, clientName: persisted.name, token: token)
    }

    func authenticate(clientID: String?, token: String?) -> LocalNetworkPairedClient? {
        guard let clientID, let token, !clientID.isEmpty, !token.isEmpty,
              let index = persistedClients.firstIndex(where: { $0.id == clientID }),
              let salt = Data(base64Encoded: persistedClients[index].salt)
        else { return nil }

        let candidate = Self.hash(token: token, salt: salt)
        guard Self.constantTimeEqual(candidate, persistedClients[index].tokenHash) else { return nil }

        persistedClients[index].lastAuthenticatedAt = now()
        clients = persistedClients.map(\.publicClient)
        save()
        return persistedClients[index].publicClient
    }

    func containsClient(id: String?) -> Bool {
        guard let id else { return false }
        return persistedClients.contains { $0.id == id }
    }

    func revoke(clientID: String) {
        persistedClients.removeAll { $0.id == clientID }
        clients = persistedClients.map(\.publicClient)
        save()
    }

    func reset() {
        cancelPairing()
        clearPairingFailures()
        persistedClients = []
        clients = []
        save()
    }

    func pruneExpiredPairingSession() {
        guard let session = pairingSession, now() >= session.expiresAt else { return }
        cancelPairing()
    }

    private func recordFailedPairingAttempt() {
        let now = now()
        prunePairingRateLimit(now: now)
        failedPairingAttemptDates.append(now)
        if failedPairingAttemptDates.count >= Self.maximumFailedPairingAttempts {
            pairingRateLimitedUntil = now.addingTimeInterval(Self.pairingRateLimitDuration)
        }
    }

    private func isPairingRateLimited(now: Date) -> Bool {
        prunePairingRateLimit(now: now)
        return pairingRateLimitedUntil.map { now < $0 } ?? false
    }

    private func prunePairingRateLimit(now: Date) {
        failedPairingAttemptDates.removeAll { now.timeIntervalSince($0) > Self.failedPairingAttemptWindow }
        if let rateLimitedUntil = pairingRateLimitedUntil, now >= rateLimitedUntil {
            clearPairingFailures()
        }
    }

    private func clearPairingFailures() {
        failedPairingAttemptDates = []
        pairingRateLimitedUntil = nil
    }

    private func schedulePairingExpiry(for session: LocalNetworkPairingSession) {
        pairingExpiryTimer?.invalidate()
        pairingExpiryTimer = Timer.scheduledTimer(withTimeInterval: max(session.expiresAt.timeIntervalSince(now()), 0.1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard self?.pairingSession == session else { return }
                self?.cancelPairing()
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = PersistedState(clients: persistedClients)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("EqualEase local network auth: could not save paired clients: %@", error.localizedDescription)
        }
    }

    private static func loadPersistedClients(from url: URL) -> [PersistedClient] {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedState.self, from: data).clients
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            NSLog("EqualEase local network auth: could not load paired clients: %@", error.localizedDescription)
            return []
        }
    }

    private static func persistenceURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("EqualEase", isDirectory: true).appendingPathComponent("local-network-auth.json")
    }

    private static let maximumFailedPairingAttempts = 5
    private static let failedPairingAttemptWindow: TimeInterval = 5 * 60
    private static let pairingRateLimitDuration: TimeInterval = 5 * 60

    private static func cleanedClientName(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? String(localized: "Phone Remote", comment: "Default display name for a newly paired local-network remote client.")
            : String(trimmed.prefix(80))
    }

    private static func normalizedPairingCode(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    private static func generatePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func generateToken() -> String {
        randomData(byteCount: 32).base64URLEncodedString()
    }

    private static func randomData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private static func hash(token: String, salt: Data) -> String {
        var data = Data(salt)
        data.append(Data(token.utf8))
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = [UInt8](lhs.utf8)
        let right = [UInt8](rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }

    enum AuthError: LocalizedError, Equatable {
        case pairingUnavailable
        case invalidPairingCode
        case pairingRateLimited

        var errorDescription: String? {
            switch self {
            case .pairingUnavailable:
                String(localized: "Pairing is not active. Start pairing from Settings > General > Local Network Remote.", comment: "Local-network remote pairing error when no temporary pairing session exists.")
            case .invalidPairingCode:
                String(localized: "The pairing code is invalid or expired.", comment: "Local-network remote pairing error for a wrong or expired six-digit code.")
            case .pairingRateLimited:
                String(localized: "Too many pairing attempts. Wait a few minutes before trying again.", comment: "Local-network remote pairing error after too many failed six-digit code attempts.")
            }
        }
    }

    private struct PersistedState: Codable {
        var clients: [PersistedClient]
    }

    private struct PersistedClient: Codable, Equatable {
        var id: String
        var name: String
        var pairedAt: Date
        var lastAuthenticatedAt: Date?
        var salt: String
        var tokenHash: String

        var publicClient: LocalNetworkPairedClient {
            LocalNetworkPairedClient(id: id, name: name, pairedAt: pairedAt, lastAuthenticatedAt: lastAuthenticatedAt)
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
