import CryptoKit
import Foundation
import Security

struct SyncDerivedKeys {
    let encryption: SymmetricKey
    let recordIndex: SymmetricKey
    let recoveryAuth: SymmetricKey
}

struct SyncPairingKeyPair {
    fileprivate let privateKey: Curve25519.KeyAgreement.PrivateKey

    init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    var publicKey: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    var rawPrivateKey: Data { privateKey.rawRepresentation }
}

struct SyncPairingGrant: Codable, Equatable {
    let vaultId: String
    let recoverySeed: String
    let deviceToken: String?
}

struct SyncDeviceProfileV1: Codable, Equatable {
    let schemaVersion: Int
    let displayName: String
    let platform: String

    init(displayName: String, platform: String) {
        self.schemaVersion = 1
        self.displayName = String(displayName.prefix(128))
        self.platform = String(platform.prefix(128))
    }
}

struct SyncEncryptedGrant: Codable, Equatable {
    let nonce: String
    let ciphertext: String
    let tag: String
}

enum SyncCrypto {
    private static let recoveryAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let checksumDomain = Data("keystats-recovery-checksum-v1".utf8)

    static func makeRecoverySeed() throws -> Data {
        var data = Data(count: 16)
        let result = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw SyncCryptoError.randomGenerationFailed(result) }
        return data
    }

    static func makeDeviceToken(deviceId: String) throws -> String {
        var secret = Data(count: 32)
        let status = secret.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SyncCryptoError.randomGenerationFailed(status) }
        return "\(deviceId).\(secret.base64URLEncodedString())"
    }

    static func recoveryCode(from seed: Data) throws -> String {
        guard seed.count == 16 else { throw SyncValidationError.invalidRecoveryCode }
        let payload = encodeCrockford(seed, outputCharacterCount: 26)
        var checksumInput = checksumDomain
        checksumInput.append(seed)
        let digest = Data(SHA256.hash(data: checksumInput))
        let checksumValue = (Int(digest[0]) << 2) | (Int(digest[1]) >> 6)
        let checksum = String(recoveryAlphabet[(checksumValue >> 5) & 31])
            + String(recoveryAlphabet[checksumValue & 31])
        return payload + checksum
    }

    static func recoverySeed(from code: String) throws -> Data {
        let normalized = code
            .uppercased()
            .filter { $0 != "-" && !$0.isWhitespace }
            .map(normalizeCrockfordCharacter)
        guard normalized.count == 28 else { throw SyncValidationError.invalidRecoveryCode }
        let payload = String(normalized.prefix(26))
        let checksum = String(normalized.suffix(2))
        guard let seed = decodeCrockford(payload, expectedByteCount: 16) else {
            throw SyncValidationError.invalidRecoveryCode
        }
        let canonical = try recoveryCode(from: seed)
        guard canonical.prefix(26) == payload, canonical.suffix(2) == checksum else {
            throw SyncValidationError.invalidRecoveryCode
        }
        return seed
    }

    static func formattedRecoveryCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: min(4, code.distance(from: start, to: code.endIndex)))
            return String(code[start..<end])
        }.joined(separator: "-")
    }

    static func deriveKeys(seed: Data) -> SyncDerivedKeys {
        let input = SymmetricKey(data: seed)
        return SyncDerivedKeys(
            encryption: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: Data(),
                info: Data("vault-encryption-v1".utf8),
                outputByteCount: 32
            ),
            recordIndex: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: Data(),
                info: Data("record-index-v1".utf8),
                outputByteCount: 32
            ),
            recoveryAuth: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: Data(),
                info: Data("recovery-auth-v1".utf8),
                outputByteCount: 32
            )
        )
    }

    static func recoveryCredential(seed: Data) -> String {
        let key = deriveKeys(seed: seed).recoveryAuth
        return Data(key.withUnsafeBytes { Data($0) }).base64URLEncodedString()
    }

    static func encryptDeviceProfile(
        _ profile: SyncDeviceProfileV1,
        vaultId: String,
        deviceId: String,
        seed: Data
    ) throws -> SyncEncryptedGrant {
        guard profile.displayName.lengthOfBytes(using: .utf8) <= 128,
              profile.platform.lengthOfBytes(using: .utf8) <= 128 else {
            throw SyncValidationError.invalidSnapshot
        }
        let sealed = try AES.GCM.seal(
            SyncJSON.encoder.encode(profile),
            using: deriveKeys(seed: seed).encryption,
            authenticating: Data("profile-v1\n\(vaultId)\n\(deviceId)".utf8)
        )
        return SyncEncryptedGrant(
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    static func decryptDeviceProfile(
        _ envelope: SyncEncryptedGrant,
        vaultId: String,
        deviceId: String,
        seed: Data
    ) throws -> SyncDeviceProfileV1 {
        guard let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw SyncValidationError.authenticationFailed
        }
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let data = try AES.GCM.open(
                sealed,
                using: deriveKeys(seed: seed).encryption,
                authenticating: Data("profile-v1\n\(vaultId)\n\(deviceId)".utf8)
            )
            let profile = try SyncJSON.decoder.decode(SyncDeviceProfileV1.self, from: data)
            guard profile.schemaVersion == 1,
                  profile.displayName.lengthOfBytes(using: .utf8) <= 128,
                  profile.platform.lengthOfBytes(using: .utf8) <= 128 else {
                throw SyncValidationError.authenticationFailed
            }
            return profile
        } catch {
            throw SyncValidationError.authenticationFailed
        }
    }

    static func recordId(vaultId: String, deviceId: String, localDay: String, seed: Data) -> String {
        let key = deriveKeys(seed: seed).recordIndex
        let input = Data("\(deviceId)\n\(localDay)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key)).base64URLEncodedString()
    }

    static func contentHash(_ snapshot: CoreDaySnapshotV1) throws -> String {
        var content = snapshot
        content = CoreDaySnapshotV1(
            deviceId: content.deviceId,
            localDay: content.localDay,
            revision: 0,
            keyPresses: content.keyPresses,
            keyPressCounts: content.keyPressCounts,
            clicks: content.clicks
        )
        return Data(SHA256.hash(data: try SyncJSON.encoder.encode(content))).base64URLEncodedString()
    }

    static func encrypt(
        snapshot: CoreDaySnapshotV1,
        vaultId: String,
        seed: Data
    ) throws -> EncryptedSyncRecordV1 {
        let validated = try snapshot.validated()
        let recordId = recordId(
            vaultId: vaultId,
            deviceId: validated.deviceId,
            localDay: validated.localDay,
            seed: seed
        )
        let aad = authenticatedData(
            vaultId: vaultId,
            deviceId: validated.deviceId,
            recordId: recordId,
            revision: validated.revision
        )
        let plaintext = try SyncJSON.encoder.encode(validated)
        let sealed = try AES.GCM.seal(plaintext, using: deriveKeys(seed: seed).encryption, authenticating: aad)
        let nonceData = sealed.nonce.withUnsafeBytes { Data($0) }
        var hashInput = nonceData
        hashInput.append(sealed.ciphertext)
        hashInput.append(sealed.tag)
        return EncryptedSyncRecordV1(
            recordId: recordId,
            deviceId: validated.deviceId,
            revision: validated.revision,
            nonce: nonceData.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString(),
            ciphertextHash: Data(SHA256.hash(data: hashInput)).base64URLEncodedString()
        )
    }

    static func decrypt(
        record: EncryptedSyncRecordV1,
        vaultId: String,
        seed: Data
    ) throws -> CoreDaySnapshotV1 {
        guard record.schemaVersion == SyncConstants.schemaVersion,
              let nonceData = Data(base64Encoded: record.nonce), nonceData.count == 12,
              let ciphertext = Data(base64Encoded: record.ciphertext),
              let tag = Data(base64Encoded: record.tag), tag.count == 16,
              ciphertext.count <= SyncConstants.maximumSnapshotBytes else {
            throw SyncValidationError.invalidSnapshot
        }
        var hashInput = nonceData
        hashInput.append(ciphertext)
        hashInput.append(tag)
        let expectedHash = Data(SHA256.hash(data: hashInput)).base64URLEncodedString()
        guard constantTimeEqual(expectedHash, record.ciphertextHash) else {
            throw SyncValidationError.authenticationFailed
        }
        let aad = authenticatedData(
            vaultId: vaultId,
            deviceId: record.deviceId,
            recordId: record.recordId,
            revision: record.revision
        )
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: deriveKeys(seed: seed).encryption, authenticating: aad)
        } catch {
            throw SyncValidationError.authenticationFailed
        }
        guard plaintext.count <= SyncConstants.maximumSnapshotBytes else {
            throw SyncValidationError.snapshotTooLarge
        }
        let snapshot = try SyncJSON.decoder.decode(CoreDaySnapshotV1.self, from: plaintext)
        guard snapshot.deviceId == record.deviceId,
              snapshot.revision == record.revision,
              record.recordId == recordId(
                vaultId: vaultId,
                deviceId: snapshot.deviceId,
                localDay: snapshot.localDay,
                seed: seed
              ) else {
            throw SyncValidationError.authenticationFailed
        }
        return try snapshot.validated()
    }

    static func pairingSafetyCode(
        ownKeyPair: SyncPairingKeyPair,
        peerPublicKey: String,
        sessionId: String
    ) throws -> String {
        let (secret, peerData) = try pairingSecret(ownKeyPair: ownKeyPair, peerPublicKey: peerPublicKey)
        let ownData = ownKeyPair.privateKey.publicKey.rawRepresentation
        let publicKeys = [ownData, peerData].sorted { $0.lexicographicallyPrecedes($1) }
        var transcript = Data("pairing-safety-code-v1".utf8)
        transcript.append(publicKeys[0])
        transcript.append(publicKeys[1])
        transcript.append(secret.withUnsafeBytes { Data($0) })
        let digest = Data(SHA256.hash(data: transcript))
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", number)
    }

    static func encryptPairingGrant(
        _ grant: SyncPairingGrant,
        ownKeyPair: SyncPairingKeyPair,
        peerPublicKey: String,
        sessionId: String
    ) throws -> SyncEncryptedGrant {
        let (secret, _) = try pairingSecret(ownKeyPair: ownKeyPair, peerPublicKey: peerPublicKey)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("pairing-wrap-v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(
            try SyncJSON.encoder.encode(grant),
            using: key,
            authenticating: Data("1\n\(sessionId)".utf8)
        )
        return SyncEncryptedGrant(
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
    }

    static func decryptPairingGrant(
        _ grant: SyncEncryptedGrant,
        ownKeyPair: SyncPairingKeyPair,
        peerPublicKey: String,
        sessionId: String
    ) throws -> SyncPairingGrant {
        guard let nonceData = Data(base64Encoded: grant.nonce), nonceData.count == 12,
              let ciphertext = Data(base64Encoded: grant.ciphertext),
              let tag = Data(base64Encoded: grant.tag) else {
            throw SyncValidationError.authenticationFailed
        }
        let (secret, _) = try pairingSecret(ownKeyPair: ownKeyPair, peerPublicKey: peerPublicKey)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("pairing-wrap-v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        do {
            let data = try AES.GCM.open(sealed, using: key, authenticating: Data("1\n\(sessionId)".utf8))
            return try SyncJSON.decoder.decode(SyncPairingGrant.self, from: data)
        } catch {
            throw SyncValidationError.authenticationFailed
        }
    }

    private static func pairingSecret(
        ownKeyPair: SyncPairingKeyPair,
        peerPublicKey: String
    ) throws -> (SharedSecret, Data) {
        guard let data = Data(base64Encoded: peerPublicKey) else { throw SyncValidationError.authenticationFailed }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        return (try ownKeyPair.privateKey.sharedSecretFromKeyAgreement(with: peer), data)
    }

    private static func authenticatedData(
        vaultId: String,
        deviceId: String,
        recordId: String,
        revision: Int64
    ) -> Data {
        Data("1\n\(vaultId)\n\(deviceId)\n\(recordId)\n\(revision)".utf8)
    }

    private static func encodeCrockford(_ data: Data, outputCharacterCount: Int) -> String {
        var result = ""
        var accumulator = 0
        var bitCount = 0
        for byte in data {
            accumulator = (accumulator << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                result.append(recoveryAlphabet[(accumulator >> bitCount) & 31])
                accumulator &= (1 << bitCount) - 1
            }
        }
        if bitCount > 0 {
            result.append(recoveryAlphabet[(accumulator << (5 - bitCount)) & 31])
        }
        return String(result.prefix(outputCharacterCount))
    }

    private static func decodeCrockford(_ value: String, expectedByteCount: Int) -> Data? {
        var result = Data()
        var accumulator = 0
        var bitCount = 0
        for character in value {
            guard let index = recoveryAlphabet.firstIndex(of: normalizeCrockfordCharacter(character)) else { return nil }
            accumulator = (accumulator << 5) | index
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8((accumulator >> bitCount) & 0xff))
                accumulator &= (1 << bitCount) - 1
            }
        }
        guard result.count == expectedByteCount else { return nil }
        return result
    }

    private static func normalizeCrockfordCharacter(_ character: Character) -> Character {
        switch character {
        case "O": return "0"
        case "I", "L": return "1"
        default: return character
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

enum SyncCryptoError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case credentialStorage
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed: return NSLocalizedString("sync.error.randomGenerationFailed", comment: "")
        case .credentialStorage: return NSLocalizedString("sync.error.credentialStorage", comment: "")
        case .missingCredentials: return NSLocalizedString("sync.error.missingCredentials", comment: "")
        }
    }
}

struct SyncStoredCredentials: Codable, Equatable {
    let schemaVersion: Int
    let vaultId: String
    let deviceId: String
    let recoverySeed: Data
    let deviceToken: String

    init(vaultId: String, deviceId: String, recoverySeed: Data, deviceToken: String) {
        self.schemaVersion = 1
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.recoverySeed = recoverySeed
        self.deviceToken = deviceToken
    }

    func validated(vaultId expectedVaultId: String? = nil, deviceId expectedDeviceId: String? = nil) throws -> SyncStoredCredentials {
        guard schemaVersion == 1,
              !vaultId.isEmpty,
              !deviceId.isEmpty,
              recoverySeed.count == 16,
              deviceToken.hasPrefix("\(deviceId)."),
              expectedVaultId == nil || vaultId == expectedVaultId,
              expectedDeviceId == nil || deviceId == expectedDeviceId else {
            throw SyncCryptoError.missingCredentials
        }
        return self
    }
}

final class SyncCredentialStore {
    static let shared = SyncCredentialStore()

    private let defaults: UserDefaults
    private let credentialsKey = "sync.credentials.v1"
    private let pendingPairingKey = "sync.pendingPairing.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func saveCredentials(_ credentials: SyncStoredCredentials) throws {
        _ = try credentials.validated()
        do {
            defaults.set(try SyncJSON.encoder.encode(credentials), forKey: credentialsKey)
        } catch {
            throw SyncCryptoError.credentialStorage
        }
    }

    func credentials(vaultId: String? = nil, deviceId: String? = nil) throws -> SyncStoredCredentials {
        guard let data = defaults.data(forKey: credentialsKey),
              let credentials = try? SyncJSON.decoder.decode(SyncStoredCredentials.self, from: data) else {
            throw SyncCryptoError.missingCredentials
        }
        return try credentials.validated(vaultId: vaultId, deviceId: deviceId)
    }

    func clear() throws {
        defaults.removeObject(forKey: credentialsKey)
        defaults.removeObject(forKey: pendingPairingKey)
    }

    func savePendingPairing(_ data: Data) throws {
        defaults.set(data, forKey: pendingPairingKey)
    }

    func pendingPairing() throws -> Data? {
        defaults.data(forKey: pendingPairingKey)
    }

    func clearPendingPairing() throws {
        defaults.removeObject(forKey: pendingPairingKey)
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
