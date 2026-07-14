using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KeyStats.Models;
using KeyStats.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace KeyStats.Sync.Tests;

[TestClass]
public sealed class SyncCryptoFixtureTests
{
    [TestMethod]
    public void RecoveryAndDerivedKeys_MatchSharedFixture()
    {
        var root = LoadFixture();
        var recovery = root.GetProperty("recovery");
        var derivedKeys = root.GetProperty("derivedKeys");
        var seed = HexToBytes(RequiredString(recovery, "seedHex"));
        var crypto = new SyncCrypto();

        Assert.AreEqual(RequiredString(recovery, "formattedCode"), crypto.EncodeRecoveryCode(seed));
        Assert.IsTrue(crypto.TryDecodeRecoveryCode(
            RequiredString(recovery, "formattedCode").ToLowerInvariant(),
            out var decodedSeed));
        CollectionAssert.AreEqual(seed, decodedSeed);
        Assert.AreEqual(
            RequiredString(derivedKeys, "encryptionKeyHex"),
            ToHex(crypto.DeriveDataKey(seed)));
        Assert.AreEqual(
            RequiredString(derivedKeys, "recordIndexKeyHex"),
            ToHex(crypto.DeriveIndexKey(seed)));
        Assert.AreEqual(
            RequiredString(derivedKeys, "recoveryAuthKeyHex"),
            ToHex(crypto.DeriveRecoveryAuth(seed)));
        Assert.AreEqual(
            RequiredString(derivedKeys, "recoveryCredentialBase64Url"),
            SyncCrypto.Base64UrlEncode(crypto.DeriveRecoveryAuth(seed)));
    }

    [TestMethod]
    public void RecordIdAndAesGcmDecryption_MatchSharedFixture()
    {
        var root = LoadFixture();
        var derivedKeys = root.GetProperty("derivedKeys");
        var vector = root.GetProperty("record");
        var crypto = new SyncCrypto();
        var indexKey = HexToBytes(RequiredString(derivedKeys, "recordIndexKeyHex"));
        var dataKey = HexToBytes(RequiredString(derivedKeys, "encryptionKeyHex"));
        var deviceId = RequiredString(vector, "deviceId");
        var recordId = RequiredString(vector, "recordId");

        Assert.AreEqual(
            recordId,
            crypto.CreateRecordId(indexKey, deviceId, RequiredString(vector, "localDay")));

        var encryptedRecord = CreateEncryptedRecord(vector);
        var plaintext = crypto.DecryptRecord(
            dataKey,
            RequiredString(vector, "vaultId"),
            encryptedRecord);
        Assert.AreEqual(RequiredString(vector, "plaintextUtf8"), Encoding.UTF8.GetString(plaintext));

        encryptedRecord.Revision++;
        Assert.ThrowsExactly<CryptographicException>(() => crypto.DecryptRecord(
            dataKey,
            RequiredString(vector, "vaultId"),
            encryptedRecord));
    }

    [TestMethod]
    public void PairingDerivationSafetyCodeAndAesGcm_MatchSharedFixture()
    {
        var pairing = LoadFixture().GetProperty("pairing");
        var crypto = new SyncCrypto();
        var joiningPrivateKey = HexToBytes(RequiredString(pairing, "joiningPrivateKeyHex"));
        var joiningPublicKey = Convert.FromBase64String(RequiredString(pairing, "joiningPublicKeyBase64"));
        var approvingPublicKey = Convert.FromBase64String(RequiredString(pairing, "approvingPublicKeyBase64"));
        var wrapKey = crypto.DerivePairingWrapKey(joiningPrivateKey, approvingPublicKey);

        Assert.AreEqual(RequiredString(pairing, "wrapKeyHex"), ToHex(wrapKey));
        Assert.AreEqual(
            RequiredString(pairing, "safetyCode"),
            crypto.CreatePairingSafetyCode(joiningPublicKey, approvingPublicKey, joiningPrivateKey));

        var payload = new PairingEncryptedPayload
        {
            Nonce = RequiredString(pairing, "nonceBase64"),
            Ciphertext = RequiredString(pairing, "ciphertextBase64"),
            Tag = RequiredString(pairing, "tagBase64")
        };
        var plaintext = crypto.DecryptPairingPayload(
            wrapKey,
            RequiredString(pairing, "sessionId"),
            payload);
        Assert.AreEqual(RequiredString(pairing, "plaintextUtf8"), Encoding.UTF8.GetString(plaintext));
    }

    private static EncryptedSyncRecord CreateEncryptedRecord(JsonElement vector)
    {
        return new EncryptedSyncRecord
        {
            SchemaVersion = 1,
            RecordId = RequiredString(vector, "recordId"),
            DeviceId = RequiredString(vector, "deviceId"),
            Revision = vector.GetProperty("revision").GetInt64(),
            Nonce = RequiredString(vector, "nonceBase64"),
            Ciphertext = RequiredString(vector, "ciphertextBase64"),
            Tag = RequiredString(vector, "tagBase64"),
            CiphertextHash = RequiredString(vector, "ciphertextHashBase64Url")
        };
    }

    private static JsonElement LoadFixture()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "crypto-vectors.json");
        using var document = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
        return document.RootElement.Clone();
    }

    private static string RequiredString(JsonElement parent, string propertyName)
    {
        return parent.GetProperty(propertyName).GetString()
               ?? throw new InvalidDataException($"Fixture property {propertyName} is missing.");
    }

    private static byte[] HexToBytes(string value)
    {
        if (value.Length % 2 != 0) throw new FormatException("Hex input must have an even length.");
        var result = new byte[value.Length / 2];
        for (var index = 0; index < result.Length; index++)
        {
            result[index] = Convert.ToByte(value.Substring(index * 2, 2), 16);
        }
        return result;
    }

    private static string ToHex(byte[] value)
    {
        return BitConverter.ToString(value).Replace("-", string.Empty).ToLowerInvariant();
    }
}
