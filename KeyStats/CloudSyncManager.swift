import Foundation
import Cocoa

/// Orchestrates cloud sync for macOS KeyStats.
/// Privacy: uploads aggregate daily stats per device; does not upload raw keystroke content.
final class CloudSyncManager {
    static let shared = CloudSyncManager()

    private let client = CloudSyncClient()
    private let defaults = UserDefaults.standard

    private let serverURLKey = "cloudSyncServerURL"
    private let syncEnabledKey = "cloudSyncEnabled"
    private let deviceIdKey = "cloudSyncDeviceId"
    private let usernameKey = "cloudSyncUsername"
    private let lastUploadVersionsKey = "cloudSyncLastUploadVersions"
    private let lastUploadFingerprintsKey = "cloudSyncLastUploadFingerprints"
    private let initialBulkUploadedKey = "cloudSyncInitialBulkUploaded"
    private let displaySelectionKey = "cloudSyncDisplaySelection"
    private let legacyDisplayScopeKey = "cloudSyncDisplayScope"

    private var uploadDebounceTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?
    private let uploadDebounceInterval: TimeInterval = 60.0
    private let autoSyncInterval: TimeInterval = 60.0

    private(set) var status: CloudSyncStatus = .idle
    private(set) var remoteRecords: [CloudStatsRecord] = []
    private(set) var devices: [CloudDevice] = []

    var onStateChanged: (() -> Void)?

    private init() {}

    // MARK: - Public settings

    var serverURLString: String {
        get { defaults.string(forKey: serverURLKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: serverURLKey) }
    }

    var isSyncEnabled: Bool {
        get { defaults.bool(forKey: syncEnabledKey) }
        set {
            defaults.set(newValue, forKey: syncEnabledKey)
            if newValue {
                scheduleUpload()
                Task { @MainActor in
                    await self.syncNow()
                    self.startAutoSyncIfNeeded()
                }
            } else {
                uploadDebounceTask?.cancel()
                stopAutoSync()
            }
        }
    }

    var savedUsername: String {
        defaults.string(forKey: usernameKey) ?? ""
    }

    var isAuthenticated: Bool {
        CloudSyncKeychain.loadToken() != nil
    }

    var isCloudDisplayAvailable: Bool {
        isAuthenticated && isSyncEnabled
    }

    var displaySelection: StatsDisplaySelection {
        get {
            if let raw = defaults.string(forKey: displaySelectionKey),
               let selection = StatsDisplaySelection.from(persisted: raw) {
                return selection
            }
            let legacy = defaults.integer(forKey: legacyDisplayScopeKey)
            return legacy == 1 ? .allDevices : .local
        }
        set {
            defaults.set(newValue.persistedValue, forKey: displaySelectionKey)
            notifyStateChanged()
        }
    }

    func displayTabs() -> [StatsDisplayTab] {
        guard isCloudDisplayAvailable else { return [] }

        var tabs: [StatsDisplayTab] = [
            StatsDisplayTab(
                selection: .local,
                label: NSLocalizedString("deviceStats.scope.local", comment: "")
            )
        ]

        let remoteDevices = devices
            .filter { $0.id != localDeviceId }
            .sorted {
                $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
            }

        for device in remoteDevices {
            let name = device.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? platformDisplayName(device.platform) : name
            tabs.append(
                StatsDisplayTab(
                    selection: .device(id: device.id),
                    label: truncatedTabLabel(label)
                )
            )
        }

        tabs.append(
            StatsDisplayTab(
                selection: .allDevices,
                label: NSLocalizedString("deviceStats.scope.allDevices", comment: "")
            )
        )
        return tabs
    }

    func validatedDisplaySelection() -> StatsDisplaySelection {
        guard isCloudDisplayAvailable else { return .local }
        let allowed = Set(displayTabs().map(\.selection))
        let current = displaySelection
        if allowed.contains(current) {
            return current
        }
        let fallback: StatsDisplaySelection = .local
        if current != fallback {
            displaySelection = fallback
        }
        return fallback
    }

    var localDeviceId: String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: deviceIdKey)
        return generated
    }

    func normalizedServerURL() -> URL? {
        var raw = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") {
            raw = "http://\(raw)"
        }
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    // MARK: - Auth

    func register(username: String, password: String) async throws {
        guard let baseURL = normalizedServerURL() else { throw CloudSyncError.invalidServerURL }
        let response = try await client.register(baseURL: baseURL, username: username, password: password)
        persistAuth(username: username, token: response.token, userId: response.userId)
        guard CloudSyncKeychain.loadToken() != nil else {
            throw CloudSyncError.serverError(NSLocalizedString("sync.error.keychainSaveFailed", comment: ""))
        }
        try await ensureDeviceRegistered()
        defaults.set(false, forKey: initialBulkUploadedKey)
        defaults.set(true, forKey: syncEnabledKey)
        if let error = await runSyncPipeline(includePull: true) {
            throw CloudSyncError.serverError(error)
        }
        await setStatus(.success(Date()))
        startAutoSyncIfNeeded()
    }

    func login(username: String, password: String) async throws {
        guard let baseURL = normalizedServerURL() else { throw CloudSyncError.invalidServerURL }
        let response = try await client.login(baseURL: baseURL, username: username, password: password)
        persistAuth(username: username, token: response.token, userId: response.userId)
        guard CloudSyncKeychain.loadToken() != nil else {
            throw CloudSyncError.serverError(NSLocalizedString("sync.error.keychainSaveFailed", comment: ""))
        }
        try await ensureDeviceRegistered()
        defaults.set(true, forKey: syncEnabledKey)
        if let error = await runSyncPipeline(includePull: true) {
            throw CloudSyncError.serverError(error)
        }
        await setStatus(.success(Date()))
        startAutoSyncIfNeeded()
    }

    func logout() {
        CloudSyncKeychain.clearCredentials()
        defaults.removeObject(forKey: usernameKey)
        defaults.set(false, forKey: syncEnabledKey)
        uploadDebounceTask?.cancel()
        stopAutoSync()
        Task { @MainActor in
            clearSessionState()
        }
    }

    // MARK: - Sync lifecycle

    func handleLocalStatsSaved() {
        guard isSyncEnabled, isAuthenticated else { return }
        scheduleUpload()
    }

    func scheduleUpload() {
        uploadDebounceTask?.cancel()
        uploadDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(self.uploadDebounceInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            if let error = await self.runSyncPipeline(includePull: false) {
                self.setStatus(.failed(error))
            }
        }
    }

    func syncNow() async {
        guard isSyncEnabled, isAuthenticated else { return }
        await setStatus(.syncing)
        if let error = await runSyncPipeline(includePull: true) {
            await setStatus(.failed(error))
        } else {
            await setStatus(.success(Date()))
        }
    }

    /// Returns an error message on failure, nil on success. Never throws.
    @MainActor
    private func runSyncPipeline(includePull: Bool) async -> String? {
        if let error = await performUploadLocalStats() {
            return error
        }
        if includePull, let error = await performPullRemoteStats() {
            return error
        }
        return nil
    }

    private func performUploadLocalStats() async -> String? {
        do {
            try await uploadLocalStatsThrowing()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func performPullRemoteStats() async -> String? {
        do {
            try await pullRemoteStatsThrowing()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func bootstrapIfNeeded() {
        guard isSyncEnabled, isAuthenticated else { return }
        startAutoSyncIfNeeded()
        Task { await syncNow() }
    }

    private func startAutoSyncIfNeeded() {
        guard isSyncEnabled, isAuthenticated else {
            stopAutoSync()
            return
        }
        guard autoSyncTask == nil else { return }

        autoSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let nanoseconds = UInt64(self.autoSyncInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                guard self.isSyncEnabled, self.isAuthenticated else { return }
                await self.setStatus(.syncing)
                if let error = await self.runSyncPipeline(includePull: true) {
                    self.setStatus(.failed(error))
                } else {
                    self.setStatus(.success(Date()))
                }
            }
        }
    }

    private func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    // MARK: - Query helpers

    func records(forPlatform platform: String) -> [CloudStatsRecord] {
        remoteRecords.filter { $0.platform == platform }
    }

    func records(forDeviceId deviceId: String) -> [CloudStatsRecord] {
        remoteRecords.filter { $0.deviceId == deviceId }
    }

    func aggregatedTodayKeyPresses(includeLocal: Bool = true) -> Int {
        deviceSummariesForToday().reduce(0) { partial, summary in
            if !includeLocal && summary.isLocal {
                return partial
            }
            return partial + summary.keyPresses
        }
    }

    func statsForDisplay(selection: StatsDisplaySelection? = nil) -> DailyStats {
        let resolved = selection ?? validatedDisplaySelection()
        switch resolved {
        case .local:
            return StatsManager.shared.currentStats
        case .allDevices:
            return aggregateTodayStats()
        case .device(let id):
            return todayStats(forDeviceId: id)
        }
    }

    func keyPressCountsForDisplay(selection: StatsDisplaySelection? = nil) -> [String: Int] {
        let resolved = selection ?? validatedDisplaySelection()
        switch resolved {
        case .local:
            return StatsManager.shared.currentStats.keyPressCounts
        case .allDevices:
            return aggregatedTodayKeyPressCounts()
        case .device(let id):
            if id == localDeviceId {
                return StatsManager.shared.currentStats.keyPressCounts
            }
            let todayKey = Self.dayKey(for: Date())
            guard let record = remoteRecords.first(where: { $0.deviceId == id && $0.date == todayKey }),
                  let counts = record.stats.keyPressCounts else {
                return [:]
            }
            return counts
        }
    }

    func keyboardHeatmapDateBounds(selection: StatsDisplaySelection? = nil) -> (start: Date, end: Date) {
        let resolved = selection ?? validatedDisplaySelection()
        switch resolved {
        case .local:
            return StatsManager.shared.keyboardHeatmapDateBounds()
        case .allDevices:
            return mergedKeyboardHeatmapDateBounds()
        case .device(let id):
            if id == localDeviceId {
                return StatsManager.shared.keyboardHeatmapDateBounds()
            }
            return remoteKeyboardHeatmapDateBounds(deviceId: id)
        }
    }

    func keyboardHeatmapDay(
        for date: Date,
        selection: StatsDisplaySelection? = nil
    ) -> StatsManager.KeyboardHeatmapDay {
        let resolved = selection ?? validatedDisplaySelection()
        let normalizedDate = Calendar.current.startOfDay(for: date)

        switch resolved {
        case .local:
            return StatsManager.shared.keyboardHeatmapDay(for: normalizedDate)
        case .device(let id):
            if id == localDeviceId {
                return StatsManager.shared.keyboardHeatmapDay(for: normalizedDate)
            }
            let dayKey = Self.dayKey(for: normalizedDate)
            guard let record = remoteRecords.first(where: { $0.deviceId == id && $0.date == dayKey }),
                  let counts = record.stats.keyPressCounts else {
                return StatsManager.KeyboardHeatmapDay(
                    date: normalizedDate,
                    totalKeyPresses: 0,
                    keyCounts: [:]
                )
            }
            return StatsManager.KeyboardHeatmapDay(
                date: normalizedDate,
                totalKeyPresses: max(0, record.stats.keyPresses),
                keyCounts: keyboardHeatmapCounts(from: counts)
            )
        case .allDevices:
            return mergedKeyboardHeatmapDay(for: normalizedDate)
        }
    }

    func aggregatedTodayKeyPressCounts() -> [String: Int] {
        var merged = StatsManager.shared.currentStats.keyPressCounts
        let todayKey = Self.dayKey(for: Date())
        for record in remoteRecords where record.date == todayKey && record.deviceId != localDeviceId {
            guard let counts = record.stats.keyPressCounts else { continue }
            for (key, count) in counts {
                let normalized = max(0, count)
                guard normalized > 0 else { continue }
                merged[key, default: 0] += normalized
            }
        }
        return merged
    }

    func keyPressBreakdownSortedForDisplay() -> [(key: String, count: Int)] {
        let sourceCounts = isCloudDisplayAvailable
            ? keyPressCountsForDisplay()
            : StatsManager.shared.currentStats.keyPressCounts
        return keyBreakdownDisplayCounts(from: sourceCounts)
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .map { (key: $0.key, count: $0.value) }
    }

    func appStatsSummary(
        range: StatsManager.AppStatsRange,
        selection: StatsDisplaySelection? = nil
    ) -> [AppStats] {
        let resolved = selection ?? validatedDisplaySelection()
        switch resolved {
        case .local:
            return StatsManager.shared.appStatsSummary(range: range)
        case .device(let id):
            if id == localDeviceId {
                return StatsManager.shared.appStatsSummary(range: range)
            }
            return remoteAppStatsSummary(range: range, deviceId: id)
        case .allDevices:
            return mergedAppStatsSummary(range: range)
        }
    }

    func deviceSummariesForToday() -> [DeviceTodaySummary] {
        let todayKey = Self.dayKey(for: Date())
        var summaries: [DeviceTodaySummary] = []

        let localStats = StatsManager.shared.currentStats
        let localMeta = devices.first { $0.id == localDeviceId }
        summaries.append(
            DeviceTodaySummary(
                deviceId: localDeviceId,
                platform: localMeta?.platform ?? "macos",
                deviceName: localMeta?.deviceName ?? (Host.current().localizedName ?? "Mac"),
                isLocal: true,
                keyPresses: localStats.keyPresses,
                leftClicks: localStats.leftClicks,
                rightClicks: localStats.rightClicks,
                sideBackClicks: localStats.sideBackClicks,
                sideForwardClicks: localStats.sideForwardClicks,
                mouseDistance: localStats.mouseDistance,
                scrollDistance: localStats.scrollDistance,
                peakKPS: localStats.peakKPS,
                peakCPS: localStats.peakCPS,
                lastSyncAt: localMeta?.lastSyncAt
            )
        )

        let knownDeviceIDs = Set(devices.map(\.id))
        for device in devices where device.id != localDeviceId {
            summaries.append(makeDeviceSummary(for: device, dateKey: todayKey))
        }

        let orphanRecords = remoteRecords.filter { record in
            record.date == todayKey && !knownDeviceIDs.contains(record.deviceId) && record.deviceId != localDeviceId
        }
        for record in orphanRecords {
            summaries.append(summary(from: record, isLocal: false))
        }

        return summaries.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            return lhs.titleText.localizedCaseInsensitiveCompare(rhs.titleText) == .orderedAscending
        }
    }

    private func makeDeviceSummary(for device: CloudDevice, dateKey: String) -> DeviceTodaySummary {
        if let record = remoteRecords.first(where: { $0.deviceId == device.id && $0.date == dateKey }) {
            return summary(from: record, isLocal: false)
        }
        return DeviceTodaySummary(
            deviceId: device.id,
            platform: device.platform,
            deviceName: device.deviceName,
            isLocal: false,
            keyPresses: 0,
            leftClicks: 0,
            rightClicks: 0,
            sideBackClicks: 0,
            sideForwardClicks: 0,
            mouseDistance: 0,
            scrollDistance: 0,
            peakKPS: 0,
            peakCPS: 0,
            lastSyncAt: device.lastSyncAt
        )
    }

    private func summary(from record: CloudStatsRecord, isLocal: Bool) -> DeviceTodaySummary {
        DeviceTodaySummary(
            deviceId: record.deviceId,
            platform: record.platform,
            deviceName: record.deviceName,
            isLocal: isLocal,
            keyPresses: record.stats.keyPresses,
            leftClicks: record.stats.leftClicks,
            rightClicks: record.stats.rightClicks,
            sideBackClicks: record.stats.sideBackClicks,
            sideForwardClicks: record.stats.sideForwardClicks,
            mouseDistance: record.stats.mouseDistance,
            scrollDistance: record.stats.scrollDistance,
            peakKPS: record.stats.peakKPS,
            peakCPS: record.stats.peakCPS,
            lastSyncAt: record.updatedAt
        )
    }

    private func remoteAppStatsSummary(
        range: StatsManager.AppStatsRange,
        deviceId: String
    ) -> [AppStats] {
        var totals: [String: AppStats] = [:]
        for record in remoteRecords where record.deviceId == deviceId {
            guard recordMatchesAppStatsRange(record, range: range) else { continue }
            mergeAppStats(from: record.stats.appStats, into: &totals)
        }
        return Array(totals.values)
    }

    private func mergedAppStatsSummary(range: StatsManager.AppStatsRange) -> [AppStats] {
        var totals: [String: AppStats] = [:]
        for item in StatsManager.shared.appStatsSummary(range: range) {
            totals[item.bundleId] = item
        }
        for record in remoteRecords where record.deviceId != localDeviceId {
            guard recordMatchesAppStatsRange(record, range: range) else { continue }
            mergeAppStats(from: record.stats.appStats, into: &totals)
        }
        return Array(totals.values)
    }

    private func recordMatchesAppStatsRange(
        _ record: CloudStatsRecord,
        range: StatsManager.AppStatsRange
    ) -> Bool {
        switch range {
        case .all:
            return true
        default:
            return dayKeys(for: range).contains(record.date)
        }
    }

    private func dayKeys(for range: StatsManager.AppStatsRange) -> Set<String> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch range {
        case .today:
            return [Self.dayKey(for: today)]
        case .week:
            return dayKeys(endingAt: today, dayCount: 7)
        case .month:
            return dayKeys(endingAt: today, dayCount: 30)
        case .all:
            return []
        }
    }

    private func dayKeys(endingAt end: Date, dayCount: Int) -> Set<String> {
        let calendar = Calendar.current
        var keys = Set<String>()
        for offset in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else { continue }
            keys.insert(Self.dayKey(for: date))
        }
        return keys
    }

    private func mergeAppStats(
        from payload: [String: CloudAppStatsPayload]?,
        into totals: inout [String: AppStats]
    ) {
        guard let payload, !payload.isEmpty else { return }
        for (_, cloudApp) in payload {
            let bundleId = cloudApp.bundleId
            guard !bundleId.isEmpty else { continue }
            var total = totals[bundleId] ?? AppStats(bundleId: bundleId, displayName: cloudApp.displayName)
            if !cloudApp.displayName.isEmpty {
                total.displayName = cloudApp.displayName
            }
            total.keyPresses += cloudApp.keyPresses
            total.leftClicks += cloudApp.leftClicks
            total.rightClicks += cloudApp.rightClicks
            total.sideBackClicks += cloudApp.sideBackClicks
            total.sideForwardClicks += cloudApp.sideForwardClicks
            total.scrollDistance += cloudApp.scrollDistance
            totals[bundleId] = total
        }
    }

    private func todayStats(forDeviceId deviceId: String) -> DailyStats {
        if deviceId == localDeviceId {
            return StatsManager.shared.currentStats
        }
        let todayKey = Self.dayKey(for: Date())
        guard let record = remoteRecords.first(where: { $0.deviceId == deviceId && $0.date == todayKey }) else {
            return DailyStats()
        }
        return dailyStats(from: record.stats, date: Date())
    }

    private func dailyStats(from payload: CloudDailyStatsPayload, date: Date) -> DailyStats {
        var stats = DailyStats(date: date)
        stats.keyPresses = payload.keyPresses
        stats.keyPressCounts = payload.keyPressCounts ?? [:]
        stats.leftClicks = payload.leftClicks
        stats.rightClicks = payload.rightClicks
        stats.sideBackClicks = payload.sideBackClicks
        stats.sideForwardClicks = payload.sideForwardClicks
        stats.mouseDistance = payload.mouseDistance
        stats.scrollDistance = payload.scrollDistance
        stats.peakKPS = payload.peakKPS
        stats.peakCPS = payload.peakCPS
        return stats
    }

    private func remoteKeyboardHeatmapDateBounds(deviceId: String) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var earliestDate: Date?

        for record in remoteRecords where record.deviceId == deviceId {
            guard recordHasKeyboardHeatmapData(record) else { continue }
            guard let date = Self.date(fromDayKey: record.date) else { continue }
            let normalized = calendar.startOfDay(for: date)
            if normalized > today { continue }
            if let existing = earliestDate {
                if normalized < existing {
                    earliestDate = normalized
                }
            } else {
                earliestDate = normalized
            }
        }

        let start = earliestDate ?? today
        return (start: min(start, today), end: today)
    }

    private func mergedKeyboardHeatmapDateBounds() -> (start: Date, end: Date) {
        let localBounds = StatsManager.shared.keyboardHeatmapDateBounds()
        let calendar = Calendar.current
        let today = localBounds.end
        var start = localBounds.start

        for record in remoteRecords where record.deviceId != localDeviceId {
            guard recordHasKeyboardHeatmapData(record) else { continue }
            guard let date = Self.date(fromDayKey: record.date) else { continue }
            let normalized = calendar.startOfDay(for: date)
            if normalized > today { continue }
            start = min(start, normalized)
        }

        return (start: min(start, today), end: today)
    }

    private func mergedKeyboardHeatmapDay(for date: Date) -> StatsManager.KeyboardHeatmapDay {
        let localDay = StatsManager.shared.keyboardHeatmapDay(for: date)
        var mergedCounts = localDay.keyCounts
        var totalPresses = localDay.totalKeyPresses

        let dayKey = Self.dayKey(for: date)
        for record in remoteRecords where record.date == dayKey && record.deviceId != localDeviceId {
            guard let counts = record.stats.keyPressCounts else { continue }
            for (key, count) in counts {
                let normalized = max(0, count)
                guard normalized > 0 else { continue }
                mergedCounts[key, default: 0] += normalized
            }
            totalPresses += record.stats.keyPresses
        }

        return StatsManager.KeyboardHeatmapDay(
            date: date,
            totalKeyPresses: totalPresses,
            keyCounts: keyboardHeatmapCounts(from: mergedCounts)
        )
    }

    private func recordHasKeyboardHeatmapData(_ record: CloudStatsRecord) -> Bool {
        record.stats.keyPresses > 0 || !(record.stats.keyPressCounts?.isEmpty ?? true)
    }

    private func platformDisplayName(_ platform: String) -> String {
        switch platform.lowercased() {
        case "macos": return "macOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return platform.capitalized
        }
    }

    private func truncatedTabLabel(_ label: String, maxLength: Int = 14) -> String {
        guard label.count > maxLength else { return label }
        return String(label.prefix(max(1, maxLength - 1))) + "…"
    }

    private static func date(fromDayKey dayKey: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dayKey)
    }

    private func aggregateTodayStats() -> DailyStats {
        let summaries = deviceSummariesForToday()
        var aggregated = DailyStats()
        for summary in summaries {
            aggregated.keyPresses += summary.keyPresses
            aggregated.leftClicks += summary.leftClicks
            aggregated.rightClicks += summary.rightClicks
            aggregated.sideBackClicks += summary.sideBackClicks
            aggregated.sideForwardClicks += summary.sideForwardClicks
            aggregated.mouseDistance += summary.mouseDistance
            aggregated.scrollDistance += summary.scrollDistance
            aggregated.peakKPS = max(aggregated.peakKPS, summary.peakKPS)
            aggregated.peakCPS = max(aggregated.peakCPS, summary.peakCPS)
        }
        return aggregated
    }

    // MARK: - Private

    private func persistAuth(username: String, token: String, userId: String) {
        CloudSyncKeychain.saveToken(token)
        CloudSyncKeychain.saveUserId(userId)
        defaults.set(username, forKey: usernameKey)
    }

    private func authToken() throws -> String {
        guard let token = CloudSyncKeychain.loadToken() else {
            throw CloudSyncError.notAuthenticated
        }
        return token
    }

    private func ensureDeviceRegistered() async throws {
        guard let baseURL = normalizedServerURL() else { throw CloudSyncError.invalidServerURL }
        let token = try authToken()
        let deviceName = Host.current().localizedName ?? "Mac"
        _ = try await client.registerDevice(
            baseURL: baseURL,
            token: token,
            requestBody: CloudRegisterDeviceRequest(
                deviceId: localDeviceId,
                platform: "macos",
                deviceName: deviceName
            )
        )
    }

    private func uploadLocalStatsThrowing() async throws {
        guard isSyncEnabled else { return }
        guard let baseURL = normalizedServerURL() else { throw CloudSyncError.notConfigured }
        let token = try authToken()
        try await ensureDeviceRegistered()

        let snapshot = StatsManager.shared.statsSnapshotForSync()
        if !defaults.bool(forKey: initialBulkUploadedKey), snapshot.count > 1 {
            let dirtyRecords = snapshot.compactMap { dayKey, stats -> CloudBulkStatsRecord? in
                guard hasStatsChanged(dayKey: dayKey, stats: stats) else { return nil }
                return CloudBulkStatsRecord(
                    date: dayKey,
                    version: nextVersion(for: dayKey),
                    stats: makePayload(dayKey: dayKey, stats: stats)
                )
            }
            if !dirtyRecords.isEmpty {
                try await client.bulkUpsertStats(
                    baseURL: baseURL,
                    token: token,
                    requestBody: CloudBulkUpsertStatsRequest(deviceId: localDeviceId, records: dirtyRecords)
                )
                markUploaded(dirtyRecords, snapshot: snapshot)
            }
            defaults.set(true, forKey: initialBulkUploadedKey)
        } else {
            let todayKey = Self.dayKey(for: Date())
            guard let todayStats = snapshot[todayKey] else { return }
            guard hasStatsChanged(dayKey: todayKey, stats: todayStats) else { return }
            let version = nextVersion(for: todayKey)
            let payload = makePayload(dayKey: todayKey, stats: todayStats)
            try await client.upsertStats(
                baseURL: baseURL,
                token: token,
                requestBody: CloudUpsertStatsRequest(
                    deviceId: localDeviceId,
                    date: todayKey,
                    version: version,
                    stats: payload
                )
            )
            markUploaded(
                [CloudBulkStatsRecord(date: todayKey, version: version, stats: payload)],
                snapshot: [todayKey: todayStats]
            )
        }
    }

    private func pullRemoteStatsThrowing() async throws {
        guard let baseURL = normalizedServerURL() else { throw CloudSyncError.notConfigured }
        let token = try authToken()
        let fetchedDevices = try await client.listDevices(baseURL: baseURL, token: token)
        let fetchedRecords = try await client.listStats(baseURL: baseURL, token: token, from: nil, to: nil, deviceId: nil)
        await setRemoteData(devices: fetchedDevices, records: fetchedRecords)
    }

    private func makePayload(dayKey: String, stats: DailyStats) -> CloudDailyStatsPayload {
        let appStats = stats.appStats.mapValues { app in
            CloudAppStatsPayload(
                bundleId: app.bundleId,
                displayName: app.displayName,
                keyPresses: app.keyPresses,
                leftClicks: app.leftClicks,
                rightClicks: app.rightClicks,
                sideBackClicks: app.sideBackClicks,
                sideForwardClicks: app.sideForwardClicks,
                scrollDistance: app.scrollDistance
            )
        }
        return CloudDailyStatsPayload(
            date: dayKey,
            keyPresses: stats.keyPresses,
            keyPressCounts: stats.keyPressCounts.isEmpty ? nil : stats.keyPressCounts,
            leftClicks: stats.leftClicks,
            rightClicks: stats.rightClicks,
            sideBackClicks: stats.sideBackClicks,
            sideForwardClicks: stats.sideForwardClicks,
            mouseDistance: stats.mouseDistance,
            scrollDistance: stats.scrollDistance,
            peakKPS: stats.peakKPS,
            peakCPS: stats.peakCPS,
            appStats: appStats.isEmpty ? nil : appStats
        )
    }

    private func hasStatsChanged(dayKey: String, stats: DailyStats) -> Bool {
        let fingerprint = makeFingerprint(dayKey: dayKey, stats: stats)
        let stored = defaults.dictionary(forKey: lastUploadFingerprintsKey) as? [String: String] ?? [:]
        return stored[dayKey] != fingerprint
    }

    private func nextVersion(for dayKey: String) -> Int64 {
        let versions = defaults.dictionary(forKey: lastUploadVersionsKey) as? [String: Int64] ?? [:]
        return (versions[dayKey] ?? 0) + 1
    }

    private func makeFingerprint(dayKey: String, stats: DailyStats) -> String {
        [
            dayKey,
            String(stats.keyPresses),
            String(stats.leftClicks),
            String(stats.rightClicks),
            String(stats.sideBackClicks),
            String(stats.sideForwardClicks),
            String(stats.mouseDistance),
            String(stats.scrollDistance),
            String(stats.peakKPS),
            String(stats.peakCPS)
        ].joined(separator: "|")
    }

    private func markUploaded(_ records: [CloudBulkStatsRecord], snapshot: [String: DailyStats]) {
        var versions = defaults.dictionary(forKey: lastUploadVersionsKey) as? [String: Int64] ?? [:]
        var fingerprints = defaults.dictionary(forKey: lastUploadFingerprintsKey) as? [String: String] ?? [:]
        for record in records {
            versions[record.date] = record.version
            if let stats = snapshot[record.date] {
                fingerprints[record.date] = makeFingerprint(dayKey: record.date, stats: stats)
            }
        }
        defaults.set(versions, forKey: lastUploadVersionsKey)
        defaults.set(fingerprints, forKey: lastUploadFingerprintsKey)
    }

    @MainActor
    private func setStatus(_ newStatus: CloudSyncStatus) {
        status = newStatus
        notifyStateChanged()
    }

    @MainActor
    private func setRemoteData(devices: [CloudDevice], records: [CloudStatsRecord]) {
        self.devices = devices
        self.remoteRecords = records
        notifyStateChanged()
    }

    @MainActor
    private func clearSessionState() {
        remoteRecords = []
        devices = []
        status = .idle
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChanged?()
            NotificationCenter.default.post(name: .cloudSyncStateDidChange, object: self)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }
}
