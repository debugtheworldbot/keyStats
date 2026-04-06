# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KeyStats for Windows — a system tray app that tracks keyboard and mouse usage statistics. Ported from the macOS version. Built with WPF + WinForms interop on .NET Framework 4.8 (`net48`), C# with nullable enabled, LangVersion 10.0.

## Build Commands

```bash
# Debug build
dotnet build KeyStats/KeyStats.csproj -c Debug

# Release build
dotnet build KeyStats/KeyStats.csproj -c Release

# Package for distribution (produces dist/KeyStats-Windows-<version>.zip)
powershell -ExecutionPolicy Bypass -File ./build.ps1 -Configuration Release
```

There are no automated tests in this project. Validation is manual (see AGENTS.md for checklist).

## Architecture

**Entry point**: `App.xaml.cs` — single-instance (mutex guard), initializes theme, services, tray icon, context menu, and all windows. Handles import/export. Exit sequence: analytics flush → monitor stop → stats flush → cleanup.

**Core singleton services** (all in `Services/`):
- `InputMonitorService` — global `WH_KEYBOARD_LL` / `WH_MOUSE_LL` hooks via `SetWindowsHookEx`. Emits events for key/click/move/scroll. Mouse sampled at 30 FPS, jumps >500px filtered.
- `StatsManager` — central aggregation, persistence, formatting, history queries. Receives events from InputMonitorService. Debounced save (2s) and UI update (300ms). Midnight rollover timer. Import/export with merge/overwrite modes.
- `NotificationService` — Windows toast notifications via Microsoft.Toolkit.Uwp.Notifications.
- `StartupManager` — manages `HKCU\...\Run` registry entry.

**UI pattern**: light MVVM (View + ViewModel, no framework). ViewModels in `ViewModels/`, Views in `Views/`.
- `StatsPopupWindow` — main stats popup, positioned near tray icon based on taskbar location
- `SettingsWindow`, `AppStatsWindow`, `KeyboardHeatmapWindow`, `KeyHistoryWindow`, `MouseCalibrationWindow`, `NotificationSettingsWindow`
- Custom controls in `Views/Controls/`: `StatItemControl`, `KeyBreakdownControl`, `StatsChartControl`, `KeyDistributionPieChartControl`, `KeyboardHeatmapControl`

**Helpers** (`Helpers/`):
- `NativeInterop` — all P/Invoke declarations (hooks, keyboard state, window info)
- `KeyNameMapper` — virtual key code → display name with modifier detection (outputs `"Ctrl+Shift+A"`)
- `ThemeManager` — runtime light/dark theme switching via dynamic resource replacement
- `ActiveWindowManager` — foreground window title/process detection for per-app attribution
- `Converters` — XAML value converters (`IntToBool`, `BoolToVisibility`, `InverseBool`)

**Data models** (`Models/`):
- `DailyStats` — daily totals, key breakdown dict, per-app stats, mouse/scroll distance
- `AppStats` — per-app key/click/scroll counts
- `AppSettings` — notifications, startup, analytics, mouse calibration settings

**Persistence**: JSON files in `%LOCALAPPDATA%\KeyStats\` — `daily_stats.json`, `history.json`, `settings.json`. Keep backward-compatible when adding fields.

## Key Constraints

- **Privacy**: only store aggregate counts/distances. Never persist keystroke content, raw mouse paths, or clipboard data.
- **Hook safety**: hook callbacks must be non-blocking. Always call `CallNextHookEx`. No file IO, serialization, or UI work in callbacks — dispatch via thread pool.
- **Threading**: `StatsManager` shared state is lock-protected. UI updates must go through WPF Dispatcher. Never mutate WPF-bound collections from background threads.
- **Shutdown**: preserve the exit sequence in `App.OnExit`. New background/timer resources must be disposed on exit.
- **UI language**: user-facing copy is Chinese-first. Preserve this unless explicitly adding bilingual UI.

## Conventions

- Git commits: Conventional Commits format (`feat:`, `fix:`, `refactor:`, etc.)
- One primary class per file, follow existing namespace/folder boundaries.
- Charts are hand-drawn on WPF Canvas (no charting library).
- Tray icon uses `Hardcodet.NotifyIcon.Wpf` (`TaskbarIcon`).
- Analytics: when adding a new page/window, emit `pageview` and `click` events using shared tracking helpers.

## High-Risk Files

Changes to these files can impact data integrity, input capture, or app stability — review carefully:
- `Services/InputMonitorService.cs`
- `Services/StatsManager.cs`
- `App.xaml.cs`
- `Helpers/NativeInterop.cs`
- `Helpers/ThemeManager.cs`
