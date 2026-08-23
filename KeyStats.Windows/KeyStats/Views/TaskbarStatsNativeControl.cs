using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using KeyStats.Helpers;
using KeyStats.ViewModels;
using Forms = System.Windows.Forms;

namespace KeyStats.Views;

/// <summary>
/// GDI-rendered taskbar child window for compatibility with the Windows 11 taskbar compositor.
/// </summary>
public sealed class TaskbarStatsNativeControl : Forms.Control
{
    private const int WM_MOUSEACTIVATE = 0x0021;
    private const int MA_NOACTIVATE = 3;

    private readonly FloatingStatsViewModel _viewModel;
    private readonly Forms.ToolTip _toolTip;
    private readonly Dictionary<string, Forms.ToolStripMenuItem> _primaryMetricItems =
        new(StringComparer.Ordinal);
    private readonly Dictionary<string, Forms.ToolStripMenuItem> _secondaryMetricItems =
        new(StringComparer.Ordinal);
    private IntPtr _taskbarParent;
    private bool _compact;
    private bool _hovered;
    private bool _isDisposed;

    public TaskbarStatsNativeControl()
    {
        SetStyle(
            Forms.ControlStyles.UserPaint |
            Forms.ControlStyles.AllPaintingInWmPaint |
            Forms.ControlStyles.OptimizedDoubleBuffer |
            Forms.ControlStyles.ResizeRedraw |
            Forms.ControlStyles.Opaque,
            true);

        TabStop = false;
        _viewModel = new FloatingStatsViewModel();
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;
        _toolTip = new Forms.ToolTip
        {
            ShowAlways = true,
            InitialDelay = 450,
            ReshowDelay = 100
        };
        ContextMenuStrip = CreateContextMenu();
        ThemeManager.Instance.ThemeChanged += OnThemeChanged;
        UpdateToolTip();
    }

    public void CreateInTaskbar(IntPtr taskbarParent)
    {
        if (_isDisposed)
        {
            throw new ObjectDisposedException(nameof(TaskbarStatsNativeControl));
        }

        if (taskbarParent == IntPtr.Zero)
        {
            throw new ArgumentException("A valid taskbar HWND is required.", nameof(taskbarParent));
        }

        _taskbarParent = taskbarParent;
        CreateControl();
        if (!IsHandleCreated)
        {
            throw new InvalidOperationException("The native taskbar statistics HWND was not created.");
        }
    }

    public void SetCompactMode(bool compact)
    {
        if (_compact == compact)
        {
            return;
        }

        _compact = compact;
        Invalidate();
    }

    protected override Forms.CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.Caption = "KeyStatsTaskbarStatsWindow";
            parameters.Parent = _taskbarParent;
            parameters.Style = NativeInterop.WS_CHILD |
                               NativeInterop.WS_VISIBLE |
                               NativeInterop.WS_CLIPSIBLINGS |
                               NativeInterop.WS_CLIPCHILDREN;
            parameters.ExStyle = NativeInterop.WS_EX_TOOLWINDOW |
                                 NativeInterop.WS_EX_NOACTIVATE |
                                 NativeInterop.WS_EX_NOPARENTNOTIFY;
            return parameters;
        }
    }

    protected override void OnPaintBackground(Forms.PaintEventArgs e)
    {
        e.Graphics.Clear(GetPalette().Background);
    }

    protected override void OnPaint(Forms.PaintEventArgs e)
    {
        base.OnPaint(e);

        var palette = GetPalette();
        e.Graphics.Clear(_hovered ? palette.HoverBackground : palette.Background);
        e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;

        // Use the actual HWND height instead of DeviceDpi. Explorer and WinForms can
        // report different DPI contexts for a cross-process taskbar child on Windows 11.
        var scale = Math.Max(0.75f, ClientSize.Height / 40f);
        var firstRowHeight = ClientSize.Height / 2;
        var secondRowHeight = ClientSize.Height - firstRowHeight;
        using var labelFont = new Font(
            "Microsoft YaHei UI",
            Math.Max(9f, 10f * scale),
            FontStyle.Regular,
            GraphicsUnit.Pixel);
        using var valueFont = new Font(
            "Microsoft YaHei UI",
            Math.Max(10f, 11f * scale),
            FontStyle.Bold,
            GraphicsUnit.Pixel);
        using var dividerPen = new Pen(palette.Divider, Math.Max(1f, scale * 0.5f));

        DrawRow(e.Graphics, new Rectangle(0, 0, ClientSize.Width, firstRowHeight),
            _viewModel.PrimaryLabel, _viewModel.PrimaryValue, labelFont, valueFont, palette, scale);

        var dividerY = Math.Max(0, firstRowHeight - 1);
        e.Graphics.DrawLine(dividerPen, 0, dividerY, ClientSize.Width, dividerY);

        DrawRow(e.Graphics, new Rectangle(0, firstRowHeight, ClientSize.Width, secondRowHeight),
            _viewModel.SecondaryLabel, _viewModel.SecondaryValue, labelFont, valueFont, palette, scale);
    }

    protected override void OnMouseEnter(EventArgs e)
    {
        base.OnMouseEnter(e);
        _hovered = true;
        Invalidate();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        _hovered = false;
        Invalidate();
    }

    protected override void OnMouseDoubleClick(Forms.MouseEventArgs e)
    {
        base.OnMouseDoubleClick(e);
        if (e.Button != Forms.MouseButtons.Left)
        {
            return;
        }

        App.CurrentApp?.TrackClick("taskbar_stats_open_details");
        App.CurrentApp?.ShowMainWindow();
    }

    protected override void WndProc(ref Forms.Message message)
    {
        if (message.Msg == WM_MOUSEACTIVATE)
        {
            message.Result = new IntPtr(MA_NOACTIVATE);
            return;
        }

        base.WndProc(ref message);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && !_isDisposed)
        {
            _isDisposed = true;
            ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
            _viewModel.PropertyChanged -= OnViewModelPropertyChanged;
            _viewModel.Cleanup();
            _toolTip.Dispose();
            ContextMenuStrip?.Dispose();
            ContextMenuStrip = null;
        }

        base.Dispose(disposing);
    }

    private void DrawRow(
        Graphics graphics,
        Rectangle bounds,
        string label,
        string value,
        Font labelFont,
        Font valueFont,
        Palette palette,
        float scale)
    {
        var horizontalPadding = Math.Max(4, (int)Math.Round(6 * scale));
        var markerSize = Math.Max(3, (int)Math.Round(3 * scale));
        var markerX = horizontalPadding;
        var markerY = bounds.Top + Math.Max(0, (bounds.Height - markerSize) / 2);
        using var markerBrush = new SolidBrush(palette.Accent);
        graphics.FillEllipse(markerBrush, markerX, markerY, markerSize, markerSize);

        var contentLeft = markerX + markerSize + Math.Max(3, (int)Math.Round(4 * scale));
        var contentRight = Math.Max(contentLeft, bounds.Right - horizontalPadding);
        var textFlags = Forms.TextFormatFlags.NoPrefix |
                        Forms.TextFormatFlags.NoPadding |
                        Forms.TextFormatFlags.SingleLine |
                        Forms.TextFormatFlags.VerticalCenter |
                        Forms.TextFormatFlags.EndEllipsis;

        if (_compact)
        {
            Forms.TextRenderer.DrawText(graphics, value, valueFont,
                Rectangle.FromLTRB(contentLeft, bounds.Top, contentRight, bounds.Bottom),
                palette.PrimaryText, textFlags | Forms.TextFormatFlags.Right);
            return;
        }

        var measuredValue = Forms.TextRenderer.MeasureText(
            graphics, value, valueFont, new Size(int.MaxValue, bounds.Height), textFlags).Width;
        var minimumValueWidth = Math.Max(38, (int)Math.Round(46 * scale));
        var valueWidth = Math.Min(
            Math.Max(minimumValueWidth, measuredValue),
            Math.Max(minimumValueWidth, (contentRight - contentLeft) / 2));
        var valueLeft = Math.Max(contentLeft, contentRight - valueWidth);
        var labelRight = Math.Max(contentLeft, valueLeft - Math.Max(3, (int)Math.Round(5 * scale)));

        Forms.TextRenderer.DrawText(graphics, label, labelFont,
            Rectangle.FromLTRB(contentLeft, bounds.Top, labelRight, bounds.Bottom),
            palette.SecondaryText, textFlags);
        Forms.TextRenderer.DrawText(graphics, value, valueFont,
            Rectangle.FromLTRB(valueLeft, bounds.Top, contentRight, bounds.Bottom),
            palette.PrimaryText, textFlags | Forms.TextFormatFlags.Right);
    }

    private Forms.ContextMenuStrip CreateContextMenu()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Opening += (_, _) => RefreshMetricMenuState();

        var openDetailsItem = new Forms.ToolStripMenuItem(KeyStats.Properties.Strings.TaskbarStats_OpenDetails);
        openDetailsItem.Click += (_, _) =>
        {
            App.CurrentApp?.TrackClick("taskbar_stats_open_details");
            App.CurrentApp?.ShowMainWindow();
        };
        menu.Items.Add(openDetailsItem);
        menu.Items.Add(new Forms.ToolStripSeparator());

        var primaryItem = new Forms.ToolStripMenuItem(KeyStats.Properties.Strings.TaskbarStats_PrimaryMetric);
        PopulateMetricMenu(primaryItem, isPrimary: true, _primaryMetricItems);
        menu.Items.Add(primaryItem);

        var secondaryItem = new Forms.ToolStripMenuItem(KeyStats.Properties.Strings.TaskbarStats_SecondaryMetric);
        PopulateMetricMenu(secondaryItem, isPrimary: false, _secondaryMetricItems);
        menu.Items.Add(secondaryItem);
        menu.Items.Add(new Forms.ToolStripSeparator());

        var hideItem = new Forms.ToolStripMenuItem(KeyStats.Properties.Strings.TaskbarStats_Hide);
        hideItem.Click += (_, _) => System.Windows.Application.Current?.Dispatcher.BeginInvoke(new Action(() =>
            App.CurrentApp?.SetTaskbarStatsEnabled(false, "taskbar_stats_context_menu")));
        menu.Items.Add(hideItem);
        return menu;
    }

    private void PopulateMetricMenu(
        Forms.ToolStripMenuItem parent,
        bool isPrimary,
        IDictionary<string, Forms.ToolStripMenuItem> destination)
    {
        foreach (var metricId in FloatingStatsViewModel.AvailableMetricIds)
        {
            var capturedMetricId = metricId;
            var item = new Forms.ToolStripMenuItem(FloatingStatsViewModel.GetMetricLabel(metricId));
            item.Click += (_, _) => SelectMetric(isPrimary, capturedMetricId);
            destination[metricId] = item;
            parent.DropDownItems.Add(item);
        }
    }

    private void RefreshMetricMenuState()
    {
        var primaryMetric = _viewModel.PrimaryMetricId;
        var secondaryMetric = _viewModel.SecondaryMetricId;

        foreach (var pair in _primaryMetricItems)
        {
            pair.Value.Checked = string.Equals(pair.Key, primaryMetric, StringComparison.Ordinal);
            pair.Value.Enabled = !string.Equals(pair.Key, secondaryMetric, StringComparison.Ordinal);
        }

        foreach (var pair in _secondaryMetricItems)
        {
            pair.Value.Checked = string.Equals(pair.Key, secondaryMetric, StringComparison.Ordinal);
            pair.Value.Enabled = !string.Equals(pair.Key, primaryMetric, StringComparison.Ordinal);
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

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_isDisposed)
        {
            return;
        }

        UpdateToolTip();
        Invalidate();
    }

    private void OnThemeChanged()
    {
        if (_isDisposed)
        {
            return;
        }

        if (IsHandleCreated && InvokeRequired)
        {
            BeginInvoke(new Action(Invalidate));
            return;
        }

        Invalidate();
    }

    private void UpdateToolTip()
    {
        _toolTip.SetToolTip(
            this,
            $"{_viewModel.PrimaryFullValue}{Environment.NewLine}{_viewModel.SecondaryFullValue}");
    }

    private static Palette GetPalette()
    {
        if (ThemeManager.Instance.IsDarkTheme)
        {
            return new Palette(
                Color.FromArgb(32, 32, 32), Color.FromArgb(45, 45, 45), Color.White,
                Color.FromArgb(197, 197, 197), Color.FromArgb(0, 120, 212), Color.FromArgb(61, 61, 61));
        }

        return new Palette(
            Color.FromArgb(250, 250, 250), Color.FromArgb(238, 238, 238), Color.FromArgb(26, 26, 26),
            Color.FromArgb(74, 74, 74), Color.FromArgb(0, 103, 192), Color.FromArgb(229, 229, 229));
    }

    private readonly struct Palette
    {
        public Palette(Color background, Color hoverBackground, Color primaryText,
            Color secondaryText, Color accent, Color divider)
        {
            Background = background;
            HoverBackground = hoverBackground;
            PrimaryText = primaryText;
            SecondaryText = secondaryText;
            Accent = accent;
            Divider = divider;
        }

        public Color Background { get; }
        public Color HoverBackground { get; }
        public Color PrimaryText { get; }
        public Color SecondaryText { get; }
        public Color Accent { get; }
        public Color Divider { get; }
    }
}
