using System;

namespace KeyStats.Models;

public sealed class SyncProgress
{
    public int CompletedDays { get; private set; }
    public int TotalDays { get; }

    public SyncProgress(int totalDays)
    {
        TotalDays = Math.Max(0, totalDays);
    }

    public void Advance(int days)
    {
        CompletedDays = Math.Min(TotalDays, CompletedDays + Math.Max(0, days));
    }
}
