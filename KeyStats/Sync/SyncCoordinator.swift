import Cocoa
import CryptoKit

struct SyncPairingSessionDisplay {
    let code: String
    let expiresAt: Date
}

struct SyncPairingSafetyDisplay {
    let safetyCode: String
    let deviceName: String
}

struct SyncRecoveryReplacementOption {
    let deviceId: String
    let displayName: String
    let platform: String
}

enum SyncCoordinatorError: LocalizedError {
    case serviceNotConfigured
    case alreadyConfigured
    case notConfigured
    case singleDevice
    case coolingDown(Date)
    case dailyLimit
    case syncInProgress
    case pairingNotStarted
    case pairingPending
    case pairingExpired
    case pairingNotConfirmed
    case invalidPairingCode
    case maximumDevices
    case bootstrapTooLarge
    case revisionExhausted

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured: return NSLocalizedString("sync.error.serviceNotConfigured", comment: "")
        case .alreadyConfigured: return NSLocalizedString("sync.error.alreadyConfigured", comment: "")
        case .notConfigured: return NSLocalizedString("sync.error.notConfigured", comment: "")
        case .singleDevice: return NSLocalizedString("sync.error.singleDevice", comment: "")
        case .coolingDown: return NSLocalizedString("sync.error.coolingDown", comment: "")
        case .dailyLimit: return NSLocalizedString("sync.error.dailyLimit", comment: "")
        case .syncInProgress: return NSLocalizedString("sync.error.inProgress", comment: "")
        case .pairingNotStarted: return NSLocalizedString("sync.error.pairingNotStarted", comment: "")
        case .pairingPending: return NSLocalizedString("sync.error.pairingPending", comment: "")
        case .pairingExpired: return NSLocalizedString("sync.error.pairingExpired", comment: "")
        case .pairingNotConfirmed: return NSLocalizedString("sync.error.pairingNotConfirmed", comment: "")
        case .invalidPairingCode: return NSLocalizedString("sync.error.invalidPairingCode", comment: "")
        case .maximumDevices: return NSLocalizedString("sync.error.maximumDevices", comment: "")
        case .bootstrapTooLarge: return NSLocalizedString("sync.error.bootstrapTooLarge", comment: "")
        case .revisionExhausted: return NSLocalizedString("sync.error.revisionExhausted", comment: "")
        }
    }
}

final class SyncCoordinator {
    static let shared = SyncCoordinator()

    private struct StoredJoiningPairingState: Codable {
        let privateKey: Data
        let sessionId: String
        let completionToken: String
        let deviceId: String
        let expiresAt: Date
        var approvalResponse: CompletePairingSessionResponseV1?
    }

    private struct JoiningPairingState {
        let keyPair: SyncPairingKeyPair
        let sessionId: String
        let completionToken: String
        let deviceId: String
        let expiresAt: Date
        var approvalResponse: CompletePairingSessionResponseV1?
    }

    private struct ApprovingPairingState {
        let keyPair: SyncPairingKeyPair
        let sessionId: String
        let joiningDeviceId: String
        let joiningPublicKey: String
        let newDeviceToken: String
        let safetyCode: String
        let expiresAt: Date
    }

    private let stateStore: SyncStateStore
    private let cache: RemoteShardCache
    private let credentialStore: SyncCredentialStore
    private let buildServiceURL: URL?
    private var serviceEnvironmentMismatch = false
    private var automaticTimer: Timer?
    private var stateRefreshTimer: Timer?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var pairingRefreshTask: Task<Void, Never>?
    private var joiningPairing: JoiningPairingState?
    private var approvingPairing: ApprovingPairingState?
    private(set) var isSyncing = false
    private(set) var syncProgress: SyncProgress?
    private var isRefreshingState = false
    private(set) var lastError: Error?
    private(set) var state: SyncPersistentState

    var isConfigured: Bool { state.isConfigured }
    var blocksLegacyImport: Bool { state.isConfigured || state.needsRepair }
    var isServiceConfigured: Bool { configuredServiceURL() != nil }
    var canRetryBootstrap: Bool { state.isConfigured && state.needsBootstrap && !state.needsRepair }
    var hasUnconfirmedCreate: Bool {
        state.pendingProvisioning?.kind == .create
            && state.pendingProvisioning?.recoveryCodeConfirmed == false
    }
    var hasPendingRecovery: Bool { state.pendingProvisioning?.kind == .recovery }
    var availability: SyncAvailability { SyncSchedulePolicy.availability(state: state) }

    init(
        stateStore: SyncStateStore = .shared,
        cache: RemoteShardCache = .shared,
        credentialStore: SyncCredentialStore = .shared,
        configuredServiceURL: URL? = SyncConfiguration.serverBaseURL
    ) {
        self.stateStore = stateStore
        self.cache = cache
        self.credentialStore = credentialStore
        buildServiceURL = configuredServiceURL
        state = stateStore.load()
        if stateStore.loadError != nil {
            state.deviceId = SyncInstallationIdentity.current()
            state.needsRepair = true
            return
        }
        state.deviceId = SyncInstallationIdentity.current(
            preferred: state.isConfigured ? state.deviceId : nil
        )
        if let configuredServiceURL {
            serviceEnvironmentMismatch = !SyncConfiguration.bind(
                configuredServiceURL: configuredServiceURL,
                to: &state
            )
        }
        if cache.loadError != nil {
            state.cursor = 0
            state.needsRepair = true
        }
        if state.isConfigured {
            do {
                guard let vaultId = state.vaultId else { throw SyncCryptoError.missingCredentials }
                _ = try credentialStore.credentials(vaultId: vaultId, deviceId: state.deviceId)
            } catch {
                state.needsRepair = true
            }
        }
        restorePendingPairingIfPossible()
        try? stateStore.save(state)
    }

    deinit {
        automaticTimer?.invalidate()
        stateRefreshTimer?.invalidate()
        pairingRefreshTask?.cancel()
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }
    }

    func start() {
        assert(Thread.isMainThread)
        guard appDidBecomeActiveObserver == nil else { return }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshCloudStateIfNeeded()
                self.scheduleIfNeeded()
            }
        }
        if state.pendingVaultDeletion {
            Task { @MainActor [weak self] in try? await self?.resumePendingVaultDeletion() }
        } else if let pending = state.pendingProvisioning,
                  pending.kind != .create || pending.recoveryCodeConfirmed {
            Task { @MainActor [weak self] in try? await self?.finishPendingProvisioning() }
        } else if state.needsBootstrap {
            Task { @MainActor [weak self] in
                try? await self?.retryBootstrapWork(reason: .bootstrap)
            }
        } else {
            scheduleIfNeeded()
            Task { @MainActor [weak self] in await self?.refreshCloudStateIfNeeded(force: true) }
        }
    }

    @MainActor
    func prepareSyncGroup() throws -> String {
        guard !state.isConfigured, !state.needsRepair else { throw SyncCoordinatorError.alreadyConfigured }
        let seed = try SyncCrypto.makeRecoverySeed()
        let recoveryCode = try SyncCrypto.recoveryCode(from: seed)
        let vaultId = UUID().uuidString.lowercased()
        let deviceId = SyncInstallationIdentity.current()
        let deviceToken = try SyncCrypto.makeDeviceToken(deviceId: deviceId)
        let profile = try SyncCrypto.encryptDeviceProfile(
            SyncDeviceProfileV1(displayName: state.displayName, platform: "macos"),
            vaultId: vaultId,
            deviceId: deviceId,
            seed: seed
        )
        try credentialStore.saveCredentials(SyncStoredCredentials(
            vaultId: vaultId,
            deviceId: deviceId,
            recoverySeed: seed,
            deviceToken: deviceToken
        ))
        try cache.clear()
        state.vaultId = vaultId
        state.deviceId = deviceId
        state.activeDeviceCount = 1
        state.cursor = 0
        state.needsRepair = false
        state.needsBootstrap = true
        state.bootstrapUploadCompleted = false
        state.pendingProvisioning = SyncPendingProvisioning(
            kind: .create,
            encryptedDeviceProfile: profile,
            replaceDeviceId: nil,
            recoveryCodeConfirmed: false,
            reconcileAcceptedRecordsBeforePush: false
        )
        state.pendingEncryptedDeviceProfile = profile
        state.revisions.removeAll()
        state.archivedRevisions.removeAll()
        state.pendingRecords.removeAll()
        state.devices = [currentDevice()]
        try persistAndNotify()
        return SyncCrypto.formattedRecoveryCode(recoveryCode)
    }

    @MainActor
    func confirmAndCreateSyncGroup() async throws {
        guard var pending = state.pendingProvisioning, pending.kind == .create else {
            throw SyncCoordinatorError.notConfigured
        }
        pending.recoveryCodeConfirmed = true
        state.pendingProvisioning = pending
        try persistAndNotify()
        try await finishPendingProvisioning()
    }

    @MainActor
    func cancelPreparedSyncGroup() throws {
        guard let pending = state.pendingProvisioning,
              pending.kind == .create,
              !pending.recoveryCodeConfirmed else { return }
        try clearLocalConfiguration(rotateIdentity: false)
    }

    @MainActor
    func recover(recoveryCode: String) async throws {
        let seed = try SyncCrypto.recoverySeed(from: recoveryCode)
        let pendingRecoveryIsProvisional = state.pendingProvisioning?.kind == .recovery
            && state.pendingProvisioning?.reconcileAcceptedRecordsBeforePush == false
        let knownDeviceId: String? = state.needsRepair && !pendingRecoveryIsProvisional
            ? state.deviceId
            : SyncInstallationIdentity.replacementCandidate
        let deviceId = knownDeviceId ?? SyncInstallationIdentity.current()
        let deviceToken = try SyncCrypto.makeDeviceToken(deviceId: deviceId)
        let provisionalVaultId = state.vaultId ?? "pending-recovery"
        try credentialStore.saveCredentials(SyncStoredCredentials(
            vaultId: provisionalVaultId,
            deviceId: deviceId,
            recoverySeed: seed,
            deviceToken: deviceToken
        ))
        state.vaultId = provisionalVaultId
        state.deviceId = deviceId
        state.activeDeviceCount = max(1, state.activeDeviceCount)
        state.cursor = 0
        state.needsRepair = false
        state.needsBootstrap = true
        state.bootstrapUploadCompleted = false
        state.pendingProvisioning = SyncPendingProvisioning(
            kind: .recovery,
            encryptedDeviceProfile: nil,
            replaceDeviceId: knownDeviceId,
            recoveryCodeConfirmed: true,
            reconcileAcceptedRecordsBeforePush: knownDeviceId != nil
        )
        if knownDeviceId == nil {
            state.revisions.removeAll()
            state.archivedRevisions.removeAll()
            state.pendingRecords.removeAll()
        }
        state.devices = [currentDevice()]
        try persistAndNotify()
        try await finishPendingProvisioning()
    }

    func recoveryReplacementOptions(
        vaultId: String?,
        devices: [SyncEncryptedDeviceV1]
    ) throws -> [SyncRecoveryReplacementOption] {
        guard let vaultId, !vaultId.isEmpty,
              devices.count == SyncConstants.maximumActiveDevices else {
            throw SyncTransportError.invalidResponse
        }
        let seed = try credentialStore.credentials(deviceId: state.deviceId).recoverySeed
        return devices.map { device in
            let profile = device.encryptedDeviceProfile.flatMap {
                try? SyncCrypto.decryptDeviceProfile(
                    $0,
                    vaultId: vaultId,
                    deviceId: device.deviceId,
                    seed: seed
                )
            }
            return SyncRecoveryReplacementOption(
                deviceId: device.deviceId,
                displayName: profile?.displayName
                    ?? String(format: NSLocalizedString("sync.device.generic", comment: ""), String(device.deviceId.prefix(6))),
                platform: profile?.platform ?? ""
            )
        }
    }

    @MainActor
    func retryRecovery(replacing option: SyncRecoveryReplacementOption, vaultId: String) async throws {
        guard var pending = state.pendingProvisioning, pending.kind == .recovery,
              UUID(uuidString: option.deviceId) != nil,
              !vaultId.isEmpty else {
            throw SyncCoordinatorError.notConfigured
        }
        let existing = try credentialStore.credentials(deviceId: state.deviceId)
        let replacementToken = try SyncCrypto.makeDeviceToken(deviceId: option.deviceId)
        try credentialStore.saveCredentials(SyncStoredCredentials(
            vaultId: vaultId,
            deviceId: option.deviceId,
            recoverySeed: existing.recoverySeed,
            deviceToken: replacementToken
        ))
        pending.replaceDeviceId = option.deviceId
        pending.reconcileAcceptedRecordsBeforePush = true
        state.pendingProvisioning = pending
        state.vaultId = vaultId
        state.deviceId = option.deviceId
        state.cursor = 0
        state.revisions.removeAll()
        state.archivedRevisions.removeAll()
        state.pendingRecords.removeAll()
        state.devices = [currentDevice()]
        try persistAndNotify()
        try await finishPendingProvisioning()
    }

    @MainActor
    func cancelPendingRecovery() throws {
        guard let pending = state.pendingProvisioning, pending.kind == .recovery else { return }
        try clearLocalConfiguration(rotateIdentity: pending.reconcileAcceptedRecordsBeforePush)
        AppDelegate.trackClick("sync_recover_cancel")
    }

    @MainActor
    private func finishPendingProvisioning() async throws {
        guard let pending = state.pendingProvisioning else { throw SyncCoordinatorError.notConfigured }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        guard pending.kind != .create || pending.recoveryCodeConfirmed else {
            throw SyncCoordinatorError.notConfigured
        }
        var credentials = try credentialStore.credentials(deviceId: state.deviceId)
        let transport = try makeTransport()

        isSyncing = true
        lastError = nil
        notifyStateChanged()
        do {
            switch pending.kind {
            case .create:
                guard let vaultId = state.vaultId,
                      let profile = pending.encryptedDeviceProfile else {
                    throw SyncTransportError.invalidResponse
                }
                let response = try await transport.createVault(CreateVaultRequestV1(
                    vaultId: vaultId,
                    deviceId: state.deviceId,
                    deviceToken: credentials.deviceToken,
                    recoveryAuthToken: SyncCrypto.recoveryCredential(seed: credentials.recoverySeed),
                    encryptedDeviceProfile: profile
                ))
                guard response.vaultId == vaultId,
                      response.deviceId == state.deviceId,
                      response.deviceToken == credentials.deviceToken,
                      response.activeDeviceCount == 1 else {
                    throw SyncTransportError.invalidResponse
                }
                state.activeDeviceCount = response.activeDeviceCount
                state.pendingProvisioning = nil
                SyncInstallationIdentity.clearReplacementCandidate()
                try persistAndNotify()

            case .recovery:
                var recoveryPending = pending
                let response: RecoverVaultResponseV1
                do {
                    response = try await transport.recover(RecoverVaultRequestV1(
                        recoveryAuthToken: SyncCrypto.recoveryCredential(seed: credentials.recoverySeed),
                        deviceId: state.deviceId,
                        deviceToken: credentials.deviceToken,
                        replaceDeviceId: recoveryPending.replaceDeviceId
                    ))
                } catch SyncTransportError.replacementDeviceNotFound where recoveryPending.replaceDeviceId != nil {
                    // Only this explicit server result proves the candidate is not
                    // a shard in the recovered vault. Generic conflicts can be a
                    // concurrent recovery and must not create a duplicate device.
                    let freshDeviceId = SyncInstallationIdentity.rotate()
                    SyncInstallationIdentity.clearReplacementCandidate()
                    let freshCredentials = SyncStoredCredentials(
                        vaultId: "pending-recovery",
                        deviceId: freshDeviceId,
                        recoverySeed: credentials.recoverySeed,
                        deviceToken: try SyncCrypto.makeDeviceToken(deviceId: freshDeviceId)
                    )
                    try credentialStore.saveCredentials(freshCredentials)
                    credentials = freshCredentials
                    recoveryPending.replaceDeviceId = nil
                    recoveryPending.reconcileAcceptedRecordsBeforePush = false
                    recoveryPending.encryptedDeviceProfile = nil
                    state.vaultId = "pending-recovery"
                    state.deviceId = freshDeviceId
                    state.cursor = 0
                    state.needsRepair = false
                    state.revisions.removeAll()
                    state.archivedRevisions.removeAll()
                    state.pendingRecords.removeAll()
                    state.pendingEncryptedDeviceProfile = nil
                    state.pendingProvisioning = recoveryPending
                    state.devices = [currentDevice()]
                    try cache.clear()
                    try persistAndNotify()
                    response = try await transport.recover(RecoverVaultRequestV1(
                        recoveryAuthToken: SyncCrypto.recoveryCredential(seed: credentials.recoverySeed),
                        deviceId: state.deviceId,
                        deviceToken: credentials.deviceToken,
                        replaceDeviceId: nil
                    ))
                }
                guard response.deviceId == state.deviceId,
                      response.deviceToken == credentials.deviceToken,
                      !response.vaultId.isEmpty,
                      (1...SyncConstants.maximumActiveDevices).contains(response.activeDeviceCount),
                      response.cursor >= 0 else {
                    throw SyncTransportError.invalidResponse
                }
                let bound = SyncStoredCredentials(
                    vaultId: response.vaultId,
                    deviceId: state.deviceId,
                    recoverySeed: credentials.recoverySeed,
                    deviceToken: credentials.deviceToken
                )
                try credentialStore.saveCredentials(bound)
                state.vaultId = response.vaultId
                state.activeDeviceCount = response.activeDeviceCount
                state.needsRepair = false
                _ = SyncInstallationIdentity.current(preferred: state.deviceId)
                let profile = try SyncCrypto.encryptDeviceProfile(
                    SyncDeviceProfileV1(displayName: state.displayName, platform: "macos"),
                    vaultId: response.vaultId,
                    deviceId: state.deviceId,
                    seed: credentials.recoverySeed
                )
                state.pendingEncryptedDeviceProfile = profile
                state.pendingProvisioning?.encryptedDeviceProfile = profile
                try persistAndNotify()
                if recoveryPending.reconcileAcceptedRecordsBeforePush {
                    try await reconcileAcceptedRecords(
                        currentSnapshot: response.currentSnapshot,
                        credentials: bound
                    )
                } else {
                    try cache.clear()
                    state.cursor = 0
                }
                state.pendingProvisioning = nil
                SyncInstallationIdentity.clearReplacementCandidate()
                try persistAndNotify()

            case .pairing:
                guard let joiningPairing,
                      let profile = pending.encryptedDeviceProfile else {
                    throw SyncCoordinatorError.pairingNotStarted
                }
                let completed = try await transport.completePairingSession(
                    id: joiningPairing.sessionId,
                    request: CompletePairingSessionRequestV1(
                        completionToken: joiningPairing.completionToken,
                        encryptedDeviceProfile: profile
                    )
                )
                let activeDeviceCount = completed.activeDeviceCount ?? 2
                guard !completed.pending,
                      !completed.requiresProfile,
                      (1...SyncConstants.maximumActiveDevices).contains(activeDeviceCount) else {
                    throw SyncTransportError.invalidResponse
                }
                state.activeDeviceCount = activeDeviceCount
                if pending.reconcileAcceptedRecordsBeforePush {
                    let cloudState = try await transport.state(bearerToken: credentials.deviceToken)
                    try validateAndApplyCloudState(cloudState, credentials: credentials, applyCurrentSnapshots: false)
                    try await reconcileAcceptedRecords(
                        currentSnapshot: cloudState.currentSnapshots.first { $0.deviceId == state.deviceId },
                        credentials: credentials
                    )
                }
                state.pendingProvisioning = nil
                self.joiningPairing = nil
                try persistAndNotify()
                try credentialStore.clearPendingPairing()
            }
        } catch {
            lastError = error
            if pending.kind == .recovery,
               requiresRepair(after: error) {
                // Keep local statistics and the stable device identity, but
                // reopen the recovery/pairing entry points so a mistyped or
                // stale recovery code cannot strand the installation in an
                // unmanageable provisional configuration.
                enterRepairMode()
            }
            try? stateStore.save(state)
            isSyncing = false
            notifyStateChanged()
            throw error
        }
        isSyncing = false
        notifyStateChanged()

        let reason: SyncReason = pending.kind == .create ? .bootstrap : pending.kind == .recovery ? .recovery : .pairing
        try await performSync(
            reason: reason,
            bypassOrdinaryGating: true,
            encryptedDeviceProfile: state.pendingEncryptedDeviceProfile
        )
        AppDelegate.trackClick(pending.kind == .create ? "sync_create" : pending.kind == .recovery ? "sync_recover" : "sync_pair_complete")
    }

    @MainActor
    private func reconcileAcceptedRecords(
        currentSnapshot: EncryptedSyncRecordV1?,
        credentials: SyncStoredCredentials
    ) async throws {
        guard let vaultId = state.vaultId else { throw SyncCoordinatorError.notConfigured }
        if state.cursor == 0 {
            try cache.clear()
        }
        if let currentSnapshot {
            try reconcileOwnRecord(
                currentSnapshot,
                archived: false,
                vaultId: vaultId,
                seed: credentials.recoverySeed
            )
        }

        var pageCount = 0
        var hasMore = true
        while hasMore, pageCount < SyncConstants.maximumHistoryPagesPerAttempt {
            let previousCursor = state.cursor
            let page = try await makeTransport().history(
                cursor: state.cursor,
                bearerToken: credentials.deviceToken
            )
            guard page.cursor >= previousCursor,
                  !page.hasMore || page.cursor > previousCursor else {
                throw SyncTransportError.invalidResponse
            }
            for change in page.changes {
                if change.tombstone {
                    try cache.applyTombstone(recordId: change.recordId)
                    continue
                }
                guard let record = change.record, record.recordId == change.recordId else {
                    throw SyncTransportError.invalidResponse
                }
                if record.deviceId == state.deviceId {
                    try reconcileOwnRecord(record, archived: true, vaultId: vaultId, seed: credentials.recoverySeed)
                } else {
                    let snapshot = try SyncCrypto.decrypt(record: record, vaultId: vaultId, seed: credentials.recoverySeed)
                    _ = try cache.apply(recordId: record.recordId, snapshot: snapshot, currentDeviceId: state.deviceId)
                }
            }
            state.cursor = page.cursor
            try stateStore.save(state)
            hasMore = page.hasMore
            pageCount += 1
        }
        guard !hasMore else { throw SyncTransportError.invalidResponse }
    }

    private func reconcileOwnRecord(
        _ record: EncryptedSyncRecordV1,
        archived: Bool,
        vaultId: String,
        seed: Data
    ) throws {
        guard record.deviceId == state.deviceId else { return }
        let snapshot = try SyncCrypto.decrypt(record: record, vaultId: vaultId, seed: seed)
        let content = try CoreDaySnapshotV1(
            deviceId: snapshot.deviceId,
            localDay: snapshot.localDay,
            revision: 0,
            keyPresses: snapshot.keyPresses,
            keyPressCounts: snapshot.keyPressCounts,
            clicks: snapshot.clicks
        ).validated()
        let contentHash = try SyncCrypto.contentHash(content)
        let previousRevision = state.revisions[snapshot.localDay]?.revision ?? 0
        guard record.revision >= previousRevision else { return }
        state.revisions[snapshot.localDay] = SyncRevisionState(
            revision: record.revision,
            contentHash: contentHash
        )
        state.pendingRecords[snapshot.localDay] = record
        if archived {
            state.archivedRevisions[snapshot.localDay] = max(
                state.archivedRevisions[snapshot.localDay] ?? 0,
                record.revision
            )
        }
    }

    @MainActor
    func beginPairing() async throws -> SyncPairingSessionDisplay {
        guard !state.isConfigured || state.needsRepair else { throw SyncCoordinatorError.alreadyConfigured }
        let transport = try makeTransport()
        let keyPair = SyncPairingKeyPair()
        let deviceId = SyncInstallationIdentity.current(
            preferred: state.needsRepair ? state.deviceId : nil
        )
        let response = try await transport.createPairingSession(CreatePairingSessionRequestV1(
            deviceId: deviceId,
            joiningPublicKey: keyPair.publicKey
        ))
        state.deviceId = deviceId
        joiningPairing = JoiningPairingState(
            keyPair: keyPair,
            sessionId: response.sessionId,
            completionToken: response.completionToken,
            deviceId: deviceId,
            expiresAt: response.expiresAt,
            approvalResponse: nil
        )
        try persistJoiningPairing()
        try stateStore.save(state)
        AppDelegate.trackClick("sync_pair_start")
        return SyncPairingSessionDisplay(code: response.code, expiresAt: response.expiresAt)
    }

    @MainActor
    func joinPairing(code: String) async throws -> SyncPairingSafetyDisplay {
        guard state.isConfigured, !state.needsRepair else { throw SyncCoordinatorError.notConfigured }
        guard state.activeDeviceCount < SyncConstants.maximumActiveDevices else {
            throw SyncCoordinatorError.maximumDevices
        }
        let transport = try makeTransport()
        let token: String
        do {
            token = try boundCredentials().deviceToken
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        let keyPair = SyncPairingKeyPair()
        let response: JoinPairingSessionResponseV1
        do {
            response = try await transport.joinPairingSession(
                code: code.filter(\.isNumber),
                request: JoinPairingSessionRequestV1(approvingPublicKey: keyPair.publicKey),
                bearerToken: token
            )
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        guard response.expiresAt > Date() else { throw SyncCoordinatorError.pairingExpired }
        let newToken = try SyncCrypto.makeDeviceToken(deviceId: response.joiningDeviceId)
        let safetyCode = try SyncCrypto.pairingSafetyCode(
            ownKeyPair: keyPair,
            peerPublicKey: response.joiningPublicKey,
            sessionId: response.sessionId
        )
        approvingPairing = ApprovingPairingState(
            keyPair: keyPair,
            sessionId: response.sessionId,
            joiningDeviceId: response.joiningDeviceId,
            joiningPublicKey: response.joiningPublicKey,
            newDeviceToken: newToken,
            safetyCode: safetyCode,
            expiresAt: response.expiresAt
        )
        return SyncPairingSafetyDisplay(
            safetyCode: safetyCode,
            deviceName: NSLocalizedString("sync.device.new", comment: "")
        )
    }

    @MainActor
    func approvePairing(safetyCodeConfirmed: Bool) async throws {
        guard safetyCodeConfirmed else { throw SyncCoordinatorError.pairingNotConfirmed }
        guard let pending = approvingPairing,
              let vaultId = state.vaultId else { throw SyncCoordinatorError.pairingNotStarted }
        let credentials: SyncStoredCredentials
        do {
            credentials = try boundCredentials()
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        let seed = credentials.recoverySeed
        let grant = SyncPairingGrant(
            vaultId: vaultId,
            recoverySeed: seed.base64EncodedString(),
            deviceToken: pending.newDeviceToken
        )
        let encrypted = try SyncCrypto.encryptPairingGrant(
            grant,
            ownKeyPair: pending.keyPair,
            peerPublicKey: pending.joiningPublicKey,
            sessionId: pending.sessionId
        )
        do {
            try await makeTransport().approvePairingSession(
                id: pending.sessionId,
                request: ApprovePairingSessionRequestV1(
                    approvingPublicKey: pending.keyPair.publicKey,
                    encryptedGrant: encrypted,
                    newDeviceToken: pending.newDeviceToken
                ),
                bearerToken: credentials.deviceToken
            )
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        if !state.devices.contains(where: { $0.deviceId == pending.joiningDeviceId }) {
            state.devices.append(SyncDevice(
                deviceId: pending.joiningDeviceId,
                displayName: String(format: NSLocalizedString("sync.device.generic", comment: ""), String(pending.joiningDeviceId.prefix(6))),
                platform: "",
                lastSyncAt: nil,
                isCurrent: false,
                isRevoked: false
            ))
        }
        approvingPairing = nil
        try persistAndNotify()
        scheduleApproverPairingRefresh(until: pending.expiresAt)
        AppDelegate.trackClick("sync_pair_approve")
    }

    @MainActor
    func fetchPairingApproval() async throws -> SyncPairingSafetyDisplay {
        guard var pending = joiningPairing else { throw SyncCoordinatorError.pairingNotStarted }
        guard pending.expiresAt > Date() else { throw SyncCoordinatorError.pairingExpired }
        let response = try await makeTransport().completePairingSession(
            id: pending.sessionId,
            request: CompletePairingSessionRequestV1(
                completionToken: pending.completionToken,
                encryptedDeviceProfile: nil
            )
        )
        if response.pending { throw SyncCoordinatorError.pairingPending }
        guard let peerKey = response.approvingPublicKey,
              response.encryptedGrant != nil else { throw SyncTransportError.invalidResponse }
        pending.approvalResponse = response
        joiningPairing = pending
        try persistJoiningPairing()
        let safetyCode = try SyncCrypto.pairingSafetyCode(
            ownKeyPair: pending.keyPair,
            peerPublicKey: peerKey,
            sessionId: pending.sessionId
        )
        return SyncPairingSafetyDisplay(
            safetyCode: safetyCode,
            deviceName: NSLocalizedString("sync.device.existing", comment: "")
        )
    }

    @MainActor
    func confirmPairing(safetyCodeConfirmed: Bool) async throws {
        guard safetyCodeConfirmed else { throw SyncCoordinatorError.pairingNotConfirmed }
        guard let pending = joiningPairing,
              let approval = pending.approvalResponse,
              let peerKey = approval.approvingPublicKey,
              let envelope = approval.encryptedGrant else {
            throw SyncCoordinatorError.pairingNotStarted
        }
        let grant = try SyncCrypto.decryptPairingGrant(
            envelope,
            ownKeyPair: pending.keyPair,
            peerPublicKey: peerKey,
            sessionId: pending.sessionId
        )
        guard let seed = Data(base64Encoded: grant.recoverySeed), seed.count == 16,
              let deviceToken = grant.deviceToken,
              deviceToken.hasPrefix("\(pending.deviceId).") else {
            throw SyncValidationError.authenticationFailed
        }
        let profile = try SyncCrypto.encryptDeviceProfile(
            SyncDeviceProfileV1(displayName: state.displayName, platform: "macos"),
            vaultId: grant.vaultId,
            deviceId: pending.deviceId,
            seed: seed
        )
        guard !grant.vaultId.isEmpty else {
            throw SyncTransportError.invalidResponse
        }
        let isIdentityTakeover = approval.replacedExistingDevice == true
        try credentialStore.saveCredentials(SyncStoredCredentials(
            vaultId: grant.vaultId,
            deviceId: pending.deviceId,
            recoverySeed: seed,
            deviceToken: deviceToken
        ))
        if !isIdentityTakeover {
            try cache.clear()
            state.revisions.removeAll()
            state.archivedRevisions.removeAll()
            state.pendingRecords.removeAll()
        }
        state.vaultId = grant.vaultId
        state.deviceId = pending.deviceId
        _ = SyncInstallationIdentity.current(preferred: pending.deviceId)
        state.activeDeviceCount = max(1, state.activeDeviceCount)
        state.cursor = 0
        state.needsRepair = false
        state.needsBootstrap = true
        state.bootstrapUploadCompleted = false
        state.devices = [currentDevice()]
        state.pendingEncryptedDeviceProfile = profile
        state.pendingProvisioning = SyncPendingProvisioning(
            kind: .pairing,
            encryptedDeviceProfile: profile,
            replaceDeviceId: isIdentityTakeover ? pending.deviceId : nil,
            recoveryCodeConfirmed: true,
            reconcileAcceptedRecordsBeforePush: isIdentityTakeover
        )
        try persistAndNotify()
        try await finishPendingProvisioning()
    }

    @MainActor
    func manualSync() async throws {
        try await performSync(reason: .manual, bypassOrdinaryGating: false)
        AppDelegate.trackClick("sync_manual")
    }

    @MainActor
    func retryBootstrap() async throws {
        guard canRetryBootstrap else { throw SyncCoordinatorError.notConfigured }
        try await retryBootstrapWork(reason: .bootstrap)
        AppDelegate.trackClick("sync_bootstrap_retry")
    }

    func recoveryCodeForDisplay() throws -> String {
        let code = try SyncCrypto.recoveryCode(from: boundCredentials().recoverySeed)
        return SyncCrypto.formattedRecoveryCode(code)
    }

    @MainActor
    func revokeDevice(deviceId: String) async throws {
        guard state.isConfigured else { throw SyncCoordinatorError.notConfigured }
        guard deviceId != state.deviceId else {
            try await leaveSync()
            return
        }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        isSyncing = true
        notifyStateChanged()
        defer {
            isSyncing = false
            notifyStateChanged()
        }
        do {
            try await makeTransport().deleteDevice(
                deviceId: deviceId,
                bearerToken: try boundCredentials().deviceToken
            )
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        state.devices.removeAll { $0.deviceId == deviceId }
        state.activeDeviceCount = max(1, state.activeDeviceCount - 1)
        try persistAndNotify()
        scheduleIfNeeded()
        AppDelegate.trackClick("sync_revoke")
    }

    @MainActor
    func leaveSync() async throws {
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        isSyncing = true
        notifyStateChanged()
        defer {
            isSyncing = false
            notifyStateChanged()
        }
        if state.isConfigured, !state.needsRepair {
            do {
                try await makeTransport().deleteDevice(
                    deviceId: state.deviceId,
                    bearerToken: try boundCredentials().deviceToken
                )
            } catch {
                if requiresRepair(after: error) { enterRepairMode() }
                throw error
            }
        }
        try clearLocalConfiguration()
        AppDelegate.trackClick("sync_leave")
    }

    /// Clears an unusable local sync binding without touching writable local
    /// statistics. The previous installation identity remains a recovery
    /// candidate so a later repair can reclaim the same cloud shard.
    @MainActor
    func forgetLocalSyncAfterRepair() throws {
        guard state.needsRepair else { throw SyncCoordinatorError.notConfigured }
        let pendingRecoveryIsProvisional = state.pendingProvisioning?.kind == .recovery
            && state.pendingProvisioning?.reconcileAcceptedRecordsBeforePush == false
        try clearLocalConfiguration(rotateIdentity: !pendingRecoveryIsProvisional)
        AppDelegate.trackClick("sync_forget_local")
    }

    @MainActor
    func deleteVault() async throws {
        guard state.isConfigured else { throw SyncCoordinatorError.notConfigured }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        state.pendingVaultDeletion = true
        try persistAndNotify()
        try await resumePendingVaultDeletion()
        AppDelegate.trackClick("sync_delete")
    }

    @MainActor
    private func resumePendingVaultDeletion() async throws {
        guard state.isConfigured, state.pendingVaultDeletion else {
            throw SyncCoordinatorError.notConfigured
        }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        isSyncing = true
        notifyStateChanged()
        defer {
            isSyncing = false
            notifyStateChanged()
        }
        do {
            try await makeTransport().deleteVault(bearerToken: try boundCredentials().deviceToken)
        } catch {
            if requiresRepair(after: error) { enterRepairMode() }
            throw error
        }
        try clearLocalConfiguration()
    }

    // MARK: - Synchronization

    @MainActor
    private func performSync(
        reason: SyncReason,
        bypassOrdinaryGating: Bool,
        encryptedDeviceProfile: SyncEncryptedGrant? = nil
    ) async throws {
        guard state.isConfigured, !state.needsRepair else { throw SyncCoordinatorError.notConfigured }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        if !bypassOrdinaryGating {
            switch SyncSchedulePolicy.availability(state: state) {
            case .notConfigured: throw SyncCoordinatorError.notConfigured
            case .singleDevice: throw SyncCoordinatorError.singleDevice
            case .coolingDown(let date): throw SyncCoordinatorError.coolingDown(date)
            case .dailyLimit: throw SyncCoordinatorError.dailyLimit
            case .available: break
            }
        }

        isSyncing = true
        lastError = nil
        notifyStateChanged()
        defer {
            isSyncing = false
            syncProgress = nil
            notifyStateChanged()
        }

        do {
            if let encryptedDeviceProfile {
                state.pendingEncryptedDeviceProfile = encryptedDeviceProfile
                try stateStore.save(state)
            }
            let prepared = try prepareRecords()
            if bypassOrdinaryGating,
               prepared.archives.count > SyncConstants.maximumBootstrapArchives {
                throw SyncCoordinatorError.bootstrapTooLarge
            }
            let archiveBatches = bypassOrdinaryGating
                ? SyncArchiveBatcher.batches(prepared.archives)
                : [Array(prepared.archives.prefix(SyncConstants.maximumArchivesPerRequest))]
            syncProgress = SyncProgress(
                totalDays: archiveBatches.reduce(0) { $0 + $1.count }
                    + (prepared.current == nil ? 0 : 1)
            )
            notifyStateChanged()
            let profileToUpload = state.pendingEncryptedDeviceProfile
            let transport = try makeTransport()
            let token = try boundCredentials().deviceToken
            var finalResponse: SyncResponseV1?

            for (index, archives) in archiveBatches.enumerated() {
                let isFinalBatch = index == archiveBatches.count - 1
                let request = SyncRequestV1(
                    reason: reason,
                    historyCursor: state.cursor,
                    currentSnapshot: isFinalBatch ? prepared.current : nil,
                    archives: archives,
                    encryptedDeviceProfile: isFinalBatch ? profileToUpload : nil,
                    bootstrapComplete: !bypassOrdinaryGating || isFinalBatch
                )
                let response = try await transport.sync(
                    request,
                    bearerToken: token,
                    idempotencyKey: try idempotencyKey(for: request)
                )
                try apply(response: response)
                markArchivesAcknowledged(archives)
                if isFinalBatch {
                    state.pendingEncryptedDeviceProfile = nil
                    if response.historyHasMore {
                        state.needsBootstrap = true
                        state.bootstrapUploadCompleted = true
                    }
                }
                syncProgress?.advance(
                    by: archives.count + (isFinalBatch && prepared.current != nil ? 1 : 0)
                )
                notifyStateChanged()
                try stateStore.save(state)
                finalResponse = response
            }

            guard let response = finalResponse else { throw SyncTransportError.invalidResponse }
            state.lastSuccessfulSyncAt = response.serverTime
            state.nextAllowedSyncAt = response.nextAllowedSyncAt
            state.remainingSuccessfulSyncsToday = response.remainingDailySyncs
            state.quotaUTCDay = SyncSchedulePolicy.utcDay(response.serverTime)
            state.activeDeviceCount = response.activeDeviceCount
            state.lastStateRefreshAt = response.serverTime
            state.needsBootstrap = false
            state.automaticFailureCount = 0
            state.automaticFailureUTCDay = SyncSchedulePolicy.utcDay(response.serverTime)
            state.automaticRetryAt = nil
            state.automaticDueAt = nil
            state.pendingEncryptedDeviceProfile = nil
            if response.historyHasMore {
                state.needsBootstrap = true
                state.bootstrapUploadCompleted = true
                try stateStore.save(state)
                try await fetchRemainingHistory()
                state.needsBootstrap = false
                state.bootstrapUploadCompleted = false
            } else {
                state.needsBootstrap = false
                state.bootstrapUploadCompleted = false
            }
            try persistAndNotify()
            scheduleIfNeeded()
        } catch {
            lastError = error
            if case SyncTransportError.singleDevice(let activeDeviceCount) = error {
                state.activeDeviceCount = activeDeviceCount
                state.automaticRetryAt = nil
                state.automaticDueAt = nil
                state.lastStateRefreshAt = Date()
                state.devices = state.devices.filter { $0.deviceId == state.deviceId }
                if state.devices.isEmpty { state.devices = [currentDevice()] }
                try? stateStore.save(state)
                scheduleIfNeeded()
                throw error
            }
            if requiresRepair(after: error) {
                enterRepairMode()
            }
            handleFailure(error, reason: reason)
            try? stateStore.save(state)
            scheduleIfNeeded()
            throw error
        }
    }

    @MainActor
    private func prepareRecords() throws -> (current: EncryptedSyncRecordV1?, archives: [EncryptedSyncRecordV1]) {
        guard let vaultId = state.vaultId else { throw SyncCoordinatorError.notConfigured }
        let seed = try boundCredentials().recoverySeed
        let localHistory = StatsManager.shared.localSyncHistorySnapshot()
        let today = SyncDay.string(from: Date())
        var current: EncryptedSyncRecordV1?
        var archives: [EncryptedSyncRecordV1] = []

        for (day, daily) in localHistory.sorted(by: { $0.key < $1.key }) {
            let provisional = try DisplayStatsAggregator.coreSnapshot(from: daily, deviceId: state.deviceId, revision: 0)
            let contentHash = try SyncCrypto.contentHash(provisional)
            let previous = state.revisions[day]
            let existingEnvelope = state.pendingRecords[day]
            let record: EncryptedSyncRecordV1
            let didChange: Bool
            if previous?.contentHash == contentHash, let existingEnvelope {
                record = existingEnvelope
                didChange = false
            } else {
                let previousRevision = previous?.revision ?? 0
                guard previousRevision < Int64.max else { throw SyncCoordinatorError.revisionExhausted }
                let revision = max(1, previousRevision + 1)
                let snapshot = try DisplayStatsAggregator.coreSnapshot(
                    from: daily,
                    deviceId: state.deviceId,
                    revision: revision
                )
                record = try SyncCrypto.encrypt(snapshot: snapshot, vaultId: vaultId, seed: seed)
                state.revisions[day] = SyncRevisionState(revision: revision, contentHash: contentHash)
                state.pendingRecords[day] = record
                didChange = true
            }

            if day == today {
                current = record
            } else if didChange || record.revision > (state.archivedRevisions[day] ?? 0) {
                archives.append(record)
            }
        }
        // Persist the exact nonce/tag envelope before any request can leave the process.
        try stateStore.save(state)
        return (current, archives)
    }

    @MainActor
    private func retryBootstrapWork(reason: SyncReason) async throws {
        if state.pendingProvisioning != nil {
            try await finishPendingProvisioning()
        } else if state.bootstrapUploadCompleted {
            try await resumeHistoryBootstrap(reason: reason)
        } else {
            try await performSync(reason: reason, bypassOrdinaryGating: true)
        }
    }

    @MainActor
    private func resumeHistoryBootstrap(reason: SyncReason) async throws {
        guard state.isConfigured, state.needsBootstrap, !state.needsRepair else {
            throw SyncCoordinatorError.notConfigured
        }
        guard !isSyncing else { throw SyncCoordinatorError.syncInProgress }
        isSyncing = true
        lastError = nil
        notifyStateChanged()
        defer {
            isSyncing = false
            notifyStateChanged()
        }
        do {
            try await fetchRemainingHistory()
            state.needsBootstrap = false
            state.bootstrapUploadCompleted = false
            state.automaticFailureCount = 0
            state.automaticRetryAt = nil
            try persistAndNotify()
            scheduleIfNeeded()
        } catch {
            lastError = error
            if requiresRepair(after: error) { state.needsRepair = true }
            handleFailure(error, reason: reason)
            try? stateStore.save(state)
            throw error
        }
    }

    private func markArchivesAcknowledged(_ records: [EncryptedSyncRecordV1]) {
        guard !records.isEmpty else { return }
        let acknowledged = Dictionary(uniqueKeysWithValues: records.map { ($0.recordId, $0.revision) })
        for (day, envelope) in state.pendingRecords {
            guard acknowledged[envelope.recordId] == envelope.revision else { continue }
            state.archivedRevisions[day] = max(state.archivedRevisions[day] ?? 0, envelope.revision)
        }
    }

    @MainActor
    private func apply(response: SyncResponseV1) throws {
        guard let vaultId = state.vaultId else { throw SyncCoordinatorError.notConfigured }
        guard (1...SyncConstants.maximumActiveDevices).contains(response.activeDeviceCount),
              (0...SyncConstants.maximumSuccessfulSyncsPerUTCDay).contains(response.remainingDailySyncs),
              response.cursor >= 0,
              response.currentSnapshots.count <= SyncConstants.maximumActiveDevices else {
            throw SyncTransportError.invalidResponse
        }
        let seed = try boundCredentials().recoverySeed
        for record in response.currentSnapshots where record.deviceId != state.deviceId {
            let snapshot = try SyncCrypto.decrypt(record: record, vaultId: vaultId, seed: seed)
            _ = try cache.apply(recordId: record.recordId, snapshot: snapshot, currentDeviceId: state.deviceId)
            if !state.devices.contains(where: { $0.deviceId == record.deviceId }) {
                state.devices.append(SyncDevice(
                    deviceId: record.deviceId,
                    displayName: String(format: NSLocalizedString("sync.device.generic", comment: ""), String(record.deviceId.prefix(6))),
                    platform: "",
                    lastSyncAt: response.serverTime,
                    isCurrent: false,
                    isRevoked: false
                ))
            }
        }
        try refreshDevices(response.devices, vaultId: vaultId, seed: seed)
        try applyHistoryChanges(response.historyChanges, vaultId: vaultId, seed: seed)
        state.cursor = response.cursor
    }

    private func refreshDevices(_ encryptedDevices: [SyncEncryptedDeviceV1], vaultId: String, seed: Data) throws {
        guard encryptedDevices.count <= SyncConstants.maximumActiveDevices else {
            throw SyncTransportError.invalidResponse
        }
        var seen: Set<String> = []
        var refreshed: [SyncDevice] = []
        for encrypted in encryptedDevices {
            guard !encrypted.deviceId.isEmpty, seen.insert(encrypted.deviceId).inserted else {
                throw SyncTransportError.invalidResponse
            }
            let existing = state.devices.first { $0.deviceId == encrypted.deviceId }
            let profile = try encrypted.encryptedDeviceProfile.map {
                try SyncCrypto.decryptDeviceProfile(
                    $0,
                    vaultId: vaultId,
                    deviceId: encrypted.deviceId,
                    seed: seed
                )
            }
            refreshed.append(SyncDevice(
                deviceId: encrypted.deviceId,
                displayName: profile?.displayName
                    ?? existing?.displayName
                    ?? String(format: NSLocalizedString("sync.device.generic", comment: ""), String(encrypted.deviceId.prefix(6))),
                platform: profile?.platform ?? existing?.platform ?? "",
                lastSyncAt: encrypted.lastSyncAt,
                isCurrent: encrypted.deviceId == state.deviceId,
                isRevoked: encrypted.revoked
            ))
        }
        if !seen.contains(state.deviceId) {
            refreshed.append(currentDevice())
        }
        state.devices = refreshed
    }

    @MainActor
    private func fetchRemainingHistory() async throws {
        guard let vaultId = state.vaultId else { throw SyncCoordinatorError.notConfigured }
        let credentials = try boundCredentials()
        let seed = credentials.recoverySeed
        let token = credentials.deviceToken
        var pageCount = 0
        while pageCount < SyncConstants.maximumHistoryPagesPerAttempt {
            let previousCursor = state.cursor
            let page = try await makeTransport().history(cursor: state.cursor, bearerToken: token)
            guard page.cursor >= 0,
                  !page.hasMore || page.cursor > previousCursor else {
                throw SyncTransportError.invalidResponse
            }
            try applyHistoryChanges(page.changes, vaultId: vaultId, seed: seed)
            state.cursor = page.cursor
            try stateStore.save(state)
            pageCount += 1
            if !page.hasMore { return }
        }
        throw SyncTransportError.invalidResponse
    }

    private func applyHistoryChanges(_ changes: [SyncHistoryChangeV1], vaultId: String, seed: Data) throws {
        for change in changes {
            if change.tombstone {
                try cache.applyTombstone(recordId: change.recordId)
                continue
            }
            guard let record = change.record, record.recordId == change.recordId else {
                throw SyncTransportError.invalidResponse
            }
            let snapshot = try SyncCrypto.decrypt(record: record, vaultId: vaultId, seed: seed)
            _ = try cache.apply(recordId: record.recordId, snapshot: snapshot, currentDeviceId: state.deviceId)
        }
    }

    private func idempotencyKey(for request: SyncRequestV1) throws -> String {
        let digest = SHA256.hash(data: try SyncJSON.encoder.encode(request))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Scheduling and state

    private func scheduleIfNeeded() {
        assert(Thread.isMainThread)
        automaticTimer?.invalidate()
        automaticTimer = nil
        stateRefreshTimer?.invalidate()
        stateRefreshTimer = nil
        guard state.isConfigured, !state.needsRepair, !state.needsBootstrap,
              state.pendingProvisioning == nil else { return }
        guard state.activeDeviceCount >= 2 else {
            scheduleSingleDeviceStateRefresh()
            return
        }
        let now = Date()
        let target: Date
        if let retryAt = state.automaticRetryAt {
            target = retryAt
        } else if SyncSchedulePolicy.automaticFailureCount(state: state, now: now) >= SyncConstants.maximumAutomaticFailuresPerUTCDay {
            target = nextUTCMidnight(after: now).addingTimeInterval(stableJitter(for: nextUTCMidnight(after: now)))
        } else if SyncConstants.enforcesSuccessfulSyncRateLimits,
                  state.quotaUTCDay == SyncSchedulePolicy.utcDay(now),
                  state.remainingSuccessfulSyncsToday <= 0 {
            target = nextUTCMidnight(after: now).addingTimeInterval(stableJitter(for: nextUTCMidnight(after: now)))
        } else if let due = state.automaticDueAt {
            target = due
        } else {
            let base = (state.lastSuccessfulSyncAt ?? now).addingTimeInterval(
                state.lastSuccessfulSyncAt == nil ? 0 : SyncConstants.automaticSyncInterval
            )
            let due = base.addingTimeInterval(stableJitter(for: base))
            state.automaticDueAt = due
            try? stateStore.save(state)
            target = due
        }
        let serverAllowed = SyncConstants.enforcesSuccessfulSyncRateLimits
            ? state.nextAllowedSyncAt ?? .distantPast
            : .distantPast
        let finalTarget = max(target, serverAllowed)
        automaticTimer = Timer.scheduledTimer(withTimeInterval: max(0.25, finalTarget.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await self?.performSync(reason: .automatic, bypassOrdinaryGating: false)
            }
        }
    }

    private func scheduleSingleDeviceStateRefresh() {
        let now = Date()
        let target = (state.lastStateRefreshAt ?? .distantPast)
            .addingTimeInterval(SyncConstants.automaticSyncInterval)
        let due = max(now.addingTimeInterval(0.25), target)
        stateRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: max(0.25, due.timeIntervalSince(now)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshCloudStateIfNeeded(force: true)
            }
        }
    }

    @MainActor
    private func refreshCloudStateIfNeeded(force: Bool = false) async {
        guard state.isConfigured,
              !state.needsRepair,
              !state.needsBootstrap,
              state.pendingProvisioning == nil,
              state.activeDeviceCount < 2,
              !isRefreshingState,
              !isSyncing else { return }
        if !force, let last = state.lastStateRefreshAt,
           Date().timeIntervalSince(last) < SyncConstants.automaticSyncInterval {
            scheduleIfNeeded()
            return
        }
        isRefreshingState = true
        defer {
            isRefreshingState = false
            scheduleIfNeeded()
        }
        do {
            let credentials = try boundCredentials()
            let response = try await makeTransport().state(bearerToken: credentials.deviceToken)
            try validateAndApplyCloudState(response, credentials: credentials, applyCurrentSnapshots: true)
            state.lastStateRefreshAt = response.serverTime
            try persistAndNotify()
        } catch SyncTransportError.unauthorized {
            enterRepairMode()
        } catch {
            lastError = error
            try? stateStore.save(state)
        }
    }

    private func validateAndApplyCloudState(
        _ response: SyncStateResponseV1,
        credentials: SyncStoredCredentials,
        applyCurrentSnapshots: Bool
    ) throws {
        guard let vaultId = state.vaultId,
              (1...SyncConstants.maximumActiveDevices).contains(response.activeDeviceCount),
              response.devices.count <= SyncConstants.maximumActiveDevices,
              response.currentSnapshots.count <= SyncConstants.maximumActiveDevices else {
            throw SyncTransportError.invalidResponse
        }
        if applyCurrentSnapshots {
            for record in response.currentSnapshots where record.deviceId != state.deviceId {
                let snapshot = try SyncCrypto.decrypt(
                    record: record,
                    vaultId: vaultId,
                    seed: credentials.recoverySeed
                )
                _ = try cache.apply(
                    recordId: record.recordId,
                    snapshot: snapshot,
                    currentDeviceId: state.deviceId
                )
            }
        }
        try refreshDevices(
            response.devices,
            vaultId: vaultId,
            seed: credentials.recoverySeed
        )
        state.activeDeviceCount = response.activeDeviceCount
        if response.activeDeviceCount < 2 {
            state.automaticDueAt = nil
            state.automaticRetryAt = nil
        }
    }

    private func handleFailure(_ error: Error, reason: SyncReason) {
        let now = Date()
        if case SyncTransportError.rateLimited(let retryAt) = error {
            state.nextAllowedSyncAt = retryAt
            if reason == .automatic {
                state.automaticRetryAt = retryAt
            }
            return
        }
        switch reason {
        case .manual:
            state.nextAllowedSyncAt = now.addingTimeInterval(60)
        case .automatic:
            let utcDay = SyncSchedulePolicy.utcDay(now)
            if state.automaticFailureUTCDay != utcDay {
                state.automaticFailureUTCDay = utcDay
                state.automaticFailureCount = 0
            }
            state.automaticFailureCount += 1
            if state.automaticFailureCount == 1 {
                state.automaticRetryAt = now.addingTimeInterval(60 * 60)
            } else if state.automaticFailureCount == 2 {
                state.automaticRetryAt = now.addingTimeInterval(6 * 60 * 60)
            } else {
                state.automaticRetryAt = nil
            }
        case .bootstrap, .recovery:
            state.needsBootstrap = true
        case .pairing:
            // A joining device already has needsBootstrap=true. An approver's
            // polling 409 must not put an otherwise healthy device into repair.
            break
        }
    }

    private func requiresRepair(after error: Error) -> Bool {
        if error is SyncStorageError { return true }
        if let validation = error as? SyncValidationError,
           case .authenticationFailed = validation {
            return true
        }
        if let transport = error as? SyncTransportError {
            switch transport {
            case .unauthorized, .forbidden:
                return true
            default:
                return false
            }
        }
        if let crypto = error as? SyncCryptoError,
           case .missingCredentials = crypto {
            return true
        }
        return false
    }

    private func enterRepairMode() {
        state.needsRepair = true
        try? cache.clear()
        try? persistAndNotify()
    }

    private func stableJitter(for dueDate: Date) -> TimeInterval {
        let input = Data("\(state.deviceId)\n\(SyncSchedulePolicy.utcDay(dueDate))".utf8)
        let digest = Array(SHA256.hash(data: input))
        let value = (Int(digest[0]) << 8) | Int(digest[1])
        return TimeInterval(value % 3_601)
    }

    private func nextUTCMidnight(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    private func scheduleApproverPairingRefresh(until expiresAt: Date) {
        pairingRefreshTask?.cancel()
        pairingRefreshTask = Task { @MainActor [weak self] in
            let retryDelays: [TimeInterval] = [5, 10, 20, 40, 60]
            var attempt = 0
            while !Task.isCancelled, Date() < expiresAt {
                let requestedDelay = retryDelays[min(attempt, retryDelays.count - 1)]
                let delay = min(requestedDelay, max(0, expiresAt.timeIntervalSinceNow))
                guard delay > 0 else { break }
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                do {
                    try await self.performSync(reason: .pairing, bypassOrdinaryGating: true)
                    self.pairingRefreshTask = nil
                    return
                } catch SyncTransportError.conflict {
                    attempt += 1
                } catch SyncTransportError.singleDevice {
                    attempt += 1
                } catch SyncCoordinatorError.syncInProgress {
                    attempt += 1
                } catch {
                    self.pairingRefreshTask = nil
                    return
                }
            }
            self?.pairingRefreshTask = nil
        }
    }

    private func configuredServiceURL() -> URL? {
        // The endpoint is a build-time trust decision. Never revive a staging
        // or user-edited URL solely from persisted state in another build.
        guard !serviceEnvironmentMismatch else { return nil }
        return buildServiceURL
    }

    private func makeTransport() throws -> SyncTransport {
        guard let url = configuredServiceURL() else { throw SyncCoordinatorError.serviceNotConfigured }
        return CloudflareSyncTransport(baseURL: url)
    }

    private func boundCredentials() throws -> SyncStoredCredentials {
        guard let vaultId = state.vaultId else { throw SyncCryptoError.missingCredentials }
        return try credentialStore.credentials(vaultId: vaultId, deviceId: state.deviceId)
    }

    private func persistJoiningPairing() throws {
        guard let joiningPairing else {
            try credentialStore.clearPendingPairing()
            return
        }
        let stored = StoredJoiningPairingState(
            privateKey: joiningPairing.keyPair.rawPrivateKey,
            sessionId: joiningPairing.sessionId,
            completionToken: joiningPairing.completionToken,
            deviceId: joiningPairing.deviceId,
            expiresAt: joiningPairing.expiresAt,
            approvalResponse: joiningPairing.approvalResponse
        )
        try credentialStore.savePendingPairing(try SyncJSON.encoder.encode(stored))
    }

    private func restorePendingPairingIfPossible() {
        do {
            guard let data = try credentialStore.pendingPairing() else { return }
            if state.isConfigured, state.pendingProvisioning?.kind != .pairing {
                try credentialStore.clearPendingPairing()
                return
            }
            let stored = try SyncJSON.decoder.decode(StoredJoiningPairingState.self, from: data)
            guard stored.expiresAt > Date(), stored.deviceId == state.deviceId else {
                try credentialStore.clearPendingPairing()
                return
            }
            joiningPairing = JoiningPairingState(
                keyPair: try SyncPairingKeyPair(rawPrivateKey: stored.privateKey),
                sessionId: stored.sessionId,
                completionToken: stored.completionToken,
                deviceId: stored.deviceId,
                expiresAt: stored.expiresAt,
                approvalResponse: stored.approvalResponse
            )
        } catch {
            try? credentialStore.clearPendingPairing()
            joiningPairing = nil
        }
    }

    private func currentDevice() -> SyncDevice {
        SyncDevice(
            deviceId: state.deviceId,
            displayName: state.displayName,
            platform: "macos",
            lastSyncAt: state.lastSuccessfulSyncAt,
            isCurrent: true,
            isRevoked: false
        )
    }

    private func persistAndNotify() throws {
        try stateStore.save(state)
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .syncStateDidChange, object: nil)
        }
    }

    private func clearLocalConfiguration(rotateIdentity: Bool = true) throws {
        automaticTimer?.invalidate()
        automaticTimer = nil
        stateRefreshTimer?.invalidate()
        stateRefreshTimer = nil
        pairingRefreshTask?.cancel()
        pairingRefreshTask = nil
        try credentialStore.clear()
        try cache.clear()
        let baseURL = buildServiceURL?.absoluteString ?? ""
        state = .fresh(serverBaseURL: baseURL)
        serviceEnvironmentMismatch = false
        state.deviceId = rotateIdentity
            ? SyncInstallationIdentity.rotate()
            : SyncInstallationIdentity.current()
        try stateStore.save(state)
        joiningPairing = nil
        approvingPairing = nil
        lastError = nil
        notifyStateChanged()
    }
}
