using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class TaskbarStatsView : UserControl
{
    private readonly FloatingStatsViewModel _viewModel;
    private readonly Dictionary<string, MenuItem> _primaryMetricItems = new(StringComparer.Ordinal);
    private readonly Dictionary<string, MenuItem> _secondaryMetricItems = new(StringComparer.Ordinal);
    private bool _isCleanedUp;

    public TaskbarStatsView()
    {
        InitializeComponent();
        _viewModel = new FloatingStatsViewModel();
        DataContext = _viewModel;
        RootBorder.ContextMenu = CreateContextMenu();
    }

    public void Cleanup()
    {
        if (_isCleanedUp)
        {
            return;
        }

        _isCleanedUp = true;
        RootBorder.ContextMenu = null;
        _viewModel.Cleanup();
    }

    public void SetCompactMode(bool compact)
    {
        var visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        PrimaryLabelBlock.Visibility = visibility;
        SecondaryLabelBlock.Visibility = visibility;
        RootBorder.Padding = compact ? new Thickness(3, 2, 3, 2) : new Thickness(6, 2, 6, 2);
    }

    private ContextMenu CreateContextMenu()
    {
        var menu = new ContextMenu();
        menu.Opened += (_, _) => RefreshMetricMenuState();

        var openDetailsItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.TaskbarStats_OpenDetails
        };
        openDetailsItem.Click += (_, _) => OpenDetails();
        menu.Items.Add(openDetailsItem);
        menu.Items.Add(new Separator());

        var primaryItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.TaskbarStats_PrimaryMetric
        };
        PopulateMetricMenu(primaryItem, isPrimary: true, _primaryMetricItems);
        menu.Items.Add(primaryItem);

        var secondaryItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.TaskbarStats_SecondaryMetric
        };
        PopulateMetricMenu(secondaryItem, isPrimary: false, _secondaryMetricItems);
        menu.Items.Add(secondaryItem);
        menu.Items.Add(new Separator());

        var hideItem = new MenuItem
        {
            Header = KeyStats.Properties.Strings.TaskbarStats_Hide
        };
        hideItem.Click += (_, _) => Dispatcher.BeginInvoke(new Action(() =>
            App.CurrentApp?.SetTaskbarStatsEnabled(false, "taskbar_stats_context_menu")));
        menu.Items.Add(hideItem);

        return menu;
    }

    private void PopulateMetricMenu(
        ItemsControl parent,
        bool isPrimary,
        IDictionary<string, MenuItem> destination)
    {
        foreach (var metricId in FloatingStatsViewModel.AvailableMetricIds)
        {
            var capturedMetricId = metricId;
            var item = new MenuItem
            {
                Header = FloatingStatsViewModel.GetMetricLabel(metricId),
                IsCheckable = true,
                StaysOpenOnClick = false
            };
            item.Click += (_, _) => SelectMetric(isPrimary, capturedMetricId);
            destination[metricId] = item;
            parent.Items.Add(item);
        }
    }

    private void RefreshMetricMenuState()
    {
        var primaryMetric = _viewModel.PrimaryMetricId;
        var secondaryMetric = _viewModel.SecondaryMetricId;

        foreach (var pair in _primaryMetricItems)
        {
            pair.Value.IsChecked = string.Equals(pair.Key, primaryMetric, StringComparison.Ordinal);
            pair.Value.IsEnabled = !string.Equals(pair.Key, secondaryMetric, StringComparison.Ordinal);
        }

        foreach (var pair in _secondaryMetricItems)
        {
            pair.Value.IsChecked = string.Equals(pair.Key, secondaryMetric, StringComparison.Ordinal);
            pair.Value.IsEnabled = !string.Equals(pair.Key, primaryMetric, StringComparison.Ordinal);
        }
    }

    private void SelectMetric(bool isPrimary, string metricId)
    {
        var currentMetric = isPrimary ? _viewModel.PrimaryMetricId : _viewModel.SecondaryMetricId;
        if (string.Equals(currentMetric, metricId, StringComparison.Ordinal))
        {
            return;
        }

        _viewModel.SetMetric(isPrimary, metricId);
        App.CurrentApp?.TrackClick("taskbar_stats_metric_change", new Dictionary<string, object?>
        {
            ["row"] = isPrimary ? "primary" : "secondary",
            ["metric"] = metricId
        });
    }

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left && e.ClickCount == 2)
        {
            OpenDetails();
            e.Handled = true;
        }
    }

    private static void OpenDetails()
    {
        App.CurrentApp?.TrackClick("taskbar_stats_open_details");
        App.CurrentApp?.ShowMainWindow();
    }
}
