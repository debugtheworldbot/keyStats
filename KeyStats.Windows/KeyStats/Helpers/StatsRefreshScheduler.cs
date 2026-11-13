using System;
using System.Windows.Threading;

namespace KeyStats.Helpers;

/// <summary>
/// Coalesces background statistics notifications into bounded UI refreshes.
/// Create, activate and dispose on the owning UI dispatcher.
/// </summary>
internal sealed class StatsRefreshScheduler : IDisposable
{
    private readonly object _lock = new();
    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer _timer;
    private readonly Action<bool> _refresh;
    private bool _active;
    private bool _disposed;
    private bool _scheduled;
    private bool _fullRefresh;

    public StatsRefreshScheduler(Action<bool> refresh)
    {
        _refresh = refresh;
        _timer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(250)
        };
        _timer.Tick += OnTick;
    }

    public void SetActive(bool active)
    {
        _dispatcher.VerifyAccess();
        lock (_lock)
        {
            if (_disposed) return;
            _active = active;
            if (active) return;
            _scheduled = false;
            _fullRefresh = false;
        }
        _timer.Stop();
    }

    /// <summary>May be called from input worker threads; never blocks on the UI.</summary>
    public void Request(bool fullRefresh = true)
    {
        lock (_lock)
        {
            if (!_active || _disposed) return;
            _fullRefresh |= fullRefresh;
            if (_scheduled) return;
            _scheduled = true;
        }

        if (!_dispatcher.HasShutdownStarted)
            _dispatcher.BeginInvoke(new Action(StartTimer), DispatcherPriority.Background);
    }

    private void StartTimer()
    {
        lock (_lock)
        {
            if (!_active || _disposed || !_scheduled || _timer.IsEnabled) return;
            // Keep the first deadline so continuous input cannot postpone refreshes.
            _timer.Start();
        }
    }

    private void OnTick(object? sender, EventArgs e)
    {
        _timer.Stop();
        bool fullRefresh;
        lock (_lock)
        {
            if (!_active || _disposed || !_scheduled) return;
            fullRefresh = _fullRefresh;
            _fullRefresh = false;
            _scheduled = false;
        }
        _refresh(fullRefresh);
    }

    public void Dispose()
    {
        _dispatcher.VerifyAccess();
        SetActive(false);
        lock (_lock) _disposed = true;
        _timer.Tick -= OnTick;
    }
}
