import CryptoKit
import Foundation
import XCTest
@testable import KeyStatsCore

final class SyncCoreTests: XCTestCase {
    func testSyncProgressAdvancesByDayAndStopsAtTotal() {
        var progress = SyncProgress(totalDays: 18)

        progress.advance(by: 16)
        XCTAssertEqual(progress, SyncProgress(completedDays: 16, totalDays: 18))

        progress.advance(by: 16)
        XCTAssertEqual(progress, SyncProgress(completedDays: 18, totalDays: 18))
    }

    func testArchiveBatcherUsesSixteenRecordPagesAndKeepsAnEmptyFinalPage() {
        XCTAssertEqual(SyncArchiveBatcher.batches(Array(0..<35)).map(\.count), [16, 16, 3])
        XCTAssertEqual(SyncArchiveBatcher.batches([Int]()).map(\.count), [0])
    }

    func testRecoveryCodeGoldenVectorAndRoundTrip() throws {
        let seed = Data(0..<16)
        let code = try SyncCrypto.recoveryCode(from: seed)
        XCTAssertEqual(code, "000G40R40M30E209185GR38E1W29")
        XCTAssertEqual(try SyncCrypto.recoverySeed(from: "000G-40R4-0M30-E209-185G-R38E-1W29"), seed)
    }

    func testRecoveryCodeRejectsNonCanonicalPaddingBits() {
        XCTAssertThrowsError(try SyncCrypto.recoverySeed(from: "000G40R40M30E209185GR38E1X29"))
    }

    func testEncryptedRecordRoundTripAndAADTamperDetection() throws {
        let seed = Data(0..<16)
        let snapshot = try CoreDaySnapshotV1(
            deviceId: "device-a",
            localDay: "2026-07-13",
            revision: 7,
            keyPresses: 42,
            keyPressCounts: ["Escape": 3, "Cmd+A": 4],
            clicks: CoreClickSnapshotV1(left: 8, right: 2, middle: 1, sideBack: 1, sideForward: 0)
        ).validated()
        let encrypted = try SyncCrypto.encrypt(snapshot: snapshot, vaultId: "vault-a", seed: seed)
        let decrypted = try SyncCrypto.decrypt(record: encrypted, vaultId: "vault-a", seed: seed)
        XCTAssertEqual(decrypted.keyPressCounts["Esc"], 3)
        XCTAssertEqual(decrypted.keyPresses, 42)

        let tampered = EncryptedSyncRecordV1(
            recordId: encrypted.recordId,
            deviceId: encrypted.deviceId,
            revision: encrypted.revision + 1,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag,
            ciphertextHash: encrypted.ciphertextHash
        )
        XCTAssertThrowsError(try SyncCrypto.decrypt(record: tampered, vaultId: "vault-a", seed: seed))

        let tamperedDevice = EncryptedSyncRecordV1(
            recordId: encrypted.recordId,
            deviceId: "device-b",
            revision: encrypted.revision,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag,
            ciphertextHash: encrypted.ciphertextHash
        )
        XCTAssertThrowsError(try SyncCrypto.decrypt(record: tamperedDevice, vaultId: "vault-a", seed: seed))
        for mutation in [
            EncryptedSyncRecordV1(
                recordId: encrypted.recordId,
                deviceId: encrypted.deviceId,
                revision: encrypted.revision,
                nonce: flippedBase64(encrypted.nonce),
                ciphertext: encrypted.ciphertext,
                tag: encrypted.tag,
                ciphertextHash: encrypted.ciphertextHash
            ),
            EncryptedSyncRecordV1(
                recordId: encrypted.recordId,
                deviceId: encrypted.deviceId,
                revision: encrypted.revision,
                nonce: encrypted.nonce,
                ciphertext: flippedBase64(encrypted.ciphertext),
                tag: encrypted.tag,
                ciphertextHash: encrypted.ciphertextHash
            ),
            EncryptedSyncRecordV1(
                recordId: encrypted.recordId,
                deviceId: encrypted.deviceId,
                revision: encrypted.revision,
                nonce: encrypted.nonce,
                ciphertext: encrypted.ciphertext,
                tag: flippedBase64(encrypted.tag),
                ciphertextHash: encrypted.ciphertextHash
            )
        ] {
            XCTAssertThrowsError(try SyncCrypto.decrypt(record: mutation, vaultId: "vault-a", seed: seed))
        }
    }

    func testRecordIdAndAADGoldenInputsAreStable() throws {
        let seed = Data(0..<16)
        let deviceId = "22222222-2222-4222-8222-222222222222"
        let first = SyncCrypto.recordId(vaultId: "ignored-a", deviceId: deviceId, localDay: "2026-07-13", seed: seed)
        let second = SyncCrypto.recordId(vaultId: "ignored-b", deviceId: deviceId, localDay: "2026-07-13", seed: seed)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "8dgxQ8oxi6TPVz2uZySYTexf6IIqtgO27SMzVwerp3M")
    }

    func testSharedRecordGoldenVectorDecrypts() throws {
        let seed = Data(0..<16)
        let record = EncryptedSyncRecordV1(
            recordId: "8dgxQ8oxi6TPVz2uZySYTexf6IIqtgO27SMzVwerp3M",
            deviceId: "22222222-2222-4222-8222-222222222222",
            revision: 7,
            nonce: "AAECAwQFBgcICQoL",
            ciphertext: "Fq8powaIdU8rPh3OxnQHghepix11oa0KKgeCOlnWd3HZ7XM1YfWFxhQAJdULWmHtUJ9s2wOTq0/w7NUabaeFtb0klI2cJvTHJAoL5JE15+pxTP6h2g9kbqFuoHJwIquF5OzYKQQh1MHAj8LZ5fJMKk/U3SeHGZ3BHNcSmQu0IPk0S1HSLa8wLES+9xilwonXPIOmj8GnknUk1oU5IW9aQogvG2pnODNil3QFMn1krGz+22iPlOhYFtRz+PfgtEeXDnd8InjHrx+dbJMn9uzD8DAeLT/dpECtuHC2CGyH9BSRolFAndkwFdL9Odd048nZlE8T",
            tag: "YEkecvnucs/fCNmchmBO0w==",
            ciphertextHash: "l9ofxDb2Y5vM491fyMl4tYG5grlvnIHAiSIygdVYJYg"
        )
        let snapshot = try SyncCrypto.decrypt(
            record: record,
            vaultId: "11111111-1111-4111-8111-111111111111",
            seed: seed
        )
        XCTAssertEqual(snapshot.localDay, "2026-07-13")
        XCTAssertEqual(snapshot.keyPresses, 42)
        XCTAssertEqual(snapshot.keyPressCounts, ["A": 10, "Enter": 4, "LeftCmd+C": 2])
        XCTAssertEqual(snapshot.clicks, CoreClickSnapshotV1(left: 17, right: 5, middle: 3, sideBack: 2, sideForward: 1))
    }

    func testSharedDerivedKeyAndPairingGoldenVectors() throws {
        let seed = Data(0..<16)
        let keys = SyncCrypto.deriveKeys(seed: seed)
        XCTAssertEqual(keyData(keys.encryption).hexString, "12b4daed3dd05973ed06e169b0a5fe0ccf1b9d5f05527af644b35b46a212f8c2")
        XCTAssertEqual(keyData(keys.recordIndex).hexString, "bb3ad3bb555398343b9e16e2a2d18957f9daf97290308c7a604fc1d12b34f912")
        XCTAssertEqual(SyncCrypto.recoveryCredential(seed: seed), "kG5pSaXcTEeTmZZYdxm8v6-N81VTN6oc0yHcrgwVtDs")

        let joining = try SyncPairingKeyPair(rawPrivateKey: try XCTUnwrap(Data(hexString: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")))
        let approvingPublicKey = "urJntOlkrpGZxQD2TJmZax+Cgju05CnCfJvh+/f0tX8="
        XCTAssertEqual(joining.publicKey, "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=")
        XCTAssertEqual(
            try SyncCrypto.pairingSafetyCode(
                ownKeyPair: joining,
                peerPublicKey: approvingPublicKey,
                sessionId: "33333333-3333-4333-8333-333333333333"
            ),
            "186481"
        )
        let grant = try SyncCrypto.decryptPairingGrant(
            SyncEncryptedGrant(
                nonce: "CwoJCAcGBQQDAgEA",
                ciphertext: "cREyHT/iqtoMzagsS1To7lrXwKxiNIRjnznHaptjhT8JprpvaFQM83TOA2jisYTK8eYStNRKE6l8a6IKxiUD/mrTEPc9Td8tPPXx0eTIg+RtM0K3BV1GyYNsRMv4I5DlEpA63y6mrDzR1nsa+ENmNR/MP3cYUEqpgfAmJVaCNWfHKMXfdVMNglteKi8kDusjB/PssfxdzYY7dd9u/oSdotMW8UbLlNJY1eoIdKUC0z8USZZShdUaIsfLF/Zu",
                tag: "0rcuzeh2OWwOt9X/xczcFA=="
            ),
            ownKeyPair: joining,
            peerPublicKey: approvingPublicKey,
            sessionId: "33333333-3333-4333-8333-333333333333"
        )
        XCTAssertEqual(grant.vaultId, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(grant.recoverySeed, "AAECAwQFBgcICQoLDA0ODw==")
    }

    func testRemoteCacheReplacesByRevisionWithoutAccumulating() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystats-sync-cache-\(UUID().uuidString).json")
        let cache = RemoteShardCache(fileURL: fileURL)
        let first = CoreDaySnapshotV1(
            deviceId: "remote",
            localDay: "2026-07-13",
            revision: 1,
            keyPresses: 10,
            keyPressCounts: ["A": 10],
            clicks: .zero
        )
        XCTAssertEqual(try cache.apply(recordId: "record", snapshot: first, currentDeviceId: "local"), .inserted)
        for _ in 0..<10 {
            XCTAssertEqual(try cache.apply(recordId: "record", snapshot: first, currentDeviceId: "local"), .unchanged)
        }
        let second = CoreDaySnapshotV1(
            deviceId: "remote",
            localDay: "2026-07-13",
            revision: 2,
            keyPresses: 12,
            keyPressCounts: ["A": 12],
            clicks: .zero
        )
        XCTAssertEqual(try cache.apply(recordId: "record", snapshot: second, currentDeviceId: "local"), .replaced)
        XCTAssertEqual(cache.snapshots().single?.keyPresses, 12)
    }

    func testCorruptRemoteCacheEntersRepairWithoutOverwritingTheFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keystats-corrupt-sync-cache-\(UUID().uuidString).json")
        let corruptData = Data("{not-valid-json".utf8)
        try corruptData.write(to: fileURL)

        let cache = RemoteShardCache(fileURL: fileURL)

        XCTAssertNotNil(cache.loadError)
        XCTAssertTrue(cache.snapshots().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptData)
    }

    func testDisplayAggregationUsesSaturatingIdempotentShards() throws {
        var localDay = DailyStats(date: try XCTUnwrap(SyncDay.date(from: "2026-07-13")))
        localDay.keyPresses = 5
        localDay.keyPressCounts = ["A": 5]
        let remote = CoreDaySnapshotV1(
            deviceId: "remote",
            localDay: "2026-07-13",
            revision: 3,
            keyPresses: 7,
            keyPressCounts: ["A": 7],
            clicks: CoreClickSnapshotV1(left: 2, right: 0, middle: 1, sideBack: 0, sideForward: 0)
        )
        let aggregated = DisplayStatsAggregator.aggregate(
            local: ["2026-07-13": localDay],
            remote: DisplayStatsAggregator.deduplicatedLatest([remote, remote]),
            currentDeviceId: "local"
        )
        XCTAssertEqual(aggregated["2026-07-13"]?.keyPresses, 12)
        XCTAssertEqual(aggregated["2026-07-13"]?.keyPressCounts["A"], 12)
        XCTAssertEqual(aggregated["2026-07-13"]?.middleClicks, 1)
    }

    func testCurrentDayDisplayAggregatesRemoteKeysAndClicksOnlyForSameDay() throws {
        var localDay = DailyStats(date: try XCTUnwrap(SyncDay.date(from: "2026-07-15")))
        localDay.keyPresses = 5
        localDay.keyPressCounts = ["A": 5]
        localDay.leftClicks = 1
        localDay.mouseDistance = 42
        let remoteToday = CoreDaySnapshotV1(
            deviceId: "remote",
            localDay: "2026-07-15",
            revision: 3,
            keyPresses: 7,
            keyPressCounts: ["A": 7],
            clicks: CoreClickSnapshotV1(left: 2, right: 1, middle: 0, sideBack: 0, sideForward: 0)
        )
        let remoteYesterday = CoreDaySnapshotV1(
            deviceId: "remote",
            localDay: "2026-07-14",
            revision: 2,
            keyPresses: 100,
            keyPressCounts: ["B": 100],
            clicks: CoreClickSnapshotV1(left: 100, right: 0, middle: 0, sideBack: 0, sideForward: 0)
        )

        let displayed = DisplayStatsAggregator.currentDay(
            local: localDay,
            remote: [remoteToday, remoteYesterday],
            currentDeviceId: "local"
        )

        XCTAssertEqual(displayed.keyPresses, 12)
        XCTAssertEqual(displayed.keyPressCounts, ["A": 12])
        XCTAssertEqual(displayed.leftClicks, 3)
        XCTAssertEqual(displayed.rightClicks, 1)
        XCTAssertEqual(displayed.mouseDistance, 42)
    }

    func testSingleDeviceGatingAndDailyLimit() {
        var state = SyncPersistentState.fresh(serverBaseURL: "https://sync.example.workers.dev")
        state.vaultId = "vault"
        state.activeDeviceCount = 1
        XCTAssertEqual(SyncSchedulePolicy.availability(state: state), .singleDevice)
        XCTAssertFalse(SyncSchedulePolicy.shouldScheduleAutomaticSync(state: state))

        state.activeDeviceCount = 2
        state.quotaUTCDay = SyncSchedulePolicy.utcDay(Date())
        state.remainingSuccessfulSyncsToday = 0
        XCTAssertEqual(SyncSchedulePolicy.availability(state: state, enforcesRateLimits: true), .dailyLimit)
    }

    func testHourlyManualAndTwentyFourHourAutomaticSchedulePolicy() {
        let now = Date(timeIntervalSince1970: 1_783_944_000)
        var state = SyncPersistentState.fresh(serverBaseURL: "https://sync.example.workers.dev")
        state.vaultId = "vault"
        state.deviceId = "device"
        state.activeDeviceCount = 2
        state.quotaUTCDay = SyncSchedulePolicy.utcDay(now)
        state.remainingSuccessfulSyncsToday = SyncConstants.maximumSuccessfulSyncsPerUTCDay

        state.lastSuccessfulSyncAt = now.addingTimeInterval(-3_599)
        guard case .coolingDown = SyncSchedulePolicy.availability(
            state: state,
            now: now,
            enforcesRateLimits: true
        ) else {
            return XCTFail("Manual sync must remain unavailable for the full one-hour interval.")
        }
        state.lastSuccessfulSyncAt = now.addingTimeInterval(-3_600)
        XCTAssertEqual(SyncSchedulePolicy.availability(
            state: state,
            now: now,
            enforcesRateLimits: true
        ), .available)

        state.lastSuccessfulSyncAt = now.addingTimeInterval(-(24 * 60 * 60 - 1))
        XCTAssertFalse(SyncSchedulePolicy.shouldScheduleAutomaticSync(
            state: state,
            now: now,
            enforcesRateLimits: true
        ))
        state.lastSuccessfulSyncAt = now.addingTimeInterval(-(24 * 60 * 60))
        XCTAssertTrue(SyncSchedulePolicy.shouldScheduleAutomaticSync(
            state: state,
            now: now,
            enforcesRateLimits: true
        ))

        state.automaticFailureUTCDay = SyncSchedulePolicy.utcDay(now)
        state.automaticFailureCount = SyncConstants.maximumAutomaticFailuresPerUTCDay
        XCTAssertFalse(SyncSchedulePolicy.shouldScheduleAutomaticSync(
            state: state,
            now: now,
            enforcesRateLimits: true
        ))
    }

    func testDebugSchedulePolicyIgnoresServerAndDailyRateLimits() {
        let now = Date(timeIntervalSince1970: 1_783_944_000)
        var state = SyncPersistentState.fresh(serverBaseURL: "https://sync.example.workers.dev")
        state.vaultId = "vault"
        state.deviceId = "device"
        state.activeDeviceCount = 2
        state.quotaUTCDay = SyncSchedulePolicy.utcDay(now)
        state.remainingSuccessfulSyncsToday = 0
        state.lastSuccessfulSyncAt = now
        state.nextAllowedSyncAt = now.addingTimeInterval(60 * 60)

        XCTAssertEqual(SyncSchedulePolicy.availability(
            state: state,
            now: now,
            enforcesRateLimits: false
        ), .available)
    }

    func testKeyCanonicalizationPreservesPlatformModifierSemantics() {
        XCTAssertEqual(SyncKeyCanonicalizer.canonicalize("Escape", platform: "mac"), "Esc")
        XCTAssertEqual(SyncKeyCanonicalizer.canonicalize("Command+Return", platform: "mac"), "Cmd+Enter")
        XCTAssertEqual(SyncKeyCanonicalizer.canonicalize("Win+Alt+Enter", platform: "windows"), "Win+Alt+Enter")
        XCTAssertNotEqual(
            SyncKeyCanonicalizer.canonicalize("Option+A", platform: "mac"),
            SyncKeyCanonicalizer.canonicalize("Alt+A", platform: "windows")
        )
        XCTAssertEqual(
            SyncKeyCanonicalizer.canonicalize("BrowserBack", platform: "windows"),
            "windows:BrowserBack"
        )
        XCTAssertEqual(
            SyncKeyCanonicalizer.canonicalize("windows:BrowserBack", platform: "mac"),
            "windows:BrowserBack"
        )
        XCTAssertEqual(
            SyncKeyCanonicalizer.canonicalize("Vendor Key ☃", platform: "windows"),
            "windows:Vendor Key ☃"
        )
        XCTAssertEqual(
            SyncKeyCanonicalizer.canonicalize("windows:Vendor Key ☃", platform: "mac"),
            "windows:Vendor Key ☃"
        )
    }

    func testSharedDateValidationCases() {
        for invalid in ["2026-02-29", "2026-00-10", "2026-13-01", "2026-04-31", "2026-7-13", "2026-07-13T00:00:00Z"] {
            XCTAssertFalse(SyncDay.isValid(invalid), invalid)
        }
        for valid in ["2024-02-29", "2026-07-13", "9999-12-31"] {
            XCTAssertTrue(SyncDay.isValid(valid), valid)
        }
    }

    func testDeviceProfileIsEncryptedAndBoundToDeviceAAD() throws {
        let seed = Data(0..<16)
        let profile = SyncDeviceProfileV1(displayName: "Private Mac", platform: "macos")
        let encrypted = try SyncCrypto.encryptDeviceProfile(
            profile,
            vaultId: "vault-a",
            deviceId: "device-a",
            seed: seed
        )
        let wire = try SyncJSON.encoder.encode(SyncEncryptedDeviceV1(
            deviceId: "device-a",
            encryptedDeviceProfile: encrypted,
            lastSyncAt: nil,
            revoked: false
        ))
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("Private Mac"))
        XCTAssertEqual(
            try SyncCrypto.decryptDeviceProfile(
                encrypted,
                vaultId: "vault-a",
                deviceId: "device-a",
                seed: seed
            ),
            profile
        )
        XCTAssertThrowsError(try SyncCrypto.decryptDeviceProfile(
            encrypted,
            vaultId: "vault-a",
            deviceId: "device-b",
            seed: seed
        ))
    }

    func testSyncJSONAcceptsFractionalWorkerTimestamps() throws {
        let data = Data(#"{"serverTime":"2026-07-13T12:34:56.789Z"}"#.utf8)
        struct Timestamp: Decodable { let serverTime: Date }
        let decoded = try SyncJSON.decoder.decode(Timestamp.self, from: data)
        XCTAssertEqual(decoded.serverTime.timeIntervalSince1970, 1_783_946_096.789, accuracy: 0.001)
    }

    func testTransportMapsAuthoritativeSingleDeviceConflict() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        SyncURLProtocolStub.response = (
            statusCode: 409,
            body: Data(#"{"code":"single_device_sync_disabled","message":"disabled","activeDeviceCount":1}"#.utf8)
        )
        let transport = CloudflareSyncTransport(
            baseURL: try XCTUnwrap(URL(string: "https://sync.test.workers.dev")),
            session: session
        )
        let request = SyncRequestV1(
            reason: .manual,
            historyCursor: 0,
            currentSnapshot: nil,
            archives: [],
            encryptedDeviceProfile: nil,
            bootstrapComplete: true
        )

        do {
            let _: SyncResponseV1 = try await transport.sync(
                request,
                bearerToken: "token",
                idempotencyKey: "single-device-test"
            )
            XCTFail("Expected the authoritative single-device response to be mapped")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .singleDevice(activeDeviceCount: 1))
        }
    }

    func testTransportMapsMaximumDevicesWithEncryptedReplacementChoices() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        SyncURLProtocolStub.response = (
            statusCode: 409,
            body: Data(#"{"code":"maximum_devices","vaultId":"11111111-1111-4111-8111-111111111111","activeDeviceCount":5,"devices":[{"deviceId":"22222222-2222-4222-8222-222222222222","encryptedDeviceProfile":{"nonce":"AA==","ciphertext":"AQ==","tag":"Ag=="},"lastSyncAt":null,"revoked":false}]}"#.utf8)
        )
        let transport = CloudflareSyncTransport(
            baseURL: try XCTUnwrap(URL(string: "https://sync.test.workers.dev")),
            session: session
        )

        do {
            let _: RecoverVaultResponseV1 = try await transport.recover(RecoverVaultRequestV1(
                recoveryAuthToken: "credential",
                deviceId: "33333333-3333-4333-8333-333333333333",
                deviceToken: "33333333-3333-4333-8333-333333333333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                replaceDeviceId: nil
            ))
            XCTFail("Expected the capacity response to expose encrypted replacement choices")
        } catch let error as SyncTransportError {
            guard case .maximumDevices(let vaultId, let devices) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(vaultId, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(devices.map(\.deviceId), ["22222222-2222-4222-8222-222222222222"])
            XCTAssertEqual(devices.first?.encryptedDeviceProfile?.ciphertext, "AQ==")
        }
    }

    func testTransportDistinguishesMissingRecoveryReplacementFromGenericConflict() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        SyncURLProtocolStub.response = (
            statusCode: 409,
            body: Data(#"{"code":"replace_device_not_found","message":"missing"}"#.utf8)
        )
        let transport = CloudflareSyncTransport(
            baseURL: try XCTUnwrap(URL(string: "https://sync.test.workers.dev")),
            session: session
        )

        do {
            let _: RecoverVaultResponseV1 = try await transport.recover(RecoverVaultRequestV1(
                recoveryAuthToken: "credential",
                deviceId: "33333333-3333-4333-8333-333333333333",
                deviceToken: "33333333-3333-4333-8333-333333333333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                replaceDeviceId: "33333333-3333-4333-8333-333333333333"
            ))
            XCTFail("Expected the missing replacement response to be mapped")
        } catch let error as SyncTransportError {
            XCTAssertEqual(error, .replacementDeviceNotFound)
        }
    }

    func testPersistentStateBackfillsNewSchedulingFields() throws {
        let data = Data(#"{"serverBaseURL":"https://sync.test.workers.dev","vaultId":"vault"}"#.utf8)
        var state = try SyncJSON.decoder.decode(SyncPersistentState.self, from: data)
        XCTAssertEqual(state.activeDeviceCount, 1)
        XCTAssertEqual(state.remainingSuccessfulSyncsToday, 8)
        XCTAssertNil(state.automaticDueAt)
        XCTAssertFalse(state.bootstrapUploadCompleted)
        XCTAssertNil(state.pendingEncryptedDeviceProfile)
        XCTAssertNil(state.pendingProvisioning)
        XCTAssertFalse(state.pendingVaultDeletion)
        XCTAssertNil(state.lastStateRefreshAt)
        XCTAssertTrue(state.archivedRevisions.isEmpty)
        XCTAssertTrue(state.pendingRecords.isEmpty)

        let profile = SyncEncryptedGrant(nonce: "nonce", ciphertext: "ciphertext", tag: "tag")
        state.pendingEncryptedDeviceProfile = profile
        state.pendingProvisioning = SyncPendingProvisioning(
            kind: .create,
            encryptedDeviceProfile: profile,
            replaceDeviceId: nil,
            recoveryCodeConfirmed: false,
            reconcileAcceptedRecordsBeforePush: false
        )
        state.pendingVaultDeletion = true
        state.lastStateRefreshAt = Date(timeIntervalSince1970: 1_783_944_000)
        let restored = try SyncJSON.decoder.decode(
            SyncPersistentState.self,
            from: SyncJSON.encoder.encode(state)
        )
        XCTAssertEqual(restored.pendingEncryptedDeviceProfile, profile)
        XCTAssertEqual(restored.pendingProvisioning, state.pendingProvisioning)
        XCTAssertTrue(restored.pendingVaultDeletion)
        XCTAssertEqual(restored.lastStateRefreshAt, state.lastStateRefreshAt)
    }

    func testPersistentStateRejectsUnknownSchemaWithoutSilentlyResettingFields() {
        let data = Data(#"{"schemaVersion":2,"serverBaseURL":"https://sync.test.workers.dev","vaultId":"vault"}"#.utf8)
        XCTAssertThrowsError(try SyncJSON.decoder.decode(SyncPersistentState.self, from: data))
    }

    func testConfiguredServiceURLDoesNotRetargetExistingVaultAcrossEnvironments() throws {
        let productionURL = "https://keystats-sync.workers.dev"
        var state = SyncPersistentState.fresh(serverBaseURL: productionURL)
        state.vaultId = "11111111-1111-4111-8111-111111111111"

        let didBind = SyncConfiguration.bind(
            configuredServiceURL: try XCTUnwrap(URL(string: "https://keystats-sync-staging.workers.dev")),
            to: &state
        )

        XCTAssertFalse(didBind)
        XCTAssertTrue(state.needsRepair)
        XCTAssertEqual(state.serverBaseURL, productionURL)
    }

    func testAtomicCredentialBundleRejectsMismatchedVaultAndDeviceBindings() throws {
        let credentials = SyncStoredCredentials(
            vaultId: "11111111-1111-4111-8111-111111111111",
            deviceId: "22222222-2222-4222-8222-222222222222",
            recoverySeed: Data(0..<16),
            deviceToken: "22222222-2222-4222-8222-222222222222.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        XCTAssertNoThrow(try credentials.validated(
            vaultId: "11111111-1111-4111-8111-111111111111",
            deviceId: "22222222-2222-4222-8222-222222222222"
        ))
        XCTAssertThrowsError(try credentials.validated(vaultId: "another-vault"))
        XCTAssertThrowsError(try credentials.validated(deviceId: "another-device"))
        XCTAssertThrowsError(try SyncStoredCredentials(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            recoverySeed: credentials.recoverySeed,
            deviceToken: "33333333-3333-4333-8333-333333333333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ).validated())
    }

    func testCredentialStorePersistsAndClearsUserDefaultsData() throws {
        let suiteName = "keystats-sync-credentials-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SyncCredentialStore(defaults: defaults)
        let credentials = SyncStoredCredentials(
            vaultId: "11111111-1111-4111-8111-111111111111",
            deviceId: "22222222-2222-4222-8222-222222222222",
            recoverySeed: Data(0..<16),
            deviceToken: "22222222-2222-4222-8222-222222222222.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
        let pendingPairing = Data([1, 2, 3])

        try store.saveCredentials(credentials)
        try store.savePendingPairing(pendingPairing)
        XCTAssertEqual(try store.credentials(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId
        ), credentials)
        XCTAssertEqual(try store.pendingPairing(), pendingPairing)

        try store.clear()
        XCTAssertThrowsError(try store.credentials())
        XCTAssertNil(try store.pendingPairing())
    }

    func testAggregatedClickTotalsSaturateInsteadOfOverflowing() {
        var daily = DailyStats()
        daily.leftClicks = Int.max
        daily.rightClicks = Int.max
        XCTAssertEqual(daily.totalClicks, Int.max)

        var allTime = AllTimeStats.initial()
        allTime.totalLeftClicks = Int.max
        allTime.totalMiddleClicks = Int.max
        XCTAssertEqual(allTime.totalClicks, Int.max)
        XCTAssertEqual(allTime.totalNonLeftClicks, Int.max)
    }
}

private final class SyncURLProtocolStub: URLProtocol {
    static var response: (statusCode: Int, body: Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.response,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private func keyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private func flippedBase64(_ value: String) -> String {
    guard var data = Data(base64Encoded: value), !data.isEmpty else { return value + "!" }
    data[0] ^= 0x01
    return data.base64EncodedString()
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<end], radix: 16) else { return nil }
            data.append(byte)
            index = end
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
