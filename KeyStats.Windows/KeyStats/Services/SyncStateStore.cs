using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using KeyStats.Models;

namespace KeyStats.Services;

public sealed class SyncStateStore
{
    private readonly string _path;
    private readonly object _lock = new();
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    public bool NeedsRepair { get; private set; }
    public bool RecoveredFromBackup { get; private set; }

    public SyncStateStore(string dataFolder)
    {
        Directory.CreateDirectory(dataFolder);
        _path = Path.Combine(dataFolder, "sync_state.json");
    }

    public SyncState Load()
    {
        lock (_lock)
        {
            NeedsRepair = false;
            RecoveredFromBackup = false;
            var backupPath = _path + ".bak";
            if (TryLoad(_path, out var state, out _))
            {
                return state;
            }

            var primaryExists = File.Exists(_path);
            if (TryLoad(backupPath, out state, out var backupBytes))
            {
                try
                {
                    // File.Replace keeps the unreadable primary as .bak, so recovery does
                    // not discard the evidence that the primary file was damaged.
                    WriteDurable(_path, backupBytes);
                    RecoveredFromBackup = true;
                    return state;
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"Could not restore sync state backup: {ex.Message}");
                }
            }

            if (!primaryExists && !File.Exists(backupPath)) return NewState();

            NeedsRepair = true;
            var repairState = NewState();
            repairState.NeedsRepair = true;
            return repairState;
        }
    }

    public void Save(SyncState state)
    {
        lock (_lock)
        {
            if (NeedsRepair)
            {
                throw new InvalidOperationException("Damaged sync state must be repaired explicitly before saving.");
            }
            Normalize(state);
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(state, _jsonOptions));
            WriteDurable(_path, bytes);
        }
    }

    public void ReplaceAfterRepair(SyncState state)
    {
        lock (_lock)
        {
            Normalize(state);
            if (!state.IsEnabled || state.NeedsRepair || string.IsNullOrWhiteSpace(state.VaultId) ||
                string.IsNullOrWhiteSpace(state.DeviceId))
            {
                throw new InvalidOperationException("Replacement sync state is incomplete.");
            }
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(state, _jsonOptions));
            WriteDurable(_path, bytes);
            NeedsRepair = false;
        }
    }

    public void Delete()
    {
        lock (_lock)
        {
            TryDelete(_path);
            TryDelete(_path + ".tmp");
            TryDelete(_path + ".bak");
            NeedsRepair = false;
            RecoveredFromBackup = false;
        }
    }

    internal static void WriteDurable(string path, byte[] bytes)
    {
        var tempPath = path + ".tmp";
        var backupPath = path + ".bak";
        using (var stream = new FileStream(
                   tempPath,
                   FileMode.Create,
                   FileAccess.Write,
                   FileShare.None,
                   4096,
                   FileOptions.WriteThrough))
        {
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
        }

        if (File.Exists(path))
        {
            File.Replace(tempPath, path, backupPath);
        }
        else
        {
            File.Move(tempPath, path);
        }
    }

    private static SyncState NewState()
    {
        return new SyncState
        {
            LocalRecords = new Dictionary<string, LocalSyncRecordState>(StringComparer.Ordinal),
            Devices = new List<SyncDeviceInfo>()
        };
    }

    private bool TryLoad(string path, out SyncState state, out byte[] bytes)
    {
        state = NewState();
        bytes = Array.Empty<byte>();
        if (!File.Exists(path)) return false;
        try
        {
            bytes = File.ReadAllBytes(path);
            state = JsonSerializer.Deserialize<SyncState>(bytes, _jsonOptions)
                    ?? throw new JsonException("Sync state was empty.");
            Normalize(state);
            if (state.Version != 1 ||
                (state.IsEnabled &&
                 (string.IsNullOrWhiteSpace(state.VaultId) ||
                  string.IsNullOrWhiteSpace(state.DeviceId) ||
                  state.ActiveDeviceCount < 1)))
            {
                throw new JsonException("Sync state metadata is incomplete.");
            }
            return true;
        }
        catch (Exception ex) when (
            ex is IOException || ex is UnauthorizedAccessException || ex is JsonException ||
            ex is NotSupportedException)
        {
            System.Diagnostics.Debug.WriteLine($"Could not load sync state {path}: {ex.Message}");
            state = NewState();
            bytes = Array.Empty<byte>();
            return false;
        }
    }

    private static void Normalize(SyncState state)
    {
        state.LocalRecords ??= new Dictionary<string, LocalSyncRecordState>(StringComparer.Ordinal);
        state.Devices ??= new List<SyncDeviceInfo>();
        state.DeviceName ??= string.Empty;
        state.DeviceId ??= string.Empty;
        state.VaultId ??= string.Empty;
        state.InstallationDeviceId ??= string.Empty;
        state.ReplacementCandidateDeviceId = string.IsNullOrWhiteSpace(state.ReplacementCandidateDeviceId)
            ? null
            : state.ReplacementCandidateDeviceId;
        state.PendingProvisioningKind = string.IsNullOrWhiteSpace(state.PendingProvisioningKind)
            ? null
            : state.PendingProvisioningKind;
        state.PendingProvisioningDisplayName ??= string.Empty;
        state.Platform = "windows";
        state.ActiveDeviceCount = Math.Max(0, state.ActiveDeviceCount);
        state.HistoryCursor = Math.Max(0, state.HistoryCursor);
        state.RemainingDailySyncs = Math.Max(0, state.RemainingDailySyncs);
        state.AutomaticFailureCount = Math.Max(0, state.AutomaticFailureCount);
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
