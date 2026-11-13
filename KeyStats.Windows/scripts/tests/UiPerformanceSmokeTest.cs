using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using KeyStats.Helpers;
using KeyStats.Models;
using KeyStats.Services;
using KeyStats.ViewModels;
using KeyStats.Views;
using KeyStats.Views.Controls;

internal static class UiPerformanceSmokeTest
{
    private const BindingFlags PrivateInstance = BindingFlags.NonPublic | BindingFlags.Instance;
    private static int _assertions;

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            // Never initialize the real singleton: these tests use only in-memory data.
            var singleton = typeof(StatsManager).GetField("_instance", BindingFlags.Static | BindingFlags.NonPublic)!;
            var manager = (StatsManager)FormatterServices.GetUninitializedObject(typeof(StatsManager));
            SetField(manager, "_lock", new object());
            SetField(manager, "<CurrentStats>k__BackingField", new DailyStats(DateTime.Today));
            SetField(manager, "<History>k__BackingField", new Dictionary<string, DailyStats>());
            SetField(manager, "<Settings>k__BackingField", new AppSettings());
            singleton.SetValue(null, manager);

            if (args.Length == 2 && args[0] == "--render-probe")
            {
                MeasureFloatingRendering(manager, args[1]);
                return 0;
            }

            TestScheduler();
            TestPopup(manager);
            TestOtherViewModels(manager);
            TestChartSubscriptions();
            TestFloatingRendering(manager);
            singleton.SetValue(null, null);
            Console.WriteLine($"PASS: {_assertions} UI performance assertions; no hooks or user-data files used.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static void ApplyTestTheme(bool dark)
    {
        typeof(ThemeManager).GetMethod(dark ? "ApplyDarkTheme" : "ApplyLightTheme",
            BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, new object[] { Application.Current.Resources });
    }

    private static void TestFloatingRendering(StatsManager manager)
    {
        // Plain Application avoids App.OnStartup, hooks, analytics and real settings.
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        SetField(manager, "_isDisposed", true); // Ignore all debounced settings writes.
        var themeSubscribers = SubscriberCount(ThemeManager.Instance, "ThemeChanged");
        var window = new FloatingStatsWindow();
        try
        {
            ApplyTestTheme(false);
            window.Show();
            Pump(100);
            var source = (HwndSource)PresentationSource.FromVisual(window);
            Check(source.CompositionTarget.RenderMode == RenderMode.SoftwareOnly, "floating window uses software rendering");
            Check(RenderOptions.ProcessRenderMode == RenderMode.Default, "floating window does not disable process GPU rendering");
            var otherWindow = new Window { Width = 100, Height = 100, Left = -32000, Top = -32000, ShowInTaskbar = false };
            otherWindow.Show();
            Check(((HwndSource)PresentationSource.FromVisual(otherWindow)).CompositionTarget.RenderMode == RenderMode.Default,
                "other windows retain their default rendering mode");
            otherWindow.Close();

            foreach (var dark in new[] { false, true })
            {
                ApplyTestTheme(dark);
                Pump(100);
                var border = (Border)window.FindName("RootBorder");
                var surface = (SolidColorBrush)border.Background;
                Check(surface.Color.A > 0 && surface.Color.A < 255, "floating theme preserves translucency");
                Check(dark ? surface.Color.R < 100 : surface.Color.R > 200, "floating surface follows light/dark theme");
                var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
                bitmap.Render(border);
                Check(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0, "floating window renders both themes");
            }

            window.Hide();
            manager.CurrentStats.KeyPresses = 123456;
            window.Show();
            Pump(100);
            Check(((FloatingStatsViewModel)window.DataContext).PrimaryValue == manager.FormatNumber(123456), "floating window catches up after hide/show");
            foreach (var layout in new[] { AppSettings.FloatingStatsSingleRowLayoutMode, AppSettings.FloatingStatsDoubleRowLayoutMode })
            {
                manager.Settings.FloatingStatsLayoutMode = layout;
                manager.Settings.FloatingStatsFontSize = AppSettings.MaximumFloatingStatsFontSize;
                window.ApplyBehaviorSettings();
                Pump(100);
                Check(window.ActualWidth > 0 && window.ActualHeight > 0, "floating layouts resize at maximum font size");
            }
        }
        finally
        {
            window.Close();
            Pump(100);
            SetField(manager, "_isDisposed", false);
        }
        Check(SubscriberCount(ThemeManager.Instance, "ThemeChanged") == themeSubscribers, "floating close releases theme subscription");
        Check(SubscriberCount(manager, "StatsChanged") == 0, "floating close releases statistics subscription");
        GC.KeepAlive(app);
    }

    private static void MeasureFloatingRendering(StatsManager manager, string mode)
    {
        if (mode != "default" && mode != "software") throw new ArgumentException("Unknown render mode.");
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        SetField(manager, "_isDisposed", true);
        ApplyTestTheme(false);
        var window = new FloatingStatsWindow();
        // Override after the production SourceInitialized handler for an A/B comparison.
        window.SourceInitialized += (_, _) => ((HwndSource)PresentationSource.FromVisual(window)).CompositionTarget.RenderMode =
            mode == "software" ? RenderMode.SoftwareOnly : RenderMode.Default;
        window.Show();
        Pump(1000);
        var process = Process.GetCurrentProcess();
        var cpuStart = process.TotalProcessorTime;
        var stopwatch = Stopwatch.StartNew();
        var updates = 0;
        var displayedChanges = 0;
        var viewModel = (FloatingStatsViewModel)window.DataContext;
        viewModel.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(FloatingStatsViewModel.PrimaryValue)) displayedChanges++; };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) =>
        {
            // Change the compact K/M text on every tick, not just the full tooltip.
            manager.CurrentStats.KeyPresses = 12345 + 137 * updates++;
            Notify(manager);
        };
        timer.Start();
        Pump(12000);
        timer.Stop();
        Pump(400);
        Check(((FloatingStatsViewModel)window.DataContext).PrimaryValue == manager.FormatNumber(manager.CurrentStats.KeyPresses),
            "render probe projects the final changing value");
        Check(displayedChanges >= 20, "render probe exercises repeated text rendering");
        process.Refresh();
        Console.WriteLine($"{mode}: private={process.PrivateMemorySize64 / 1048576.0:F1} MiB; workingSet={process.WorkingSet64 / 1048576.0:F1} MiB; CPU={(process.TotalProcessorTime - cpuStart).TotalSeconds:F3}s/{stopwatch.Elapsed.TotalSeconds:F1}s; notifications={updates}; displayedChanges={displayedChanges}");
        foreach (var dark in new[] { false, true })
        {
            ApplyTestTheme(dark);
            Pump(100);
            var border = (Border)window.FindName("RootBorder");
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(border.ActualWidth * 4), (int)Math.Ceiling(border.ActualHeight * 4), 384, 384, PixelFormats.Pbgra32);
            bitmap.Render(border);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, $"floating-{mode}-{(dark ? "dark" : "light")}.png"));
            encoder.Save(stream);
        }
        window.Close();
        Pump(100);
        GC.KeepAlive(app);
    }

    private static void TestScheduler()
    {
        var schedulerType = typeof(StatsPopupViewModel).Assembly.GetType("KeyStats.Helpers.StatsRefreshScheduler", true)!;
        var refreshes = new List<bool>();
        var scheduler = Activator.CreateInstance(schedulerType, new object[] { new Action<bool>(refreshes.Add) })!;
        var request = schedulerType.GetMethod("Request")!;
        var activate = schedulerType.GetMethod("SetActive")!;
        Action<bool> send = full => request.Invoke(scheduler, new object[] { full });
        Action<bool> setActive = active => activate.Invoke(scheduler, new object[] { active });

        send(true);
        Pump(350);
        Check(refreshes.Count == 0, "inactive scheduler does not refresh");
        setActive(true);
        // Joining without pumping catches synchronous UI waits in the input path.
        var burst = Task.Run(() => Parallel.For(0, 1000, i => send(i == 500)));
        Check(burst.Wait(2000), "background notifications never wait for UI");
        Pump(400);
        Check(refreshes.Count == 1 && refreshes[0], "1000 mixed notifications become one full refresh");
        Pump(350);
        Check(refreshes.Count == 1, "scheduler does not keep waking while idle");
        send(false);
        Pump(350);
        Check(refreshes.Count == 2 && !refreshes[1], "mouse-only refresh stays lightweight");
        send(true);
        setActive(false);
        Pump(350);
        Check(refreshes.Count == 2, "hiding cancels a pending refresh");
        setActive(true);
        send(false);
        Pump(350);
        Check(refreshes.Count == 3, "scheduler resumes after hide/show");

        var before = refreshes.Count;
        var stream = Task.Run(() =>
        {
            for (var i = 0; i < 90; i++) { send(true); Thread.Sleep(10); }
        });
        Pump(800);
        Check(refreshes.Count > before, "continuous input does not postpone the first deadline");
        Check(stream.Wait(2000), "continuous notification producer completes");
        send(true);
        ((IDisposable)scheduler).Dispose();
        before = refreshes.Count;
        Pump(350);
        send(true);
        Check(refreshes.Count == before, "disposed scheduler ignores queued/new notifications");
    }

    private static void TestPopup(StatsManager manager)
    {
        manager.CurrentStats.KeyPresses = 10;
        manager.CurrentStats.KeyPressCounts["A"] = 10;
        manager.CurrentStats.SideBackClicks = 2;
        manager.CurrentStats.AppStats["Unknown"] = new AppStats("Unknown", "Test app") { KeyPresses = 10 };
        var vm = new StatsPopupViewModel();
        Check(SubscriberCount(manager, "StatsChanged") == 0, "unshown popup has no stats subscription");
        vm.SetActive(true);
        Check(vm.KeyPresses == "10" && vm.SideBackClicks == "2", "show projects a locked snapshot including side clicks");
        var row = vm.Column1Items[0];
        var chart = vm.ChartData;
        var appRow = vm.AppStatsItems[0];
        Notify(manager);
        Pump(350);
        Check(ReferenceEquals(row, vm.Column1Items[0]), "unchanged key row is reused");
        Check(ReferenceEquals(chart, vm.ChartData), "unchanged chart series is reused");
        Check(ReferenceEquals(appRow, vm.AppStatsItems[0]), "unchanged app row is reused");

        manager.CurrentStats.KeyPresses = 11;
        manager.CurrentStats.KeyPressCounts["A"] = 11;
        manager.CurrentStats.AppStats["Unknown"].KeyPresses = 11;
        for (var i = 0; i < 1000; i++) Notify(manager);
        Pump(350);
        Check(vm.KeyPresses == "11" && vm.Column1Items[0].Count == "11", "burst refresh projects final counts");
        Check(ReferenceEquals(chart, vm.ChartData), "keypress does not rebuild an unchanged click chart");
        Check(vm.AppStatsItems[0].KeyPresses == "11", "changed app row reflects final count");

        vm.SetActive(false);
        Check(SubscriberCount(manager, "StatsChanged") == 0, "hidden popup unsubscribes");
        manager.CurrentStats.KeyPresses = 20;
        Notify(manager);
        Pump(350);
        Check(vm.KeyPresses == "11", "hidden popup performs no projection");
        vm.SetActive(true);
        Check(vm.KeyPresses == "20", "reopened popup catches up immediately");
        vm.SelectedMetricIndex = 2;
        manager.CurrentStats.MouseDistance += 100;
        Notify(manager, StatsManager.StatsUpdateKind.MouseDistanceOnly);
        Pump(350);
        Check(vm.ChartData.Last().Value == manager.CurrentStats.MouseDistance, "mouse-only updates refresh the selected distance chart");
        vm.Cleanup();
        vm.Cleanup();
        Check(SubscriberCount(manager, "StatsChanged") == 0, "popup cleanup is idempotent");
    }

    private static void TestOtherViewModels(StatsManager manager)
    {
        var floating = new FloatingStatsViewModel();
        floating.SetActive(true);
        manager.CurrentStats.KeyPresses = 30;
        Notify(manager);
        Pump(350);
        Check(floating.PrimaryValue == "30", "floating counters update through scheduler");
        floating.SetActive(false);
        Check(SubscriberCount(manager, "StatsChanged") == 0, "hidden floating window unsubscribes");
        floating.Cleanup();
        var apps = new AppStatsViewModel();
        var history = new KeyHistoryViewModel();
        apps.SetActive(true);
        history.SetActive(true);
        Check(SubscriberCount(manager, "StatsUpdateRequested") == 2, "detail windows subscribe when active");
        apps.SetActive(false);
        history.SetActive(false);
        Check(SubscriberCount(manager, "StatsUpdateRequested") == 0, "hidden detail windows unsubscribe");
        apps.Cleanup();
        history.Cleanup();
    }

    private static void TestChartSubscriptions()
    {
        var initial = SubscriberCount(ThemeManager.Instance, "ThemeChanged");
        var data = new ObservableCollection<ChartDataPoint>();
        var references = CreateAndUnloadCharts(data);
        Check(SubscriberCount(ThemeManager.Instance, "ThemeChanged") == initial, "chart unload removes global theme subscriptions");
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        Check(references.All(reference => !reference.IsAlive), "20 unloaded charts collect even while data collection survives");
        GC.KeepAlive(data);

        // Exercise real WPF load/unload and rendering in an off-screen host too.
        var visibleChart = new StatsChartControl();
        var window = new Window
        {
            Content = visibleChart, Width = 360, Height = 200,
            Left = -32000, Top = -32000, ShowInTaskbar = false, ShowActivated = false
        };
        window.Show();
        Pump(100);
        visibleChart.ChartData = new ObservableCollection<ChartDataPoint>
        {
            new() { Date = DateTime.Today.AddDays(-1), Value = 4 },
            new() { Date = DateTime.Today, Value = 10 }
        };
        Pump(100);
        var canvas = (System.Windows.Controls.Canvas)visibleChart.FindName("ChartCanvas");
        Check(canvas.Children.Count > 5, "loaded chart renders actual data");
        visibleChart.ChartStyle = 1;
        Check(canvas.Children.Count > 5, "bar chart still renders after switching style");
        window.Hide();
        window.Show();
        Pump(100);
        Check(canvas.Children.Count > 5, "chart redraws after hide/show");
        window.Close();
        Pump(100);
        Check(SubscriberCount(ThemeManager.Instance, "ThemeChanged") == initial, "real window close unsubscribes its chart");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference[] CreateAndUnloadCharts(ObservableCollection<ChartDataPoint> data)
    {
        var references = new List<WeakReference>();
        for (var i = 0; i < 20; i++)
        {
            var chart = new StatsChartControl { ChartData = data, LocalChartData = data };
            var baseline = SubscriberCount(ThemeManager.Instance, "ThemeChanged");
            chart.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
            chart.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
            Check(SubscriberCount(ThemeManager.Instance, "ThemeChanged") == baseline + 1, "repeated Loaded does not duplicate subscriptions");
            chart.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
            chart.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
            Check(SubscriberCount(ThemeManager.Instance, "ThemeChanged") == baseline + 1, "reloading chart restores theme subscription");
            chart.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
            references.Add(new WeakReference(chart));
        }
        return references.ToArray();
    }

    private static void Notify(StatsManager manager, StatsManager.StatsUpdateKind kind = StatsManager.StatsUpdateKind.Full)
    {
        typeof(StatsManager).GetMethod("NotifyStatsUpdate", PrivateInstance)!.Invoke(manager, new object[] { kind });
    }

    private static int SubscriberCount(object instance, string name)
    {
        return ((MulticastDelegate?)instance.GetType().GetField(name, PrivateInstance)!.GetValue(instance))?.GetInvocationList().Length ?? 0;
    }

    private static void SetField(object instance, string name, object value)
    {
        instance.GetType().GetField(name, PrivateInstance)!.SetValue(instance, value);
    }

    private static void Pump(int milliseconds)
    {
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer(DispatcherPriority.Send) { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        Dispatcher.PushFrame(frame);
    }

    private static void Check(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException("FAIL: " + description);
        _assertions++;
    }
}
