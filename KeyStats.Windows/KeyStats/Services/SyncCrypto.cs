using System;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using KeyStats.Models;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Crypto.Engines;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace KeyStats.Services;

public sealed class SyncCrypto
{
    private const string CrockfordAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    private const string DataKeyLabel = "vault-encryption-v1";
    private const string IndexKeyLabel = "record-index-v1";
    private const string RecoveryAuthLabel = "recovery-auth-v1";
    private const string PairingWrapLabel = "pairing-wrap-v1";
    private static readonly byte[] RecoveryChecksumPrefix = Encoding.UTF8.GetBytes("keystats-recovery-checksum-v1");
    private static readonly byte[] PairingSafetyPrefix = Encoding.ASCII.GetBytes("pairing-safety-code-v1");
    private readonly SecureRandom _secureRandom = new();

    public byte[] GenerateVaultSeed()
    {
        return GenerateRandomBytes(16);
    }

    public byte[] GenerateRandomBytes(int length)
    {
        var bytes = new byte[length];
        _secureRandom.NextBytes(bytes);
        return bytes;
    }

    public string GenerateTokenSecret()
    {
        return Base64UrlEncode(GenerateRandomBytes(32));
    }

    public byte[] DeriveDataKey(byte[] vaultSeed) => DeriveKey(vaultSeed, DataKeyLabel);
    public byte[] DeriveIndexKey(byte[] vaultSeed) => DeriveKey(vaultSeed, IndexKeyLabel);
    public byte[] DeriveRecoveryAuth(byte[] vaultSeed) => DeriveKey(vaultSeed, RecoveryAuthLabel);

    public string CreateRecordId(byte[] indexKey, string deviceId, string localDay)
    {
        using var hmac = new HMACSHA256(indexKey);
        var input = Encoding.UTF8.GetBytes(deviceId + "\n" + localDay);
        return Base64UrlEncode(hmac.ComputeHash(input));
    }

    public EncryptedSyncRecord EncryptRecord(
        byte[] dataKey,
        string vaultId,
        string deviceId,
        string recordId,
        long revision,
        byte[] plaintext)
    {
        if (plaintext == null || plaintext.Length > SyncProtocol.MaximumSnapshotBytes)
        {
            throw new CryptographicException("Sync snapshot exceeds the encryption size limit.");
        }
        var nonce = GenerateRandomBytes(12);
        var aad = CreateRecordAad(vaultId, deviceId, recordId, revision);
        var encrypted = EncryptAesGcm(dataKey, nonce, plaintext, aad);

        return new EncryptedSyncRecord
        {
            SchemaVersion = SyncProtocol.SchemaVersion,
            RecordId = recordId,
            DeviceId = deviceId,
            Revision = revision,
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(encrypted.Ciphertext),
            Tag = Convert.ToBase64String(encrypted.Tag),
            CiphertextHash = Sha256Base64Url(nonce.Concat(encrypted.Ciphertext).Concat(encrypted.Tag).ToArray())
        };
    }

    public byte[] DecryptRecord(byte[] dataKey, string vaultId, EncryptedSyncRecord record)
    {
        if (record.SchemaVersion != SyncProtocol.SchemaVersion || record.Revision <= 0)
        {
            throw new CryptographicException("Unsupported encrypted record.");
        }

        var nonce = DecodeBase64(record.Nonce, 12, "nonce");
        var ciphertext = DecodeBase64(record.Ciphertext, null, "ciphertext");
        if (ciphertext.Length > SyncProtocol.MaximumSnapshotBytes)
        {
            throw new CryptographicException("Encrypted snapshot exceeds the size limit.");
        }
        var tag = DecodeBase64(record.Tag, 16, "tag");
        var expectedHash = Sha256Base64Url(nonce.Concat(ciphertext).Concat(tag).ToArray());
        if (!FixedTimeEquals(expectedHash, record.CiphertextHash))
        {
            throw new CryptographicException("Encrypted record hash mismatch.");
        }

        var aad = CreateRecordAad(vaultId, record.DeviceId, record.RecordId, record.Revision);
        return DecryptAesGcm(dataKey, nonce, ciphertext, tag, aad);
    }

    public PairingSessionContext CreatePairingContext(string proposedDeviceId)
    {
        var privateKey = new X25519PrivateKeyParameters(_secureRandom);
        var publicKey = privateKey.GeneratePublicKey();
        return new PairingSessionContext
        {
            PrivateKey = privateKey.GetEncoded(),
            PublicKey = publicKey.GetEncoded(),
            ProposedDeviceId = proposedDeviceId
        };
    }

    public byte[] DerivePairingWrapKey(byte[] privateKeyBytes, byte[] peerPublicKeyBytes)
    {
        if (privateKeyBytes.Length != 32 || peerPublicKeyBytes.Length != 32)
        {
            throw new CryptographicException("Invalid X25519 key material.");
        }

        var privateKey = new X25519PrivateKeyParameters(privateKeyBytes, 0);
        var publicKey = new X25519PublicKeyParameters(peerPublicKeyBytes, 0);
        var sharedSecret = new byte[32];
        privateKey.GenerateSecret(publicKey, sharedSecret, 0);
        return DeriveKey(sharedSecret, PairingWrapLabel);
    }

    public string CreatePairingSafetyCode(
        byte[] localPublicKey,
        byte[] peerPublicKey,
        byte[] privateKey)
    {
        var localFirst = CompareBytes(localPublicKey, peerPublicKey) <= 0;
        var first = localFirst ? localPublicKey : peerPublicKey;
        var second = localFirst ? peerPublicKey : localPublicKey;

        var privateParameters = new X25519PrivateKeyParameters(privateKey, 0);
        var peerParameters = new X25519PublicKeyParameters(peerPublicKey, 0);
        var sharedSecret = new byte[32];
        privateParameters.GenerateSecret(peerParameters, sharedSecret, 0);

        var input = new byte[PairingSafetyPrefix.Length + first.Length + second.Length + sharedSecret.Length];
        var offset = 0;
        Buffer.BlockCopy(PairingSafetyPrefix, 0, input, offset, PairingSafetyPrefix.Length);
        offset += PairingSafetyPrefix.Length;
        Buffer.BlockCopy(first, 0, input, offset, first.Length);
        offset += first.Length;
        Buffer.BlockCopy(second, 0, input, offset, second.Length);
        offset += second.Length;
        Buffer.BlockCopy(sharedSecret, 0, input, offset, sharedSecret.Length);

        using var sha = SHA256.Create();
        var digest = sha.ComputeHash(input);
        var number = ((uint)digest[0] << 24) |
                     ((uint)digest[1] << 16) |
                     ((uint)digest[2] << 8) |
                     digest[3];
        return (number % 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
    }

    public PairingEncryptedPayload EncryptPairingPayload(byte[] wrapKey, string sessionId, byte[] plaintext)
    {
        var nonce = GenerateRandomBytes(12);
        var aad = Encoding.UTF8.GetBytes(SyncProtocol.SchemaVersion + "\n" + sessionId);
        var encrypted = EncryptAesGcm(wrapKey, nonce, plaintext, aad);
        return new PairingEncryptedPayload
        {
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(encrypted.Ciphertext),
            Tag = Convert.ToBase64String(encrypted.Tag)
        };
    }

    public PairingEncryptedPayload EncryptDeviceProfile(
        byte[] dataKey,
        string vaultId,
        string deviceId,
        byte[] plaintext)
    {
        var nonce = GenerateRandomBytes(12);
        var aad = Encoding.UTF8.GetBytes("profile-v1\n" + vaultId + "\n" + deviceId);
        var encrypted = EncryptAesGcm(dataKey, nonce, plaintext, aad);
        return new PairingEncryptedPayload
        {
            Nonce = Convert.ToBase64String(nonce),
            Ciphertext = Convert.ToBase64String(encrypted.Ciphertext),
            Tag = Convert.ToBase64String(encrypted.Tag)
        };
    }

    public byte[] DecryptDeviceProfile(
        byte[] dataKey,
        string vaultId,
        string deviceId,
        PairingEncryptedPayload payload)
    {
        var nonce = DecodeBase64(payload.Nonce, 12, "nonce");
        var ciphertext = DecodeBase64(payload.Ciphertext, null, "ciphertext");
        var tag = DecodeBase64(payload.Tag, 16, "tag");
        var aad = Encoding.UTF8.GetBytes("profile-v1\n" + vaultId + "\n" + deviceId);
        return DecryptAesGcm(dataKey, nonce, ciphertext, tag, aad);
    }

    public byte[] DecryptPairingPayload(byte[] wrapKey, string sessionId, PairingEncryptedPayload payload)
    {
        var nonce = DecodeBase64(payload.Nonce, 12, "nonce");
        var ciphertext = DecodeBase64(payload.Ciphertext, null, "ciphertext");
        var tag = DecodeBase64(payload.Tag, 16, "tag");
        var aad = Encoding.UTF8.GetBytes(SyncProtocol.SchemaVersion + "\n" + sessionId);
        return DecryptAesGcm(wrapKey, nonce, ciphertext, tag, aad);
    }

    public string EncodeRecoveryCode(byte[] seed)
    {
        if (seed.Length != 16)
        {
            throw new ArgumentException("Recovery seed must be 16 bytes.", nameof(seed));
        }

        var seedPart = EncodeCrockford(seed, 26);
        var checksumInput = new byte[RecoveryChecksumPrefix.Length + seed.Length];
        Buffer.BlockCopy(RecoveryChecksumPrefix, 0, checksumInput, 0, RecoveryChecksumPrefix.Length);
        Buffer.BlockCopy(seed, 0, checksumInput, RecoveryChecksumPrefix.Length, seed.Length);
        using var sha = SHA256.Create();
        var digest = sha.ComputeHash(checksumInput);
        var checksumValue = ((digest[0] << 8) | digest[1]) >> 6;
        var checksum = string.Concat(
            CrockfordAlphabet[(checksumValue >> 5) & 31],
            CrockfordAlphabet[checksumValue & 31]);
        return GroupRecoveryCode(seedPart + checksum);
    }

    public bool TryDecodeRecoveryCode(string? recoveryCode, out byte[] seed)
    {
        seed = Array.Empty<byte>();
        var normalized = NormalizeRecoveryCode(recoveryCode);
        if (normalized.Length != 28)
        {
            return false;
        }

        if (!TryDecodeCrockford(normalized.Substring(0, 26), 16, out var decodedSeed))
        {
            return false;
        }

        var expected = NormalizeRecoveryCode(EncodeRecoveryCode(decodedSeed));
        if (!FixedTimeEquals(expected, normalized))
        {
            return false;
        }

        seed = decodedSeed;
        return true;
    }

    public static string Sha256Base64(byte[] value)
    {
        using var sha = SHA256.Create();
        return Convert.ToBase64String(sha.ComputeHash(value));
    }

    public static string Sha256Base64Url(byte[] value)
    {
        using var sha = SHA256.Create();
        return Base64UrlEncode(sha.ComputeHash(value));
    }

    public static string Sha256Base64Url(string value)
    {
        using var sha = SHA256.Create();
        return Base64UrlEncode(sha.ComputeHash(Encoding.UTF8.GetBytes(value)));
    }

    public static string Base64UrlEncode(byte[] value)
    {
        return Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static byte[] CreateRecordAad(
        string vaultId,
        string deviceId,
        string recordId,
        long revision)
    {
        return Encoding.UTF8.GetBytes(
            SyncProtocol.SchemaVersion + "\n" +
            vaultId + "\n" +
            deviceId + "\n" +
            recordId + "\n" +
            revision.ToString(CultureInfo.InvariantCulture));
    }

    private static byte[] DeriveKey(byte[] inputKeyMaterial, string info)
    {
        var generator = new HkdfBytesGenerator(new Sha256Digest());
        generator.Init(new HkdfParameters(inputKeyMaterial, Array.Empty<byte>(), Encoding.ASCII.GetBytes(info)));
        var result = new byte[32];
        generator.GenerateBytes(result, 0, result.Length);
        return result;
    }

    private static (byte[] Ciphertext, byte[] Tag) EncryptAesGcm(
        byte[] key,
        byte[] nonce,
        byte[] plaintext,
        byte[] aad)
    {
        var cipher = new GcmBlockCipher(new AesEngine());
        cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
        var output = new byte[cipher.GetOutputSize(plaintext.Length)];
        var length = cipher.ProcessBytes(plaintext, 0, plaintext.Length, output, 0);
        length += cipher.DoFinal(output, length);
        if (length < 16)
        {
            throw new CryptographicException("AES-GCM did not produce an authentication tag.");
        }

        var ciphertextLength = length - 16;
        var ciphertext = new byte[ciphertextLength];
        var tag = new byte[16];
        Buffer.BlockCopy(output, 0, ciphertext, 0, ciphertextLength);
        Buffer.BlockCopy(output, ciphertextLength, tag, 0, tag.Length);
        return (ciphertext, tag);
    }

    private static byte[] DecryptAesGcm(
        byte[] key,
        byte[] nonce,
        byte[] ciphertext,
        byte[] tag,
        byte[] aad)
    {
        var input = new byte[ciphertext.Length + tag.Length];
        Buffer.BlockCopy(ciphertext, 0, input, 0, ciphertext.Length);
        Buffer.BlockCopy(tag, 0, input, ciphertext.Length, tag.Length);

        try
        {
            var cipher = new GcmBlockCipher(new AesEngine());
            cipher.Init(false, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
            var output = new byte[cipher.GetOutputSize(input.Length)];
            var length = cipher.ProcessBytes(input, 0, input.Length, output, 0);
            length += cipher.DoFinal(output, length);
            if (length == output.Length)
            {
                return output;
            }

            return output.Take(length).ToArray();
        }
        catch (InvalidCipherTextException ex)
        {
            throw new CryptographicException("AES-GCM authentication failed.", ex);
        }
    }

    private static byte[] DecodeBase64(string value, int? expectedLength, string label)
    {
        try
        {
            var decoded = Convert.FromBase64String(value);
            if (expectedLength.HasValue && decoded.Length != expectedLength.Value)
            {
                throw new CryptographicException($"Invalid {label} length.");
            }
            return decoded;
        }
        catch (FormatException ex)
        {
            throw new CryptographicException($"Invalid {label} encoding.", ex);
        }
    }

    private static int CompareBytes(byte[] left, byte[] right)
    {
        var length = Math.Min(left.Length, right.Length);
        for (var i = 0; i < length; i++)
        {
            var comparison = left[i].CompareTo(right[i]);
            if (comparison != 0) return comparison;
        }
        return left.Length.CompareTo(right.Length);
    }

    private static bool FixedTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.ASCII.GetBytes(left ?? string.Empty);
        var rightBytes = Encoding.ASCII.GetBytes(right ?? string.Empty);
        var difference = leftBytes.Length ^ rightBytes.Length;
        var length = Math.Max(leftBytes.Length, rightBytes.Length);
        for (var i = 0; i < length; i++)
        {
            var leftValue = i < leftBytes.Length ? leftBytes[i] : (byte)0;
            var rightValue = i < rightBytes.Length ? rightBytes[i] : (byte)0;
            difference |= leftValue ^ rightValue;
        }
        return difference == 0;
    }

    private static string EncodeCrockford(byte[] bytes, int outputLength)
    {
        var builder = new StringBuilder(outputLength);
        var accumulator = 0;
        var bitCount = 0;
        foreach (var value in bytes)
        {
            accumulator = (accumulator << 8) | value;
            bitCount += 8;
            while (bitCount >= 5)
            {
                bitCount -= 5;
                builder.Append(CrockfordAlphabet[(accumulator >> bitCount) & 31]);
                accumulator &= (1 << bitCount) - 1;
            }
        }

        if (bitCount > 0)
        {
            builder.Append(CrockfordAlphabet[(accumulator << (5 - bitCount)) & 31]);
        }

        return builder.ToString().PadRight(outputLength, '0').Substring(0, outputLength);
    }

    private static bool TryDecodeCrockford(string value, int byteLength, out byte[] bytes)
    {
        bytes = new byte[byteLength];
        var accumulator = 0;
        var bitCount = 0;
        var outputIndex = 0;
        foreach (var character in value)
        {
            var index = CrockfordAlphabet.IndexOf(character);
            if (index < 0)
            {
                bytes = Array.Empty<byte>();
                return false;
            }

            accumulator = (accumulator << 5) | index;
            bitCount += 5;
            while (bitCount >= 8 && outputIndex < byteLength)
            {
                bitCount -= 8;
                bytes[outputIndex++] = (byte)((accumulator >> bitCount) & 0xff);
                accumulator &= (1 << bitCount) - 1;
            }
        }

        return outputIndex == byteLength && accumulator == 0;
    }

    private static string NormalizeRecoveryCode(string? value)
    {
        var builder = new StringBuilder();
        foreach (var raw in (value ?? string.Empty).ToUpperInvariant())
        {
            if (raw == '-' || char.IsWhiteSpace(raw)) continue;
            builder.Append(raw switch
            {
                'O' => '0',
                'I' or 'L' => '1',
                _ => raw
            });
        }
        return builder.ToString();
    }

    private static string GroupRecoveryCode(string normalized)
    {
        return string.Join("-", Enumerable.Range(0, 7).Select(index => normalized.Substring(index * 4, 4)));
    }
}
