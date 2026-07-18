using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KeyStats.Models;

namespace KeyStats.Services;

public sealed class RemoteShardCache
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("KeyStats.Sync.RemoteCache.v1");
    private readonly string _path;
    private readonly object _lock = new();
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    private CachePayload _payload = new();

    public bool NeedsRepair { get; private set; }
    public bool RecoveredFromBackup { get; private set; }
    public event Action? Changed;

    public RemoteShardCache(string dataFolder)
    {
        Directory.CreateDirectory(dataFolder);
        _path = Path.Combine(dataFolder, "sync_cache.json");
        Load();
    }

    public bool Apply(CachedRemoteRecord incoming)
    {
        ValidateIncoming(incoming);
        var key = CreateKey(incoming.DeviceId, incoming.RecordId);
        var changed = false;
        lock (_lock)
        {
            if (_payload.Tombstones.TryGetValue(incoming.RecordId, out var tombstoneRevision) &&
                tombstoneRevision >= incoming.Revision)
            {
                return false;
            }

            if (_payload.Records.TryGetValue(key, out var existing))
            {
                if (existing.Revision > incoming.Revision) return false;
                if (existing.Revision == incoming.Revision)
                {
                    if (!string.Equals(existing.CiphertextHash, incoming.CiphertextHash, StringComparison.Ordinal))
                    {
                        throw new RemoteShardConflictException();
                    }

                    if (existing.IsCurrent == incoming.IsCurrent) return false;
                    existing.IsCurrent = incoming.IsCurrent;
                    SaveLocked();
                    changed = true;
                }
            }

            if (!changed)
            {
                if (incoming.IsCurrent)
                {
                    foreach (var current in _payload.Records.Values.Where(record =>
                                 record.IsCurrent &&
                                 string.Equals(record.DeviceId, incoming.DeviceId, StringComparison.Ordinal)))
                    {
                        current.IsCurrent = false;
                    }
                }

                _payload.Records[key] = DeepClone(incoming);
                SaveLocked();
                changed = true;
            }
        }

        if (changed) Changed?.Invoke();
        return changed;
    }

    public bool ApplyTombstone(string recordId, long sequence)
    {
        if (string.IsNullOrWhiteSpace(recordId) || sequence <= 0)
        {
            return false;
        }

        var changed = false;
        lock (_lock)
        {
            if (_payload.Tombstones.TryGetValue(recordId, out var existingRevision) && existingRevision >= sequence)
            {
                return false;
            }

            _payload.Tombstones[recordId] = sequence;
            foreach (var key in _payload.Records
                         .Where(pair => string.Equals(pair.Value.RecordId, recordId, StringComparison.Ordinal))
                         .Select(pair => pair.Key)
                         .ToList())
            {
                _payload.Records.Remove(key);
            }
            SaveLocked();
            changed = true;
        }

        if (changed) Changed?.Invoke();
        return changed;
    }

    public IReadOnlyList<CachedRemoteRecord> GetAll()
    {
        lock (_lock)
        {
            return _payload.Records.Values.Select(DeepClone).ToList();
        }
    }

    public IReadOnlyCollection<string> GetAvailableDays()
    {
        lock (_lock)
        {
            return _payload.Records.Values
                .Select(record => record.Plaintext.LocalDay)
                .Where(day => !string.IsNullOrWhiteSpace(day))
                .Distinct(StringComparer.Ordinal)
                .ToList();
        }
    }

    public void ResetForBootstrap()
    {
        lock (_lock)
        {
            _payload = new CachePayload();
            NeedsRepair = false;
            SaveLocked();
        }
        Changed?.Invoke();
    }

    public void Clear()
    {
        lock (_lock)
        {
            _payload = new CachePayload();
            NeedsRepair = false;
            TryDelete(_path);
            TryDelete(_path + ".tmp");
            TryDelete(_path + ".bak");
        }
        Changed?.Invoke();
    }

    private void Load()
    {
        lock (_lock)
        {
            NeedsRepair = false;
            RecoveredFromBackup = false;
            var backupPath = _path + ".bak";
            if (TryLoad(_path, out var payload, out _))
            {
                _payload = payload;
                return;
            }

            var primaryExists = File.Exists(_path);
            if (TryLoad(backupPath, out payload, out var backupBytes))
            {
                try
                {
                    SyncStateStore.WriteDurable(_path, backupBytes);
                    _payload = payload;
                    RecoveredFromBackup = true;
                    return;
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"Could not restore remote cache backup: {ex.Message}");
                }
            }

            _payload = new CachePayload();
            NeedsRepair = primaryExists || File.Exists(backupPath);
        }
    }

    private bool TryLoad(string path, out CachePayload payload, out byte[] fileBytes)
    {
        payload = new CachePayload();
        fileBytes = Array.Empty<byte>();
        if (!File.Exists(path)) return false;
        try
        {
            fileBytes = File.ReadAllBytes(path);
            var wrapper = JsonSerializer.Deserialize<CacheFileWrapper>(fileBytes, _jsonOptions)
                          ?? throw new JsonException("Cache wrapper was empty.");
            if (wrapper.Version != 1 || string.IsNullOrWhiteSpace(wrapper.ProtectedPayload))
            {
                throw new JsonException("Unsupported cache wrapper.");
            }

            var protectedBytes = Convert.FromBase64String(wrapper.ProtectedPayload);
            var jsonBytes = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            payload = JsonSerializer.Deserialize<CachePayload>(jsonBytes, _jsonOptions)
                      ?? throw new JsonException("Cache payload was empty.");
            payload.Records ??= new Dictionary<string, CachedRemoteRecord>(StringComparer.Ordinal);
            payload.Tombstones ??= new Dictionary<string, long>(StringComparer.Ordinal);
            return true;
        }
        catch (Exception ex) when (
            ex is IOException || ex is UnauthorizedAccessException || ex is JsonException ||
            ex is FormatException || ex is CryptographicException || ex is NotSupportedException)
        {
            System.Diagnostics.Debug.WriteLine($"Could not load remote cache {path}: {ex.Message}");
            payload = new CachePayload();
            fileBytes = Array.Empty<byte>();
            return false;
        }
    }

    private void SaveLocked()
    {
        var jsonBytes = JsonSerializer.SerializeToUtf8Bytes(_payload, _jsonOptions);
        var protectedBytes = ProtectedData.Protect(jsonBytes, Entropy, DataProtectionScope.CurrentUser);
        var wrapper = new CacheFileWrapper
        {
            Version = 1,
            ProtectedPayload = Convert.ToBase64String(protectedBytes)
        };
        SyncStateStore.WriteDurable(_path, JsonSerializer.SerializeToUtf8Bytes(wrapper, _jsonOptions));
    }

    private static void ValidateIncoming(CachedRemoteRecord incoming)
    {
        if (incoming.Revision <= 0 ||
            string.IsNullOrWhiteSpace(incoming.RecordId) ||
            string.IsNullOrWhiteSpace(incoming.DeviceId) ||
            string.IsNullOrWhiteSpace(incoming.CiphertextHash) ||
            string.IsNullOrWhiteSpace(incoming.Plaintext.LocalDay))
        {
            throw new ArgumentException("Remote record is incomplete.", nameof(incoming));
        }
    }

    private static string CreateKey(string deviceId, string recordId) => deviceId + "\n" + recordId;

    private static CachedRemoteRecord DeepClone(CachedRemoteRecord value)
    {
        var source = value.Plaintext;
        return new CachedRemoteRecord
        {
            DeviceId = value.DeviceId,
            RecordId = value.RecordId,
            Revision = value.Revision,
            CiphertextHash = value.CiphertextHash,
            IsCurrent = value.IsCurrent,
            Plaintext = new CoreDaySnapshotV1
            {
                SchemaVersion = source.SchemaVersion,
                DeviceId = source.DeviceId,
                LocalDay = source.LocalDay,
                Revision = source.Revision,
                KeyPresses = source.KeyPresses,
                KeyPressCounts = new Dictionary<string, long>(source.KeyPressCounts, StringComparer.Ordinal),
                Clicks = new CoreClickSnapshotV1
                {
                    Left = source.Clicks.Left,
                    Right = source.Clicks.Right,
                    Middle = source.Clicks.Middle,
                    SideBack = source.Clicks.SideBack,
                    SideForward = source.Clicks.SideForward
                }
            }
        };
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

    private sealed class CachePayload
    {
        public Dictionary<string, CachedRemoteRecord> Records { get; set; } = new(StringComparer.Ordinal);
        public Dictionary<string, long> Tombstones { get; set; } = new(StringComparer.Ordinal);
    }

    private sealed class CacheFileWrapper
    {
        public int Version { get; set; } = 1;
        public string ProtectedPayload { get; set; } = string.Empty;
    }
}

public sealed class RemoteShardConflictException : Exception
{
    public RemoteShardConflictException()
        : base("Conflicting encrypted sync records were received.")
    {
    }
}
