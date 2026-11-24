using System;
using System.Windows;
using KeyStats.Helpers;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class AppStatsWindow : Window
{
    private readonly AppStatsViewModel _viewModel;

    public AppStatsWindow()
    {
        InitializeComponent();
        _viewModel = (AppStatsViewModel)DataContext;
        Loaded += OnLoaded;
        Closed += OnClosed;
        IsVisibleChanged += (_, _) => UpdateRefreshState();
        StateChanged += (_, _) => UpdateRefreshState();
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("app_stats");
    }

    private void UpdateRefreshState()
    {
        _viewModel.SetActive(IsVisible && WindowState != WindowState.Minimized);
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(ApplyWindowBackdrop));
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        _viewModel.Cleanup();
    }

    private void ApplyWindowBackdrop()
    {
        WindowBackdropHelper.Apply(this, NativeInterop.DwmSystemBackdropType.TransientWindow);
    }
}
