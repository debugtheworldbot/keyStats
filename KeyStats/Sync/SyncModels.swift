import Foundation

enum SyncConstants {
    static let schemaVersion = 1
    static let maximumActiveDevices = 5
    static let minimumSuccessfulSyncInterval: TimeInterval = 60 * 60
#if DEBUG
    static let enforcesSuccessfulSyncRateLimits = false
#else
    static let enforcesSuccessfulSyncRateLimits = true
#endif
    static let automaticSyncInterval: TimeInterval = 24 * 60 * 60
    static let maximumSuccessfulSyncsPerUTCDay = 8
    static let maximumAutomaticFailuresPerUTCDay = 3
    static let maximumSnapshotBytes = 64 * 1024
    static let maximumKeyEntries = 512
    static let maximumKeyNameBytes = 64
    static let maximumArchivesPerRequest = 16
    static let maximumBootstrapRequests = 256
    static let maximumBootstrapArchives = maximumArchivesPerRequest * maximumBootstrapRequests
    static let maximumHistoryPagesPerAttempt = 256
}

struct SyncProgress: Equatable {
    private(set) var completedDays = 0
    let totalDays: Int

    mutating func advance(by days: Int) {
        completedDays = min(totalDays, completedDays + max(0, days))
    }
}

struct CoreClickSnapshotV1: Codable, Equatable {
    var left: Int64
    var right: Int64
    var middle: Int64
    var sideBack: Int64
    var sideForward: Int64

    static let zero = CoreClickSnapshotV1(left: 0, right: 0, middle: 0, sideBack: 0, sideForward: 0)
}

struct CoreDaySnapshotV1: Codable, Equatable {
    let schemaVersion: Int
    let deviceId: String
    let localDay: String
    let revision: Int64
    let keyPresses: Int64
    let keyPressCounts: [String: Int64]
    let clicks: CoreClickSnapshotV1

    init(
        schemaVersion: Int = SyncConstants.schemaVersion,
        deviceId: String,
        localDay: String,
        revision: Int64,
        keyPresses: Int64,
        keyPressCounts: [String: Int64],
        clicks: CoreClickSnapshotV1
    ) {
        self.schemaVersion = schemaVersion
        self.deviceId = deviceId
        self.localDay = localDay
        self.revision = revision
        self.keyPresses = keyPresses
        self.keyPressCounts = keyPressCounts
        self.clicks = clicks
    }

    func validated() throws -> CoreDaySnapshotV1 {
        guard schemaVersion == SyncConstants.schemaVersion else { throw SyncValidationError.unsupportedSchema }
        guard !deviceId.isEmpty, SyncDay.isValid(localDay), revision >= 0, keyPresses >= 0 else {
            throw SyncValidationError.invalidSnapshot
        }
        guard keyPressCounts.count <= SyncConstants.maximumKeyEntries else {
            throw SyncValidationError.tooManyKeys
        }
        guard clicks.left >= 0, clicks.right >= 0, clicks.middle >= 0,
              clicks.sideBack >= 0, clicks.sideForward >= 0 else {
            throw SyncValidationError.invalidSnapshot
        }

        var normalizedCounts: [String: Int64] = [:]
        for (rawKey, value) in keyPressCounts {
            guard value >= 0 else { throw SyncValidationError.invalidSnapshot }
            let key = SyncKeyCanonicalizer.canonicalize(rawKey, platform: "mac")
            guard !key.isEmpty, key.lengthOfBytes(using: .utf8) <= SyncConstants.maximumKeyNameBytes else {
                throw SyncValidationError.invalidKeyName
            }
            normalizedCounts[key] = SyncMath.saturatingAdd(normalizedCounts[key] ?? 0, value)
        }

        let normalized = CoreDaySnapshotV1(
            deviceId: deviceId,
            localDay: localDay,
            revision: revision,
            keyPresses: keyPresses,
            keyPressCounts: normalizedCounts,
            clicks: clicks
        )
        let encoded = try SyncJSON.encoder.encode(normalized)
        guard encoded.count <= SyncConstants.maximumSnapshotBytes else { throw SyncValidationError.snapshotTooLarge }
        return normalized
    }
}

enum SyncValidationError: LocalizedError {
    case unsupportedSchema
    case invalidSnapshot
    case invalidKeyName
    case tooManyKeys
    case snapshotTooLarge
    case invalidRecoveryCode
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return NSLocalizedString("sync.error.unsupportedSchema", comment: "")
        case .invalidSnapshot: return NSLocalizedString("sync.error.invalidSnapshot", comment: "")
        case .invalidKeyName: return NSLocalizedString("sync.error.invalidKeyName", comment: "")
        case .tooManyKeys: return NSLocalizedString("sync.error.tooManyKeys", comment: "")
        case .snapshotTooLarge: return NSLocalizedString("sync.error.snapshotTooLarge", comment: "")
        case .invalidRecoveryCode: return NSLocalizedString("sync.error.invalidRecoveryCode", comment: "")
        case .authenticationFailed: return NSLocalizedString("sync.error.authenticationFailed", comment: "")
        }
    }
}

enum SyncMath {
    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= 0, rhs >= 0 else { return max(0, lhs) }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0 else { return max(0, lhs) }
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

enum SyncDay {
    private static let regularExpression = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func date(from day: String, calendar: Calendar = .current) -> Date? {
        guard isValid(day) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])).map {
            calendar.startOfDay(for: $0)
        }
    }

    static func isValid(_ day: String) -> Bool {
        let range = NSRange(day.startIndex..<day.endIndex, in: day)
        guard regularExpression.firstMatch(in: day, range: range) != nil,
              let parsed = date(fromValidatedShape: day) else { return false }
        return string(from: parsed, calendar: utcGregorianCalendar) == day
    }

    private static var utcGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(fromValidatedShape day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcGregorianCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum SyncKeyCanonicalizer {
    static func canonicalize(_ rawName: String, platform: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "+" { return "+" }

        var source = trimmed
        var hasLiteralPlus = false
        if source.hasSuffix("++") {
            source.removeLast()
            hasLiteralPlus = true
        }
        var parts = source.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if hasLiteralPlus { parts.append("+") }

        var normalized: [String] = []
        var seen: Set<String> = []
        for part in parts {
            let value = canonicalPart(part, platform: platform)
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            normalized.append(value)
        }
        return normalized.joined(separator: "+")
    }

    private static func canonicalPart(_ raw: String, platform: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        switch upper {
        case "ESC", "ESCAPE": return "Esc"
        case "RETURN", "ENTER", "NUMPADENTER": return "Enter"
        case "BACKSPACE", "BS": return "Backspace"
        case "DELETE", "DEL", "FORWARDDELETE": return "Delete"
        case "LEFT", "ARROWLEFT", "LEFTARROW": return "Left"
        case "RIGHT", "ARROWRIGHT", "RIGHTARROW": return "Right"
        case "UP", "ARROWUP", "UPARROW": return "Up"
        case "DOWN", "ARROWDOWN", "DOWNARROW": return "Down"
        case "COMMAND", "CMD": return "Cmd"
        case "LEFTCOMMAND", "LEFTCMD": return "LeftCmd"
        case "RIGHTCOMMAND", "RIGHTCMD": return "RightCmd"
        case "WINDOWS", "WIN", "META": return "Win"
        case "LEFTWINDOWS", "LEFTWIN": return "LeftWin"
        case "RIGHTWINDOWS", "RIGHTWIN": return "RightWin"
        case "OPTION": return "Option"
        case "LEFTOPTION": return "LeftOption"
        case "RIGHTOPTION": return "RightOption"
        case "ALT": return "Alt"
        case "LEFTALT": return "LeftAlt"
        case "RIGHTALT": return "RightAlt"
        case "CONTROL", "CTRL": return "Ctrl"
        case "LEFTCONTROL", "LEFTCTRL": return "LeftCtrl"
        case "RIGHTCONTROL", "RIGHTCTRL": return "RightCtrl"
        case "SHIFT": return "Shift"
        case "LEFTSHIFT": return "LeftShift"
        case "RIGHTSHIFT": return "RightShift"
        case "FN", "FUNCTION", "GLOBE", "🌐", "KEY63", "KEY179": return "Fn"
        case "SPACE", "SPACEBAR": return "Space"
        case "TAB": return "Tab"
        case "CAPS", "CAPSLOCK": return "CapsLock"
        case "INSERT", "INS", "HELP": return "Insert"
        case "PAGEUP": return "PageUp"
        case "PAGEDOWN": return "PageDown"
        case "HOME": return "Home"
        case "END": return "End"
        case "PRINTSCREEN", "PRTSC", "PRTSCN", "SNAPSHOT": return "PrintScreen"
        case "SCROLLLOCK", "SCROLL": return "ScrollLock"
        case "PAUSE", "BREAK": return "Pause"
        case "+": return "+"
        default:
            if value.count == 1 || upper.range(of: #"^F\d{1,2}$"#, options: .regularExpression) != nil {
                return upper
            }
            // Already-canonical unknown keys retain the source platform. This
            // prevents a Windows key from being relabelled as a macOS key when
            // a received snapshot is validated again.
            if ["mac:", "macos:", "windows:"].contains(where: { prefix in
                value.hasPrefix(prefix) && value.count > prefix.count
            }) {
                return value
            }
            return "\(platform):\(value)"
        }
    }
}

struct EncryptedSyncRecordV1: Codable, Equatable {
    let schemaVersion: Int
    let recordId: String
    let deviceId: String
    let revision: Int64
    let nonce: String
    let ciphertext: String
    let tag: String
    let ciphertextHash: String

    init(
        schemaVersion: Int = SyncConstants.schemaVersion,
        recordId: String,
        deviceId: String,
        revision: Int64,
        nonce: String,
        ciphertext: String,
        tag: String,
        ciphertextHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.recordId = recordId
        self.deviceId = deviceId
        self.revision = revision
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.ciphertextHash = ciphertextHash
    }
}

struct SyncHistoryChangeV1: Codable, Equatable {
    let cursor: Int64
    let record: EncryptedSyncRecordV1?
    let recordId: String
    let tombstone: Bool
}

struct SyncDevice: Codable, Equatable, Identifiable {
    let deviceId: String
    var displayName: String
    var platform: String
    var lastSyncAt: Date?
    var isCurrent: Bool
    var isRevoked: Bool

    var id: String { deviceId }
}

struct SyncRevisionState: Codable, Equatable {
    var revision: Int64
    var contentHash: String
}

enum SyncProvisioningKind: String, Codable {
    case create
    case recovery
    case pairing
}

struct SyncPendingProvisioning: Codable, Equatable {
    var kind: SyncProvisioningKind
    var encryptedDeviceProfile: SyncEncryptedGrant?
    var replaceDeviceId: String?
    var recoveryCodeConfirmed: Bool
    var reconcileAcceptedRecordsBeforePush: Bool
}

struct SyncPersistentState: Codable, Equatable {
    var schemaVersion = 1
    var serverBaseURL: String
    var vaultId: String?
    var deviceId: String
    var displayName: String
    var needsRepair: Bool
    var needsBootstrap: Bool
    /// The final bootstrap upload was accepted. Only paginated history remains.
    var bootstrapUploadCompleted: Bool
    var activeDeviceCount: Int
    var cursor: Int64
    var lastSuccessfulSyncAt: Date?
    var nextAllowedSyncAt: Date?
    var remainingSuccessfulSyncsToday: Int
    var quotaUTCDay: String?
    var automaticFailureUTCDay: String?
    var automaticFailureCount: Int
    var automaticRetryAt: Date?
    var automaticDueAt: Date?
    var revisions: [String: SyncRevisionState]
    /// Highest revision successfully sent through the archive path for each day.
    /// This is separate from local revisions so a request lost before reaching
    /// the Worker is retried with the exact same encrypted envelope.
    var archivedRevisions: [String: Int64]
    var pendingRecords: [String: EncryptedSyncRecordV1]
    /// Exact encrypted profile envelope retained until the final bootstrap
    /// response is accepted, so a lost response can be replayed byte-for-byte.
    var pendingEncryptedDeviceProfile: SyncEncryptedGrant?
    /// Durable non-secret transaction metadata. Seed and token remain bundled
    /// in the local credential store.
    var pendingProvisioning: SyncPendingProvisioning?
    var pendingVaultDeletion: Bool
    var lastStateRefreshAt: Date?
    var devices: [SyncDevice]

    static func fresh(serverBaseURL: String) -> SyncPersistentState {
        SyncPersistentState(
            serverBaseURL: serverBaseURL,
            vaultId: nil,
            deviceId: UUID().uuidString.lowercased(),
            displayName: Host.current().localizedName ?? "Mac",
            needsRepair: false,
            needsBootstrap: false,
            bootstrapUploadCompleted: false,
            activeDeviceCount: 0,
            cursor: 0,
            lastSuccessfulSyncAt: nil,
            nextAllowedSyncAt: nil,
            remainingSuccessfulSyncsToday: SyncConstants.maximumSuccessfulSyncsPerUTCDay,
            quotaUTCDay: nil,
            automaticFailureUTCDay: nil,
            automaticFailureCount: 0,
            automaticRetryAt: nil,
            automaticDueAt: nil,
            revisions: [:],
            archivedRevisions: [:],
            pendingRecords: [:],
            pendingEncryptedDeviceProfile: nil,
            pendingProvisioning: nil,
            pendingVaultDeletion: false,
            lastStateRefreshAt: nil,
            devices: []
        )
    }

    var isConfigured: Bool { vaultId != nil }
}

extension SyncPersistentState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, serverBaseURL, vaultId, deviceId, displayName
        case needsRepair, needsBootstrap, bootstrapUploadCompleted, activeDeviceCount, cursor
        case lastSuccessfulSyncAt, nextAllowedSyncAt, remainingSuccessfulSyncsToday, quotaUTCDay
        case automaticFailureUTCDay, automaticFailureCount, automaticRetryAt, automaticDueAt
        case revisions, archivedRevisions, pendingRecords, pendingEncryptedDeviceProfile
        case pendingProvisioning, pendingVaultDeletion, lastStateRefreshAt, devices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedSchemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported sync state schema"
            )
        }
        schemaVersion = decodedSchemaVersion
        serverBaseURL = try container.decodeIfPresent(String.self, forKey: .serverBaseURL) ?? ""
        vaultId = try container.decodeIfPresent(String.self, forKey: .vaultId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? UUID().uuidString.lowercased()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? (Host.current().localizedName ?? "Mac")
        needsRepair = try container.decodeIfPresent(Bool.self, forKey: .needsRepair) ?? false
        needsBootstrap = try container.decodeIfPresent(Bool.self, forKey: .needsBootstrap) ?? false
        bootstrapUploadCompleted = try container.decodeIfPresent(Bool.self, forKey: .bootstrapUploadCompleted) ?? false
        activeDeviceCount = try container.decodeIfPresent(Int.self, forKey: .activeDeviceCount) ?? (vaultId == nil ? 0 : 1)
        cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor) ?? 0
        lastSuccessfulSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt)
        nextAllowedSyncAt = try container.decodeIfPresent(Date.self, forKey: .nextAllowedSyncAt)
        remainingSuccessfulSyncsToday = try container.decodeIfPresent(Int.self, forKey: .remainingSuccessfulSyncsToday)
            ?? SyncConstants.maximumSuccessfulSyncsPerUTCDay
        quotaUTCDay = try container.decodeIfPresent(String.self, forKey: .quotaUTCDay)
        automaticFailureUTCDay = try container.decodeIfPresent(String.self, forKey: .automaticFailureUTCDay)
        automaticFailureCount = try container.decodeIfPresent(Int.self, forKey: .automaticFailureCount) ?? 0
        automaticRetryAt = try container.decodeIfPresent(Date.self, forKey: .automaticRetryAt)
        automaticDueAt = try container.decodeIfPresent(Date.self, forKey: .automaticDueAt)
        revisions = try container.decodeIfPresent([String: SyncRevisionState].self, forKey: .revisions) ?? [:]
        archivedRevisions = try container.decodeIfPresent([String: Int64].self, forKey: .archivedRevisions) ?? [:]
        pendingRecords = try container.decodeIfPresent([String: EncryptedSyncRecordV1].self, forKey: .pendingRecords) ?? [:]
        pendingEncryptedDeviceProfile = try container.decodeIfPresent(
            SyncEncryptedGrant.self,
            forKey: .pendingEncryptedDeviceProfile
        )
        pendingProvisioning = try container.decodeIfPresent(
            SyncPendingProvisioning.self,
            forKey: .pendingProvisioning
        )
        pendingVaultDeletion = try container.decodeIfPresent(Bool.self, forKey: .pendingVaultDeletion) ?? false
        lastStateRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastStateRefreshAt)
        devices = try container.decodeIfPresent([SyncDevice].self, forKey: .devices) ?? []
    }
}

enum SyncArchiveBatcher {
    static func batches<T>(_ values: [T], maximumCount: Int = SyncConstants.maximumArchivesPerRequest) -> [[T]] {
        precondition(maximumCount > 0)
        guard !values.isEmpty else { return [[]] }
        return stride(from: 0, to: values.count, by: maximumCount).map { start in
            Array(values[start..<min(start + maximumCount, values.count)])
        }
    }
}

enum SyncReason: String, Codable {
    case manual
    case automatic
    case bootstrap
    case recovery
    case pairing
}

enum SyncAvailability: Equatable {
    case notConfigured
    case singleDevice
    case coolingDown(until: Date)
    case dailyLimit
    case available
}

enum SyncSchedulePolicy {
    static func availability(
        state: SyncPersistentState,
        now: Date = Date(),
        enforcesRateLimits: Bool = SyncConstants.enforcesSuccessfulSyncRateLimits
    ) -> SyncAvailability {
        guard state.isConfigured else { return .notConfigured }
        guard state.activeDeviceCount >= 2 else { return .singleDevice }
        if enforcesRateLimits {
            let remaining = state.quotaUTCDay == utcDay(now)
                ? state.remainingSuccessfulSyncsToday
                : SyncConstants.maximumSuccessfulSyncsPerUTCDay
            guard remaining > 0 else { return .dailyLimit }
            if let next = state.nextAllowedSyncAt, next > now { return .coolingDown(until: next) }
            if let last = state.lastSuccessfulSyncAt {
                let next = last.addingTimeInterval(SyncConstants.minimumSuccessfulSyncInterval)
                if next > now { return .coolingDown(until: next) }
            }
        }
        return .available
    }

    static func shouldScheduleAutomaticSync(
        state: SyncPersistentState,
        now: Date = Date(),
        enforcesRateLimits: Bool = SyncConstants.enforcesSuccessfulSyncRateLimits
    ) -> Bool {
        guard state.isConfigured, state.activeDeviceCount >= 2 else { return false }
        if enforcesRateLimits {
            let remaining = state.quotaUTCDay == utcDay(now)
                ? state.remainingSuccessfulSyncsToday
                : SyncConstants.maximumSuccessfulSyncsPerUTCDay
            guard remaining > 0 else { return false }
        }
        guard automaticFailureCount(state: state, now: now) < SyncConstants.maximumAutomaticFailuresPerUTCDay else {
            return false
        }
        guard let last = state.lastSuccessfulSyncAt else { return true }
        return now.timeIntervalSince(last) >= SyncConstants.automaticSyncInterval
    }

    static func automaticFailureCount(state: SyncPersistentState, now: Date) -> Int {
        state.automaticFailureUTCDay == utcDay(now) ? state.automaticFailureCount : 0
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return SyncDay.string(from: date, calendar: calendar)
    }
}

enum SyncJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
        return decoder
    }()
}

extension Notification.Name {
    static let syncStateDidChange = Notification.Name("KeyStats.syncStateDidChange")
    static let syncRemoteCacheDidChange = Notification.Name("KeyStats.syncRemoteCacheDidChange")
}
