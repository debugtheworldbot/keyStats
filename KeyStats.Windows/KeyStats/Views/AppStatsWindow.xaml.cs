using System;
using System.Windows;
using System.Windows.Interop;
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
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowTitleBarTheme();
        App.CurrentApp?.TrackPageView("app_stats");
    }

    private void OnThemeChanged()
    {
        Dispatcher.BeginInvoke(new Action(ApplyWindowTitleBarTheme));
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        _viewModel.Cleanup();
    }

    private void ApplyWindowTitleBarTheme()
    {
        var handle = new WindowInteropHelper(this).Handle;
        NativeInterop.TrySetImmersiveDarkMode(handle, ThemeManager.Instance.IsDarkTheme);
    }
}
