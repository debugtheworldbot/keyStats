import Foundation

// MARK: - API DTOs

struct CloudAuthRequest: Codable {
    let username: String
    let password: String
}

struct CloudAuthResponse: Codable {
    let token: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case token
        case userId = "user_id"
    }
}

struct CloudDevice: Codable, Identifiable {
    let id: String
    let userId: String
    let platform: String
    let deviceName: String
    let createdAt: Date
    let lastSyncAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case platform
        case deviceName = "device_name"
        case createdAt = "created_at"
        case lastSyncAt = "last_sync_at"
    }
}

struct CloudRegisterDeviceRequest: Codable {
    let deviceId: String?
    let platform: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case platform
        case deviceName = "device_name"
    }
}

/// Privacy: aggregate counters only. `keyPressCounts` maps key names to counts, not typed content.
struct CloudDailyStatsPayload: Codable {
    let date: String
    let keyPresses: Int
    let keyPressCounts: [String: Int]?
    let leftClicks: Int
    let rightClicks: Int
    let sideBackClicks: Int
    let sideForwardClicks: Int
    let mouseDistance: Double
    let scrollDistance: Double
    let peakKPS: Int
    let peakCPS: Int
    let appStats: [String: CloudAppStatsPayload]?
}

/// Privacy: per-app aggregate counts keyed by bundle id.
struct CloudAppStatsPayload: Codable {
    let bundleId: String
    let displayName: String
    let keyPresses: Int
    let leftClicks: Int
    let rightClicks: Int
    let sideBackClicks: Int
    let sideForwardClicks: Int
    let scrollDistance: Double
}

struct CloudUpsertStatsRequest: Codable {
    let deviceId: String
    let date: String
    let version: Int64
    let stats: CloudDailyStatsPayload

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case date
        case version
        case stats
    }
}

struct CloudBulkUpsertStatsRequest: Codable {
    let deviceId: String
    let records: [CloudBulkStatsRecord]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case records
    }
}

struct CloudBulkStatsRecord: Codable {
    let date: String
    let version: Int64
    let stats: CloudDailyStatsPayload
}

struct CloudStatsRecord: Codable {
    let deviceId: String
    let platform: String
    let deviceName: String
    let date: String
    let version: Int64
    let updatedAt: Date
    let stats: CloudDailyStatsPayload

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case platform
        case deviceName = "device_name"
        case date
        case version
        case updatedAt = "updated_at"
        case stats
    }
}

struct CloudDevicesResponse: Codable {
    let devices: [CloudDevice]
}

struct CloudStatsListResponse: Codable {
    let records: [CloudStatsRecord]
}

struct CloudUpsertStatsResponse: Codable {
    let accepted: Bool
    let version: Int64
}

struct CloudBulkUpsertStatsResponse: Codable {
    let accepted: Int
    let total: Int
}

struct CloudAPIErrorResponse: Codable {
    let error: String
}

enum CloudSyncError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case invalidServerURL
    case invalidResponse
    case serverError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return NSLocalizedString("sync.error.notConfigured", comment: "")
        case .notAuthenticated:
            return NSLocalizedString("sync.error.notAuthenticated", comment: "")
        case .invalidServerURL:
            return NSLocalizedString("sync.error.invalidServerURL", comment: "")
        case .invalidResponse:
            return NSLocalizedString("sync.error.invalidResponse", comment: "")
        case .serverError(let message):
            return message
        case .networkError(let message):
            return message
        }
    }
}

enum StatsDisplaySelection: Equatable, Hashable {
    case local
    case allDevices
    case device(id: String)

    var persistedValue: String {
        switch self {
        case .local:
            return "local"
        case .allDevices:
            return "all"
        case .device(let id):
            return "device:\(id)"
        }
    }

    static func from(persisted raw: String) -> StatsDisplaySelection? {
        switch raw {
        case "local":
            return .local
        case "all":
            return .allDevices
        default:
            guard raw.hasPrefix("device:") else { return nil }
            let id = String(raw.dropFirst("device:".count))
            return id.isEmpty ? nil : .device(id: id)
        }
    }

    var analyticsValue: String {
        switch self {
        case .local:
            return "local"
        case .allDevices:
            return "all"
        case .device:
            return "device"
        }
    }
}

struct StatsDisplayTab: Equatable {
    let selection: StatsDisplaySelection
    let label: String
}

struct DeviceTodaySummary: Identifiable {
    let deviceId: String
    let platform: String
    let deviceName: String
    let isLocal: Bool
    let keyPresses: Int
    let leftClicks: Int
    let rightClicks: Int
    let sideBackClicks: Int
    let sideForwardClicks: Int
    let mouseDistance: Double
    let scrollDistance: Double
    let peakKPS: Int
    let peakCPS: Int
    let lastSyncAt: Date?

    var id: String { deviceId }

    var totalClicks: Int {
        leftClicks + rightClicks + sideBackClicks + sideForwardClicks
    }

    var platformDisplayName: String {
        switch platform.lowercased() {
        case "macos": return "macOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return platform.capitalized
        }
    }

    var titleText: String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return platformDisplayName
        }
        return name
    }

    func asDailyStats() -> DailyStats {
        var stats = DailyStats()
        stats.keyPresses = keyPresses
        stats.leftClicks = leftClicks
        stats.rightClicks = rightClicks
        stats.sideBackClicks = sideBackClicks
        stats.sideForwardClicks = sideForwardClicks
        stats.mouseDistance = mouseDistance
        stats.scrollDistance = scrollDistance
        stats.peakKPS = peakKPS
        stats.peakCPS = peakCPS
        return stats
    }
}

enum CloudSyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case failed(String)
}

extension Notification.Name {
    static let cloudSyncStateDidChange = Notification.Name("cloudSyncStateDidChange")
}
