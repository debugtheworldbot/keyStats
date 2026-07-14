import Foundation

struct CreateVaultRequestV1: Codable {
    let vaultId: String
    let deviceId: String
    let deviceToken: String
    let recoveryAuthToken: String
    let encryptedDeviceProfile: SyncEncryptedGrant
}

struct CreateVaultResponseV1: Codable {
    let vaultId: String
    let deviceId: String
    let deviceToken: String
    let activeDeviceCount: Int
    let serverTime: Date
}

struct CreatePairingSessionRequestV1: Codable {
    let deviceId: String
    let joiningPublicKey: String
}

struct CreatePairingSessionResponseV1: Codable {
    let sessionId: String
    let code: String
    let completionToken: String
    let expiresAt: Date
}

struct JoinPairingSessionRequestV1: Codable {
    let approvingPublicKey: String
}

struct JoinPairingSessionResponseV1: Codable {
    let sessionId: String
    let joiningDeviceId: String
    let joiningPublicKey: String
    let replacedExistingDevice: Bool
    let expiresAt: Date
}

struct ApprovePairingSessionRequestV1: Codable {
    let approvingPublicKey: String
    let encryptedGrant: SyncEncryptedGrant
    let newDeviceToken: String
}

struct CompletePairingSessionRequestV1: Codable {
    let completionToken: String
    let encryptedDeviceProfile: SyncEncryptedGrant?
}

struct CompletePairingSessionResponseV1: Codable {
    let pending: Bool
    let requiresProfile: Bool
    let approvingPublicKey: String?
    let encryptedGrant: SyncEncryptedGrant?
    let replacedExistingDevice: Bool?
    let activeDeviceCount: Int?
    let serverTime: Date?
}

struct RecoverVaultRequestV1: Codable {
    let recoveryAuthToken: String
    let deviceId: String
    let deviceToken: String
    let replaceDeviceId: String?
}

struct RecoverVaultResponseV1: Codable {
    let vaultId: String
    let deviceId: String
    let deviceToken: String
    let activeDeviceCount: Int
    let serverTime: Date
    let cursor: Int64
    let currentSnapshot: EncryptedSyncRecordV1?
}

struct SyncRequestV1: Codable {
    let reason: SyncReason
    let historyCursor: Int64
    let currentSnapshot: EncryptedSyncRecordV1?
    let archives: [EncryptedSyncRecordV1]
    let encryptedDeviceProfile: SyncEncryptedGrant?
    let bootstrapComplete: Bool
}

/// Server-visible device metadata plus an E2EE profile. Display names and
/// platforms must never be returned as plaintext wire fields.
struct SyncEncryptedDeviceV1: Codable, Equatable {
    let deviceId: String
    let encryptedDeviceProfile: SyncEncryptedGrant?
    let lastSyncAt: Date?
    let revoked: Bool
}

struct SyncResponseV1: Codable {
    let serverTime: Date
    let nextAllowedSyncAt: Date
    let remainingDailySyncs: Int
    let activeDeviceCount: Int
    let currentSnapshots: [EncryptedSyncRecordV1]
    let historyChanges: [SyncHistoryChangeV1]
    let historyHasMore: Bool
    let cursor: Int64
    let devices: [SyncEncryptedDeviceV1]
}

struct HistoryResponseV1: Codable {
    let changes: [SyncHistoryChangeV1]
    let cursor: Int64
    let hasMore: Bool
}

struct SyncStateResponseV1: Codable {
    let serverTime: Date
    let activeDeviceCount: Int
    let devices: [SyncEncryptedDeviceV1]
    let currentSnapshots: [EncryptedSyncRecordV1]
}

struct EmptyResponseV1: Codable {}

protocol SyncTransport {
    func createVault(_ request: CreateVaultRequestV1) async throws -> CreateVaultResponseV1
    func createPairingSession(_ request: CreatePairingSessionRequestV1) async throws -> CreatePairingSessionResponseV1
    func joinPairingSession(code: String, request: JoinPairingSessionRequestV1, bearerToken: String) async throws -> JoinPairingSessionResponseV1
    func approvePairingSession(id: String, request: ApprovePairingSessionRequestV1, bearerToken: String) async throws
    func completePairingSession(id: String, request: CompletePairingSessionRequestV1) async throws -> CompletePairingSessionResponseV1
    func recover(_ request: RecoverVaultRequestV1) async throws -> RecoverVaultResponseV1
    func sync(_ request: SyncRequestV1, bearerToken: String, idempotencyKey: String) async throws -> SyncResponseV1
    func history(cursor: Int64, bearerToken: String) async throws -> HistoryResponseV1
    func state(bearerToken: String) async throws -> SyncStateResponseV1
    func deleteDevice(deviceId: String, bearerToken: String) async throws
    func deleteVault(bearerToken: String) async throws
}

enum SyncTransportError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case replacementDeviceNotFound
    case maximumDevices(vaultId: String?, devices: [SyncEncryptedDeviceV1])
    case singleDevice(activeDeviceCount: Int)
    case rateLimited(retryAt: Date)
    case server(statusCode: Int, code: String?)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return NSLocalizedString("sync.error.invalidConfiguration", comment: "")
        case .invalidResponse: return NSLocalizedString("sync.error.invalidResponse", comment: "")
        case .unauthorized, .forbidden: return NSLocalizedString("sync.error.authenticationFailed", comment: "")
        case .notFound: return NSLocalizedString("sync.error.notFound", comment: "")
        case .conflict, .replacementDeviceNotFound: return NSLocalizedString("sync.error.conflict", comment: "")
        case .maximumDevices: return NSLocalizedString("sync.error.maximumDevices", comment: "")
        case .singleDevice: return NSLocalizedString("sync.error.singleDevice", comment: "")
        case .rateLimited: return NSLocalizedString("sync.error.rateLimited", comment: "")
        case .server: return NSLocalizedString("sync.error.server", comment: "")
        }
    }
}

final class CloudflareSyncTransport: SyncTransport {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func createVault(_ request: CreateVaultRequestV1) async throws -> CreateVaultResponseV1 {
        try await send(path: "/v1/vaults", method: "POST", body: request)
    }

    func createPairingSession(_ request: CreatePairingSessionRequestV1) async throws -> CreatePairingSessionResponseV1 {
        try await send(path: "/v1/pairing-sessions", method: "POST", body: request)
    }

    func joinPairingSession(code: String, request: JoinPairingSessionRequestV1, bearerToken: String) async throws -> JoinPairingSessionResponseV1 {
        try await send(
            path: "/v1/pairing-sessions/\(try validatedPathComponent(code))/join",
            method: "POST",
            body: request,
            bearerToken: bearerToken
        )
    }

    func approvePairingSession(id: String, request: ApprovePairingSessionRequestV1, bearerToken: String) async throws {
        let _: EmptyResponseV1 = try await send(
            path: "/v1/pairing-sessions/\(try validatedPathComponent(id))/approve",
            method: "POST",
            body: request,
            bearerToken: bearerToken
        )
    }

    func completePairingSession(id: String, request: CompletePairingSessionRequestV1) async throws -> CompletePairingSessionResponseV1 {
        try await send(
            path: "/v1/pairing-sessions/\(try validatedPathComponent(id))/complete",
            method: "POST",
            body: request
        )
    }

    func recover(_ request: RecoverVaultRequestV1) async throws -> RecoverVaultResponseV1 {
        try await send(path: "/v1/recover", method: "POST", body: request)
    }

    func sync(_ request: SyncRequestV1, bearerToken: String, idempotencyKey: String) async throws -> SyncResponseV1 {
        try await send(
            path: "/v1/sync",
            method: "POST",
            body: request,
            bearerToken: bearerToken,
            extraHeaders: ["Idempotency-Key": idempotencyKey]
        )
    }

    func history(cursor: Int64, bearerToken: String) async throws -> HistoryResponseV1 {
        try await send(
            path: "/v1/history?cursor=\(max(0, cursor))",
            method: "GET",
            body: Optional<String>.none,
            bearerToken: bearerToken
        )
    }

    func state(bearerToken: String) async throws -> SyncStateResponseV1 {
        try await send(
            path: "/v1/state",
            method: "GET",
            body: Optional<String>.none,
            bearerToken: bearerToken
        )
    }

    func deleteDevice(deviceId: String, bearerToken: String) async throws {
        let _: EmptyResponseV1 = try await send(
            path: "/v1/devices/\(try validatedPathComponent(deviceId))",
            method: "DELETE",
            body: Optional<String>.none,
            bearerToken: bearerToken
        )
    }

    func deleteVault(bearerToken: String) async throws {
        let _: EmptyResponseV1 = try await send(
            path: "/v1/vault",
            method: "DELETE",
            body: Optional<String>.none,
            bearerToken: bearerToken
        )
    }

    private func send<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request?,
        bearerToken: String? = nil,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              baseURL.scheme == "https",
              baseURL.host?.hasSuffix(".workers.dev") == true,
              !baseURL.absoluteString.contains("<"),
              !baseURL.absoluteString.contains("example") else {
            throw SyncTransportError.invalidConfiguration
        }
        let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.path = normalizedBasePath(components.path) + String(split[0])
        if split.count == 2 { components.percentEncodedQuery = String(split[1]) }
        guard let url = components.url else { throw SyncTransportError.invalidConfiguration }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            urlRequest.httpBody = try SyncJSON.encoder.encode(body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearerToken {
            urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw mapError(response: http, data: data)
        }
        if Response.self == EmptyResponseV1.self, data.isEmpty,
           let empty = EmptyResponseV1() as? Response {
            return empty
        }
        do {
            return try SyncJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw SyncTransportError.invalidResponse
        }
    }

    private func mapError(response: HTTPURLResponse, data: Data) -> SyncTransportError {
        struct ErrorEnvelope: Decodable {
            let code: String?
            let error: String?
            let activeDeviceCount: Int?
            let vaultId: String?
            let devices: [SyncEncryptedDeviceV1]?
        }
        let envelope = try? SyncJSON.decoder.decode(ErrorEnvelope.self, from: data)
        switch response.statusCode {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409:
            if envelope?.code == "single_device_sync_disabled",
               envelope?.activeDeviceCount == 1 {
                return .singleDevice(activeDeviceCount: 1)
            }
            if envelope?.code == "maximum_devices" {
                return .maximumDevices(vaultId: envelope?.vaultId, devices: envelope?.devices ?? [])
            }
            if envelope?.code == "replace_device_not_found" {
                return .replacementDeviceNotFound
            }
            return .conflict
        case 429:
            return .rateLimited(retryAt: retryDate(from: response) ?? Date().addingTimeInterval(60))
        default:
            return .server(statusCode: response.statusCode, code: envelope?.code ?? envelope?.error)
        }
    }

    private func retryDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) { return Date().addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }

    private func normalizedBasePath(_ path: String) -> String {
        guard !path.isEmpty, path != "/" else { return "" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func validatedPathComponent(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
            throw SyncTransportError.invalidConfiguration
        }
        return value
    }
}
