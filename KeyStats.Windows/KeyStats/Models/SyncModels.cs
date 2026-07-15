using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace KeyStats.Models;

public static class SyncProtocol
{
    public const int SchemaVersion = 1;
    public const int MaximumDevices = 5;
    public const int MaximumKeyEntries = 512;
    public const int MaximumKeyNameBytes = 64;
    public const int MaximumSnapshotBytes = 64 * 1024;
    public const int MaximumArchivesPerRequest = 16;
    public const int MaximumBootstrapRequests = 256;
    public const int MaximumBootstrapArchives = MaximumArchivesPerRequest * MaximumBootstrapRequests;
    public const int MaximumHistoryPagesPerAttempt = 256;
    public const int MaximumAutomaticFailuresPerUtcDay = 3;
    public static readonly TimeSpan ManualSyncInterval = TimeSpan.FromHours(1);
    public static readonly TimeSpan AutomaticSyncInterval = TimeSpan.FromHours(24);
}

public sealed class CoreDaySnapshotV1
{
    public int SchemaVersion { get; set; } = SyncProtocol.SchemaVersion;
    public string DeviceId { get; set; } = string.Empty;
    public string LocalDay { get; set; } = string.Empty;
    public long Revision { get; set; }
    public long KeyPresses { get; set; }
    public Dictionary<string, long> KeyPressCounts { get; set; } = new(StringComparer.Ordinal);
    public CoreClickSnapshotV1 Clicks { get; set; } = new();
}

public sealed class CoreClickSnapshotV1
{
    public long Left { get; set; }
    public long Right { get; set; }
    public long Middle { get; set; }
    public long SideBack { get; set; }
    public long SideForward { get; set; }
}

public sealed class EncryptedSyncRecord
{
    public int SchemaVersion { get; set; } = SyncProtocol.SchemaVersion;
    public string RecordId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public long Revision { get; set; }
    public string Nonce { get; set; } = string.Empty;
    public string Ciphertext { get; set; } = string.Empty;
    public string Tag { get; set; } = string.Empty;
    public string CiphertextHash { get; set; } = string.Empty;
}

public sealed class SyncRequest
{
    public string Reason { get; set; } = "manual";
    public long HistoryCursor { get; set; }
    public EncryptedSyncRecord? CurrentSnapshot { get; set; }
    public List<EncryptedSyncRecord> Archives { get; set; } = new();
    public PairingEncryptedPayload? EncryptedDeviceProfile { get; set; }
    public bool BootstrapComplete { get; set; } = true;
}

public sealed class SyncResponse
{
    public DateTime ServerTime { get; set; }
    public DateTime NextAllowedSyncAt { get; set; }
    public int RemainingDailySyncs { get; set; }
    public int ActiveDeviceCount { get; set; }
    public List<EncryptedSyncRecord> CurrentSnapshots { get; set; } = new();
    public List<SyncHistoryChange> HistoryChanges { get; set; } = new();
    public bool HistoryHasMore { get; set; }
    public long Cursor { get; set; }
    public List<DeviceSummary> Devices { get; set; } = new();
}

public sealed class SyncHistoryChange
{
    public long Cursor { get; set; }
    public EncryptedSyncRecord? Record { get; set; }
    public string RecordId { get; set; } = string.Empty;
    public bool Tombstone { get; set; }
}

public sealed class HistoryResponse
{
    public List<SyncHistoryChange> Changes { get; set; } = new();
    public long Cursor { get; set; }
    public bool HasMore { get; set; }
}

public sealed class CreateVaultRequest
{
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceToken { get; set; } = string.Empty;
    public string RecoveryAuthToken { get; set; } = string.Empty;
    public PairingEncryptedPayload EncryptedDeviceProfile { get; set; } = new();
}

public sealed class CreateVaultResponse
{
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceToken { get; set; } = string.Empty;
    public int ActiveDeviceCount { get; set; } = 1;
    public DateTime ServerTime { get; set; }
}

public sealed class CreatePairingSessionRequest
{
    public string DeviceId { get; set; } = string.Empty;
    public string JoiningPublicKey { get; set; } = string.Empty;
}

public sealed class CreatePairingSessionResponse
{
    public string SessionId { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public string CompletionToken { get; set; } = string.Empty;
    public DateTime ExpiresAt { get; set; }
}

public sealed class JoinPairingSessionRequest
{
    public string ApprovingPublicKey { get; set; } = string.Empty;
}

public sealed class JoinPairingSessionResponse
{
    public string SessionId { get; set; } = string.Empty;
    public string JoiningDeviceId { get; set; } = string.Empty;
    public string JoiningPublicKey { get; set; } = string.Empty;
    public bool ReplacedExistingDevice { get; set; }
    public DateTime? ExpiresAt { get; set; }
}

public sealed class ApprovePairingSessionRequest
{
    public string ApprovingPublicKey { get; set; } = string.Empty;
    public PairingEncryptedPayload EncryptedGrant { get; set; } = new();
    public string NewDeviceToken { get; set; } = string.Empty;
}

public sealed class PairingEncryptedPayload
{
    public string Nonce { get; set; } = string.Empty;
    public string Ciphertext { get; set; } = string.Empty;
    public string Tag { get; set; } = string.Empty;
}

public sealed class CompletePairingSessionResponse
{
    public bool Pending { get; set; }
    public bool RequiresProfile { get; set; }
    public string? ApprovingPublicKey { get; set; }
    public PairingEncryptedPayload? EncryptedGrant { get; set; }
    public bool ReplacedExistingDevice { get; set; }
    public int? ActiveDeviceCount { get; set; }
    public DateTime? ServerTime { get; set; }
}

public sealed class CompletePairingSessionRequest
{
    public string CompletionToken { get; set; } = string.Empty;
    public PairingEncryptedPayload? EncryptedDeviceProfile { get; set; }
}

public sealed class RecoverVaultRequest
{
    public string RecoveryAuthToken { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceToken { get; set; } = string.Empty;
    public string? ReplaceDeviceId { get; set; }
}

public sealed class RecoverVaultResponse
{
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceToken { get; set; } = string.Empty;
    public int ActiveDeviceCount { get; set; }
    public DateTime ServerTime { get; set; }
    public long Cursor { get; set; }
    public EncryptedSyncRecord? CurrentSnapshot { get; set; }
}

public sealed class SyncStateResponse
{
    public DateTime ServerTime { get; set; }
    public int ActiveDeviceCount { get; set; }
    public List<DeviceSummary> Devices { get; set; } = new();
    public List<EncryptedSyncRecord> CurrentSnapshots { get; set; } = new();
}

public sealed class PairingProvisioningPayload
{
    public string VaultId { get; set; } = string.Empty;
    public string RecoverySeed { get; set; } = string.Empty;
    public string? DeviceToken { get; set; }
}

public sealed class DeviceProfileV1
{
    public int SchemaVersion { get; set; } = SyncProtocol.SchemaVersion;
    public string DisplayName { get; set; } = string.Empty;
    public string Platform { get; set; } = "windows";
}

public sealed class DeviceSummary
{
    public string DeviceId { get; set; } = string.Empty;
    public PairingEncryptedPayload? EncryptedDeviceProfile { get; set; }
    public DateTime? LastSyncAt { get; set; }
    public bool Revoked { get; set; }
}

public sealed class SyncDeviceInfo
{
    public string DeviceId { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Platform { get; set; } = string.Empty;
    public DateTime? LastSyncAt { get; set; }
    public bool IsCurrent { get; set; }
    public bool IsRevoked { get; set; }
}

public sealed class RecoveryReplacementOption
{
    public string DeviceId { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Platform { get; set; } = string.Empty;
}

public sealed class SyncState
{
    public int Version { get; set; } = 1;
    public bool IsEnabled { get; set; }
    public bool NeedsRepair { get; set; }
    public bool NeedsBootstrap { get; set; }
    public bool NeedsHistoryBootstrap { get; set; }
    public bool NeedsStateRefreshBeforeBootstrap { get; set; }
    public string InstallationDeviceId { get; set; } = string.Empty;
    public string? ReplacementCandidateDeviceId { get; set; }
    public string? PendingProvisioningKind { get; set; }
    public string? PendingProvisioningDisplayName { get; set; }
    public string? PendingProvisioningReplaceDeviceId { get; set; }
    public string? PendingBootstrapReason { get; set; }
    public bool PendingVaultDeletion { get; set; }
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public string Platform { get; set; } = "windows";
    public DateTime? LastSuccessfulSyncAtUtc { get; set; }
    public DateTime? NextAllowedSyncAtUtc { get; set; }
    public DateTime? NextAutomaticSyncAtUtc { get; set; }
    public DateTime? LastStateRefreshAtUtc { get; set; }
    public int RemainingDailySyncs { get; set; } = 8;
    public string? QuotaUtcDay { get; set; }
    public int ActiveDeviceCount { get; set; }
    public long HistoryCursor { get; set; }
    public string? AutomaticFailureUtcDay { get; set; }
    public int AutomaticFailureCount { get; set; }
    public PairingEncryptedPayload? PendingEncryptedDeviceProfile { get; set; }
    public EncryptedSyncRecord? LastAcknowledgedCurrentSnapshot { get; set; }
    public Dictionary<string, LocalSyncRecordState> LocalRecords { get; set; } = new(StringComparer.Ordinal);
    public List<SyncDeviceInfo> Devices { get; set; } = new();
}

public sealed class LocalSyncRecordState
{
    public string LocalDay { get; set; } = string.Empty;
    public string ContentHash { get; set; } = string.Empty;
    public long Revision { get; set; }
    public bool IsPending { get; set; }
    public bool UploadedAsArchive { get; set; }
    public EncryptedSyncRecord Envelope { get; set; } = new();
}

public sealed class CachedRemoteRecord
{
    public string RecordId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public long Revision { get; set; }
    public string CiphertextHash { get; set; } = string.Empty;
    public bool IsCurrent { get; set; }
    public CoreDaySnapshotV1 Plaintext { get; set; } = new();
}

public sealed class PairingSessionContext
{
    [JsonIgnore]
    public byte[] PrivateKey { get; set; } = Array.Empty<byte>();
    public byte[] PublicKey { get; set; } = Array.Empty<byte>();
    public string SessionId { get; set; } = string.Empty;
    public string Code { get; set; } = string.Empty;
    public string CompletionToken { get; set; } = string.Empty;
    public string ProposedDeviceId { get; set; } = string.Empty;
    public DateTime ExpiresAt { get; set; }
}

public sealed class PairingApprovalContext
{
    public byte[] PrivateKey { get; set; } = Array.Empty<byte>();
    public byte[] PublicKey { get; set; } = Array.Empty<byte>();
    public byte[] PeerPublicKey { get; set; } = Array.Empty<byte>();
    public string SessionId { get; set; } = string.Empty;
    public string NewDeviceId { get; set; } = string.Empty;
    public string SafetyCode { get; set; } = string.Empty;
    public DateTime ExpiresAt { get; set; }
}

public sealed class PairingCompletionPreview
{
    public PairingSessionContext Context { get; set; } = new();
    public CompletePairingSessionResponse Response { get; set; } = new();
    public string SafetyCode { get; set; } = string.Empty;
}

public sealed class SyncCredentials
{
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public byte[] VaultSeed { get; set; } = Array.Empty<byte>();
    public string DeviceToken { get; set; } = string.Empty;
}

public sealed class PendingSyncSecrets
{
    public int Version { get; set; } = 1;
    public string Kind { get; set; } = string.Empty;
    public string VaultId { get; set; } = string.Empty;
    public string DeviceId { get; set; } = string.Empty;
    public byte[] VaultSeed { get; set; } = Array.Empty<byte>();
    public string DeviceToken { get; set; } = string.Empty;
    public string? ReplaceDeviceId { get; set; }
    public byte[] PairingPrivateKey { get; set; } = Array.Empty<byte>();
    public byte[] PairingPublicKey { get; set; } = Array.Empty<byte>();
    public string PairingSessionId { get; set; } = string.Empty;
    public string PairingCode { get; set; } = string.Empty;
    public string PairingCompletionToken { get; set; } = string.Empty;
    public DateTime? PairingExpiresAt { get; set; }
}

public sealed class SyncStatusSnapshot
{
    public bool IsServiceConfigured { get; set; }
    public bool IsEnabled { get; set; }
    public bool NeedsRepair { get; set; }
    public bool NeedsBootstrap { get; set; }
    public bool BlocksImport { get; set; }
    public bool IsBusy { get; set; }
    public bool CanSync { get; set; }
    public bool CanManualSync { get; set; }
    public bool CanRetryBootstrap { get; set; }
    public int ActiveDeviceCount { get; set; }
    public DateTime? LastSuccessfulSyncAtUtc { get; set; }
    public DateTime? NextAllowedSyncAtUtc { get; set; }
    public int RemainingDailySyncs { get; set; }
    public int? SyncCompletedDays { get; set; }
    public int? SyncTotalDays { get; set; }
    public string? LastError { get; set; }
}
