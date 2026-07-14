using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KeyStats.Models;

namespace KeyStats.Services;

public sealed class SyncCredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("KeyStats.Sync.Credentials.v1");
    private readonly string _path;
    private readonly object _lock = new();
    private readonly JsonSerializerOptions _jsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public bool Exists => File.Exists(_path) || File.Exists(_path + ".bak");

    public SyncCredentialStore(string dataFolder)
    {
        Directory.CreateDirectory(dataFolder);
        _path = Path.Combine(dataFolder, "sync_credentials.bin");
    }

    public void Save(SyncCredentials credentials)
    {
        if (credentials.VaultSeed == null || credentials.VaultSeed.Length != 16 ||
            string.IsNullOrWhiteSpace(credentials.DeviceToken))
        {
            throw new CryptographicException("Sync credentials are incomplete.");
        }
        var hasVaultBinding = !string.IsNullOrWhiteSpace(credentials.VaultId);
        var hasDeviceBinding = !string.IsNullOrWhiteSpace(credentials.DeviceId);
        if (hasVaultBinding != hasDeviceBinding ||
            (hasDeviceBinding && !IsTokenBoundTo(credentials.DeviceToken, credentials.DeviceId)))
        {
            throw new CryptographicException("Sync credential binding is inconsistent.");
        }

        lock (_lock)
        {
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(credentials, _jsonOptions);
            var protectedBytes = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);
            SyncStateStore.WriteDurable(_path, protectedBytes);
        }
    }

    public SyncCredentials Load()
    {
        lock (_lock)
        {
            if (TryLoad(_path, out var credentials, out _)) return credentials;

            var backupPath = _path + ".bak";
            if (TryLoad(backupPath, out credentials, out var backupBytes))
            {
                try
                {
                    SyncStateStore.WriteDurable(_path, backupBytes);
                    return credentials;
                }
                catch (Exception ex)
                {
                    throw new CryptographicException(
                        "The sync credential backup could not be restored for this Windows user.", ex);
                }
            }

            throw new CryptographicException("The sync credential cannot be unlocked for this Windows user.");
        }
    }

    public SyncCredentials Load(string expectedDeviceId)
        => Load(string.Empty, expectedDeviceId);

    public SyncCredentials Load(string expectedVaultId, string expectedDeviceId)
    {
        if (string.IsNullOrWhiteSpace(expectedDeviceId))
        {
            throw new CryptographicException("The sync device binding is missing.");
        }

        var credentials = Load();
        if (!IsTokenBoundTo(credentials.DeviceToken, expectedDeviceId) ||
            (!string.IsNullOrWhiteSpace(credentials.DeviceId) &&
             !string.Equals(credentials.DeviceId, expectedDeviceId, StringComparison.Ordinal)) ||
            (!string.IsNullOrWhiteSpace(expectedVaultId) &&
             !string.IsNullOrWhiteSpace(credentials.VaultId) &&
             !string.Equals(credentials.VaultId, expectedVaultId, StringComparison.Ordinal)))
        {
            throw new CryptographicException(
                "The sync credential belongs to a different device and must be repaired.");
        }
        if (string.IsNullOrWhiteSpace(credentials.DeviceId) ||
            (!string.IsNullOrWhiteSpace(expectedVaultId) && string.IsNullOrWhiteSpace(credentials.VaultId)))
        {
            credentials.DeviceId = expectedDeviceId;
            credentials.VaultId = expectedVaultId;
            Save(credentials);
        }
        return credentials;
    }

    private static bool IsTokenBoundTo(string token, string deviceId)
    {
        var expectedPrefix = deviceId + ".";
        return token.StartsWith(expectedPrefix, StringComparison.Ordinal) &&
               token.Length > expectedPrefix.Length;
    }

    public void Delete()
    {
        lock (_lock)
        {
            TryDelete(_path);
            TryDelete(_path + ".tmp");
            TryDelete(_path + ".bak");
        }
    }

    private bool TryLoad(string path, out SyncCredentials credentials, out byte[] protectedBytes)
    {
        credentials = new SyncCredentials();
        protectedBytes = Array.Empty<byte>();
        if (!File.Exists(path)) return false;
        try
        {
            protectedBytes = File.ReadAllBytes(path);
            var plaintext = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            credentials = JsonSerializer.Deserialize<SyncCredentials>(plaintext, _jsonOptions)
                          ?? throw new CryptographicException("Sync credentials are invalid.");
            if (credentials.VaultSeed == null || credentials.VaultSeed.Length != 16 ||
                string.IsNullOrWhiteSpace(credentials.DeviceToken))
            {
                throw new CryptographicException("Sync credentials are incomplete.");
            }
            return true;
        }
        catch (Exception ex) when (
            ex is IOException || ex is UnauthorizedAccessException || ex is JsonException ||
            ex is CryptographicException || ex is NotSupportedException)
        {
            System.Diagnostics.Debug.WriteLine($"Could not load sync credential {path}: {ex.Message}");
            credentials = new SyncCredentials();
            protectedBytes = Array.Empty<byte>();
            return false;
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Could not delete {path}: {ex.Message}");
        }
    }
}
