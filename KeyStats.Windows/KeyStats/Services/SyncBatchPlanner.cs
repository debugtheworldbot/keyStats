using System;
using System.Collections.Generic;
using System.Linq;
using KeyStats.Models;

namespace KeyStats.Services;

public static class SyncBatchPlanner
{
    public const int MaximumArchivesPerRequest = SyncProtocol.MaximumArchivesPerRequest;

    public static IReadOnlyList<SyncRequest> CreateBatches(
        SyncRequest source,
        EncryptedSyncRecord? lastAcknowledgedCurrentSnapshot = null)
    {
        if (source == null) throw new ArgumentNullException(nameof(source));

        var archives = source.Archives ?? new List<EncryptedSyncRecord>();
        if (!IsSupportedReason(source.Reason))
        {
            throw new ArgumentException("Unsupported sync reason.", nameof(source));
        }

        if (!IsBootstrapReason(source.Reason))
        {
            var orderedArchives = PrioritizePreviousCurrentArchive(
                source.CurrentSnapshot,
                archives,
                lastAcknowledgedCurrentSnapshot);
            return new[]
            {
                CreateBatch(
                    source,
                    orderedArchives.Take(MaximumArchivesPerRequest),
                    bootstrapComplete: true,
                    includeFinalPayload: true)
            };
        }

        if (archives.Count > SyncProtocol.MaximumBootstrapArchives)
        {
            throw new InvalidOperationException(
                $"An initial sync can upload at most {SyncProtocol.MaximumBootstrapArchives} archives.");
        }

        var batchCount = Math.Max(
            1,
            (archives.Count + MaximumArchivesPerRequest - 1) / MaximumArchivesPerRequest);
        var result = new List<SyncRequest>(batchCount);
        for (var index = 0; index < batchCount; index++)
        {
            var isFinal = index == batchCount - 1;
            result.Add(CreateBatch(
                source,
                archives.Skip(index * MaximumArchivesPerRequest).Take(MaximumArchivesPerRequest),
                bootstrapComplete: isFinal,
                includeFinalPayload: isFinal));
        }
        return result;
    }

    public static bool IsBootstrapReason(string? reason)
    {
        return string.Equals(reason, "bootstrap", StringComparison.Ordinal) ||
               string.Equals(reason, "recovery", StringComparison.Ordinal) ||
               string.Equals(reason, "pairing", StringComparison.Ordinal);
    }

    private static bool IsSupportedReason(string? reason)
    {
        return IsBootstrapReason(reason) ||
               string.Equals(reason, "manual", StringComparison.Ordinal) ||
               string.Equals(reason, "automatic", StringComparison.Ordinal);
    }

    private static IEnumerable<EncryptedSyncRecord> PrioritizePreviousCurrentArchive(
        EncryptedSyncRecord? nextCurrent,
        IEnumerable<EncryptedSyncRecord> archives,
        EncryptedSyncRecord? previousCurrent)
    {
        if (nextCurrent == null || previousCurrent == null ||
            string.Equals(nextCurrent.RecordId, previousCurrent.RecordId, StringComparison.Ordinal))
        {
            return archives;
        }

        // The server must archive the exact previously acknowledged current
        // envelope before changing the current record ID. A newer local
        // revision for that day remains pending for the next ordinary sync.
        return new[] { previousCurrent }.Concat(
            archives.Where(record =>
                !string.Equals(record.RecordId, previousCurrent.RecordId, StringComparison.Ordinal)));
    }

    private static SyncRequest CreateBatch(
        SyncRequest source,
        IEnumerable<EncryptedSyncRecord> archives,
        bool bootstrapComplete,
        bool includeFinalPayload)
    {
        return new SyncRequest
        {
            Reason = source.Reason,
            HistoryCursor = source.HistoryCursor,
            CurrentSnapshot = includeFinalPayload ? source.CurrentSnapshot : null,
            Archives = archives.ToList(),
            EncryptedDeviceProfile = includeFinalPayload ? source.EncryptedDeviceProfile : null,
            BootstrapComplete = bootstrapComplete
        };
    }
}
