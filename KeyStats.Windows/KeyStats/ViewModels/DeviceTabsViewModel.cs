using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using KeyStats.Models;
using KeyStats.Services;

namespace KeyStats.ViewModels;

public sealed class DeviceTabItem
{
    public string Label { get; init; } = "";
    public StatsDisplaySelection Selection { get; init; } = StatsDisplaySelection.Local;
}

/// <summary>
/// Shared device tab state for popover, heatmap, and app stats views.
/// </summary>
public sealed class DeviceTabsViewModel : ViewModelBase
{
    private bool _isVisible;
    private int _selectedIndex;
    private StatsDisplaySelection[] _selections = Array.Empty<StatsDisplaySelection>();

    public ObservableCollection<DeviceTabItem> Tabs { get; } = new();

    public bool IsVisible
    {
        get => _isVisible;
        private set => SetProperty(ref _isVisible, value);
    }

    public int SelectedIndex
    {
        get => _selectedIndex;
        set
        {
            if (!SetProperty(ref _selectedIndex, value)) return;
            ApplySelectionAtIndex(value);
        }
    }

    public DeviceTabsViewModel()
    {
        RefreshTabs();
        CloudSyncManager.Instance.StateChanged += OnCloudSyncStateChanged;
    }

    public void RefreshTabs()
    {
        var available = CloudSyncManager.Instance.IsCloudDisplayAvailable;
        IsVisible = available;
        Tabs.Clear();

        if (!available)
        {
            _selections = Array.Empty<StatsDisplaySelection>();
            SelectedIndex = 0;
            return;
        }

        var displayTabs = CloudSyncManager.Instance.DisplayTabs();
        _selections = displayTabs.Select(t => t.Selection).ToArray();
        foreach (var tab in displayTabs)
        {
            Tabs.Add(new DeviceTabItem { Label = tab.Label, Selection = tab.Selection });
        }

        var validated = CloudSyncManager.Instance.ValidatedDisplaySelection();
        var index = Array.FindIndex(_selections, s => s.Equals(validated));
        _selectedIndex = index >= 0 ? index : 0;
        OnPropertyChanged(nameof(SelectedIndex));
    }

    public void Cleanup()
    {
        CloudSyncManager.Instance.StateChanged -= OnCloudSyncStateChanged;
    }

    private void OnCloudSyncStateChanged()
    {
        Application.Current?.Dispatcher.Invoke(RefreshTabs);
    }

    private void ApplySelectionAtIndex(int index)
    {
        if (index < 0 || index >= _selections.Length) return;
        CloudSyncManager.Instance.DisplaySelection = _selections[index];
    }
}
