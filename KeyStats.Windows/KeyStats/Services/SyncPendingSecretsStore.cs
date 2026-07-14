using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KeyStats.Models;

namespace KeyStats.Services;

/// <summary>
/// Persists an in-flight create, recovery, or pairing credential bundle with
/// Windows DPAPI so an accepted request can be replayed exactly after a lost
/// response without exposing seeds, tokens, or X25519 private keys.
/// </summary>
public sealed class SyncPendingSecretsStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("KeyStats.Sync.Pending.v1");
    private readonly string _path;
    private readonly object _lock = new();
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public bool Exists => File.Exists(_path) || File.Exists(_path + ".bak");

    public SyncPendingSecretsStore(string dataFolder)
    {
        Directory.CreateDirectory(dataFolder);
        _path = Path.Combine(dataFolder, "sync_pending_credentials.bin");
    }

    public void Save(PendingSyncSecrets value)
    {
        Validate(value);
        lock (_lock)
        {
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(value, _jsonOptions);
            var protectedBytes = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);
            SyncStateStore.WriteDurable(_path, protectedBytes);
        }
    }

    public PendingSyncSecrets Load()
    {
        lock (_lock)
        {
            if (TryLoad(_path, out var value, out _)) return value;
            var backupPath = _path + ".bak";
            if (TryLoad(backupPath, out value, out var protectedBytes))
            {
                SyncStateStore.WriteDurable(_path, protectedBytes);
                return value;
            }
            throw new CryptographicException("Pending sync credentials cannot be unlocked for this Windows user.");
        }
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

    private bool TryLoad(string path, out PendingSyncSecrets value, out byte[] protectedBytes)
    {
        value = new PendingSyncSecrets();
        protectedBytes = Array.Empty<byte>();
        if (!File.Exists(path)) return false;
        try
        {
            protectedBytes = File.ReadAllBytes(path);
            var plaintext = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            value = JsonSerializer.Deserialize<PendingSyncSecrets>(plaintext, _jsonOptions)
                    ?? throw new CryptographicException("Pending sync credentials are empty.");
            Validate(value);
            return true;
        }
        catch (Exception ex) when (
            ex is IOException || ex is UnauthorizedAccessException || ex is JsonException ||
            ex is CryptographicException || ex is NotSupportedException)
        {
            System.Diagnostics.Debug.WriteLine($"Could not load pending sync credentials {path}: {ex.Message}");
            value = new PendingSyncSecrets();
            protectedBytes = Array.Empty<byte>();
            return false;
        }
    }

    private static void Validate(PendingSyncSecrets value)
    {
        if (value.Version != 1 || string.IsNullOrWhiteSpace(value.Kind) ||
            string.IsNullOrWhiteSpace(value.DeviceId))
        {
            throw new CryptographicException("Pending sync credential metadata is incomplete.");
        }
        if (value.Kind == "create" || value.Kind == "recover" || value.Kind == "pairing-final")
        {
            var prefix = value.DeviceId + ".";
            if (value.VaultSeed == null || value.VaultSeed.Length != 16 ||
                string.IsNullOrWhiteSpace(value.DeviceToken) ||
                !value.DeviceToken.StartsWith(prefix, StringComparison.Ordinal) ||
                value.DeviceToken.Length <= prefix.Length)
            {
                throw new CryptographicException("Pending sync credentials are incomplete.");
            }
            if ((value.Kind == "create" || value.Kind == "pairing-final") &&
                string.IsNullOrWhiteSpace(value.VaultId))
            {
                throw new CryptographicException("Pending sync vault binding is missing.");
            }
            if (!string.IsNullOrWhiteSpace(value.ReplaceDeviceId) &&
                !string.Equals(value.ReplaceDeviceId, value.DeviceId, StringComparison.Ordinal))
            {
                throw new CryptographicException("Pending recovery replacement binding is inconsistent.");
            }
            if (value.Kind == "pairing-final" &&
                (string.IsNullOrWhiteSpace(value.PairingSessionId) ||
                 string.IsNullOrWhiteSpace(value.PairingCompletionToken) ||
                 value.PairingPrivateKey == null || value.PairingPrivateKey.Length != 32 ||
                 value.PairingPublicKey == null || value.PairingPublicKey.Length != 32))
            {
                throw new CryptographicException("Pending pairing completion credentials are incomplete.");
            }
        }
        if (value.Kind == "pairing")
        {
            if (value.PairingPrivateKey == null || value.PairingPrivateKey.Length != 32 ||
                value.PairingPublicKey == null || value.PairingPublicKey.Length != 32 ||
                string.IsNullOrWhiteSpace(value.PairingSessionId) ||
                string.IsNullOrWhiteSpace(value.PairingCode) ||
                string.IsNullOrWhiteSpace(value.PairingCompletionToken) ||
                !value.PairingExpiresAt.HasValue)
            {
                throw new CryptographicException("Pending pairing credentials are incomplete.");
            }
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
            System.Diagnostics.Debug.WriteLine($"Could not delete pending sync credential {path}: {ex.Message}");
        }
    }
}
