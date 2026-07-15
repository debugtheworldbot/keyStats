import Foundation

enum SyncStorageError: LocalizedError {
    case invalidApplicationSupportDirectory
    case corruptState
    case corruptCache

    var errorDescription: String? {
        switch self {
        case .invalidApplicationSupportDirectory:
            return NSLocalizedString("sync.error.invalidApplicationSupportDirectory", comment: "")
        case .corruptState:
            return NSLocalizedString("sync.error.corruptState", comment: "")
        case .corruptCache:
            return NSLocalizedString("sync.error.corruptCache", comment: "")
        }
    }
}

enum SyncConfiguration {
    static var serverBaseURL: URL? {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "KeyStatsSyncServiceURL") as? String,
              !configured.isEmpty,
              !configured.contains("<"),
              !configured.contains("$("),
              !configured.contains("example"),
              let url = URL(string: configured),
              url.scheme == "https",
              url.host?.hasSuffix(".workers.dev") == true else { return nil }
        return url
    }

    @discardableResult
    static func bind(configuredServiceURL: URL, to state: inout SyncPersistentState) -> Bool {
        if state.isConfigured,
           !state.serverBaseURL.isEmpty,
           serviceIdentity(URL(string: state.serverBaseURL)) != serviceIdentity(configuredServiceURL) {
            state.needsRepair = true
            return false
        }
        state.serverBaseURL = configuredServiceURL.absoluteString
        return true
    }

    private static func serviceIdentity(_ url: URL?) -> String? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        return components.string
    }
}

/// Random installation lineage used only to reclaim the same cloud device
/// after local sync state or credentials are repaired. It is not an
/// authentication secret and is intentionally kept outside sync-state.json so
/// a corrupt state file cannot force the same local history under a new ID.
enum SyncInstallationIdentity {
    private static let currentKey = "sync.installationDeviceId.v1"
    private static let previousKey = "sync.previousInstallationDeviceId.v1"

    static func current(preferred: String? = nil) -> String {
        let defaults = UserDefaults.standard
        if let preferred, isDeviceId(preferred) {
            defaults.set(preferred.lowercased(), forKey: currentKey)
            return preferred.lowercased()
        }
        if let stored = defaults.string(forKey: currentKey), isDeviceId(stored) {
            return stored.lowercased()
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: currentKey)
        return generated
    }

    static var replacementCandidate: String? {
        guard let stored = UserDefaults.standard.string(forKey: previousKey), isDeviceId(stored) else {
            return nil
        }
        return stored.lowercased()
    }

    @discardableResult
    static func rotate() -> String {
        let defaults = UserDefaults.standard
        if let current = defaults.string(forKey: currentKey), isDeviceId(current) {
            defaults.set(current.lowercased(), forKey: previousKey)
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: currentKey)
        return generated
    }

    static func clearReplacementCandidate() {
        UserDefaults.standard.removeObject(forKey: previousKey)
    }

    private static func isDeviceId(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

final class SyncStateStore {
    static let shared = SyncStateStore()

    private let fileURL: URL
    private let lock = NSLock()
    private(set) var loadError: Error?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SyncStoragePaths.defaultDirectory.appendingPathComponent("sync-state.json")
    }

    func load() -> SyncPersistentState {
        lock.lock()
        defer { lock.unlock() }
        let fallbackURL = SyncConfiguration.serverBaseURL?.absoluteString ?? ""
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .fresh(serverBaseURL: fallbackURL)
        }
        do {
            let state = try SyncJSON.decoder.decode(SyncPersistentState.self, from: Data(contentsOf: fileURL))
            loadError = nil
            return state
        } catch {
            loadError = SyncStorageError.corruptState
            return .fresh(serverBaseURL: fallbackURL)
        }
    }

    func save(_ state: SyncPersistentState) throws {
        lock.lock()
        defer { lock.unlock() }
        try AtomicJSONFile.write(SyncJSON.encoder.encode(state), to: fileURL)
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

}

private struct CachedRemoteShard: Codable, Equatable {
    let recordId: String
    let snapshot: CoreDaySnapshotV1
}

private struct RemoteShardCachePayload: Codable {
    var schemaVersion = 1
    var shards: [String: CachedRemoteShard]
}

enum RemoteShardApplyResult: Equatable {
    case inserted
    case replaced
    case unchanged
    case ignoredOlderRevision
}

final class RemoteShardCache {
    static let shared = RemoteShardCache()

    private let fileURL: URL
    private let lock = NSLock()
    private var shards: [String: CachedRemoteShard] = [:]
    private(set) var loadError: Error?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SyncStoragePaths.defaultDirectory.appendingPathComponent("sync-cache.json")
        loadFromDisk()
    }

    @discardableResult
    func apply(recordId: String, snapshot: CoreDaySnapshotV1, currentDeviceId: String) throws -> RemoteShardApplyResult {
        guard snapshot.deviceId != currentDeviceId else { return .ignoredOlderRevision }
        let validated = try snapshot.validated()
        let key = shardKey(deviceId: validated.deviceId, localDay: validated.localDay)

        lock.lock()
        defer { lock.unlock() }
        if let existing = shards[key] {
            if validated.revision < existing.snapshot.revision { return .ignoredOlderRevision }
            if validated.revision == existing.snapshot.revision {
                guard validated == existing.snapshot, recordId == existing.recordId else {
                    throw SyncTransportError.conflict
                }
                return .unchanged
            }
            shards[key] = CachedRemoteShard(recordId: recordId, snapshot: validated)
            try persistLocked()
            notifyChanged()
            return .replaced
        }
        shards[key] = CachedRemoteShard(recordId: recordId, snapshot: validated)
        try persistLocked()
        notifyChanged()
        return .inserted
    }

    func applyTombstone(recordId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let oldCount = shards.count
        shards = shards.filter { $0.value.recordId != recordId }
        guard shards.count != oldCount else { return }
        try persistLocked()
        notifyChanged()
    }

    func snapshots(excludingDeviceId deviceId: String? = nil) -> [CoreDaySnapshotV1] {
        lock.lock()
        defer { lock.unlock() }
        return shards.values.compactMap { shard in
            if let deviceId, shard.snapshot.deviceId == deviceId { return nil }
            return shard.snapshot
        }
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        shards.removeAll()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        notifyChanged()
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let payload = try SyncJSON.decoder.decode(RemoteShardCachePayload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1 else { throw SyncStorageError.corruptCache }
            shards = payload.shards
            loadError = nil
        } catch {
            loadError = SyncStorageError.corruptCache
            shards = [:]
        }
    }

    private func persistLocked() throws {
        let payload = RemoteShardCachePayload(shards: shards)
        try AtomicJSONFile.write(SyncJSON.encoder.encode(payload), to: fileURL)
    }

    private func shardKey(deviceId: String, localDay: String) -> String {
        "\(deviceId)|\(localDay)"
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .syncRemoteCacheDidChange, object: nil)
        }
    }
}

private enum SyncStoragePaths {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KeyStats", isDirectory: true)
    }
}

private enum AtomicJSONFile {
    static func write(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
