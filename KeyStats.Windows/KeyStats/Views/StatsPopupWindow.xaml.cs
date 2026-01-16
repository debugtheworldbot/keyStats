using System.Windows;
using System.Windows.Forms;
using KeyStats.ViewModels;

namespace KeyStats.Views;

public partial class StatsPopupWindow : Window
{
    private readonly StatsPopupViewModel _viewModel;

    public StatsPopupWindow()
    {
        InitializeComponent();

        _viewModel = (StatsPopupViewModel)DataContext;
        _viewModel.RequestClose += () => Close();

        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        PositionNearTray();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _viewModel.Cleanup();
    }

    private void Window_Deactivated(object sender, EventArgs e)
    {
        Close();
    }

    private void PositionNearTray()
    {
        // Get the working area of the screen with the taskbar
        var screen = Screen.PrimaryScreen;
        if (screen == null) return;

        var workingArea = screen.WorkingArea;
        var screenBounds = screen.Bounds;

        // Determine taskbar position
        double left, top;

        if (workingArea.Bottom < screenBounds.Bottom)
        {
            // Taskbar at bottom
            left = workingArea.Right - Width - 10;
            top = workingArea.Bottom - Height - 10;
        }
        else if (workingArea.Top > screenBounds.Top)
        {
            // Taskbar at top
            left = workingArea.Right - Width - 10;
            top = workingArea.Top + 10;
        }
        else if (workingArea.Right < screenBounds.Right)
        {
            // Taskbar at right
            left = workingArea.Right - Width - 10;
            top = workingArea.Bottom - Height - 10;
        }
        else
        {
            // Taskbar at left
            left = workingArea.Left + 10;
            top = workingArea.Bottom - Height - 10;
        }

        Left = left / (PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1);
        Top = top / (PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M22 ?? 1);
    }
}
