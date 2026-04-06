using System;
using System.Windows;
using KeyStats.Helpers;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class KeyHistoryWindow : Window
{
    private readonly KeyHistoryViewModel _viewModel;

    public KeyHistoryWindow()
    {
        InitializeComponent();
        _viewModel = (KeyHistoryViewModel)DataContext;
        Loaded += OnLoaded;
        Closed += OnClosed;
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        ApplyWindowBackdrop();
        App.CurrentApp?.TrackPageView("key_history");
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
