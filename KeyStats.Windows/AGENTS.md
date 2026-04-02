# KeyStats.Windows - Agent Development Guide

## Project Snapshot

- Type: Windows tray app (WPF + WinForms interop)
- Runtime: .NET Framework 4.8 (`net48`)
- Language: C# (nullable enabled, LangVersion 10.0)
- UI pattern: View + ViewModel (light MVVM)
- Core behavior: global keyboard/mouse counting only (no input content capture)

## Architecture (Read Before Editing)

### Entry and lifecycle

- `KeyStats/App.xaml.cs`
  - Single-instance mutex guard
  - Initializes theme, stats service, input monitor, tray icon
  - Creates context menu and app windows
  - Handles import/export dialogs
  - On exit: stop monitor, flush save, dispose resources

### Core singleton services

- `KeyStats/Services/InputMonitorService.cs`
  - Installs `WH_KEYBOARD_LL` / `WH_MOUSE_LL` hooks via `SetWindowsHookEx`
  - Emits events for key/click/move/scroll
  - Must keep hook callbacks fast (uses `ThreadPool.QueueUserWorkItem`)

- `KeyStats/Services/StatsManager.cs`
  - Central stats aggregation + persistence + formatting + history queries
  - Receives events from `InputMonitorService`
  - Debounced save/update timers + midnight rollover
  - Import/export + merge/overwrite logic + keyboard heatmap aggregation

- `KeyStats/Services/NotificationService.cs`
  - Toast notifications for milestones

- `KeyStats/Services/StartupManager.cs`
  - Windows startup entry in `HKCU\...\Run`

### UI and state projection

- `KeyStats/ViewModels/TrayIconViewModel.cs`: tray icon, tooltip, popup open/quit commands
- `KeyStats/ViewModels/StatsPopupViewModel.cs`: main stats popup binding source
- `KeyStats/ViewModels/AppStatsViewModel.cs`: app-level aggregation view model
- `KeyStats/Views/*`: popup/settings/notification/calibration/heatmap windows
- `KeyStats/Helpers/ThemeManager.cs`: runtime dynamic light/dark resource replacement

## Non-Negotiable Rules

### Privacy and security

- Only store aggregate counts/distances/app attribution.
- Never persist keystroke content, raw mouse path, or clipboard/text payloads.
- Keep analytics optional and behind existing settings (`AppSettings.AnalyticsEnabled`).

### Hook safety and performance

- Low-level hook callbacks must be non-blocking and short.
- Always call `CallNextHookEx(...)`.
- Do not add file IO, JSON serialization, or UI work directly in hook callbacks.
- Preserve 30 FPS mouse sampling and abnormal movement filtering unless explicitly redesigning.

### Threading

- `StatsManager` shared state (`CurrentStats`, `History`, `Settings`) must stay lock-protected.
- UI updates must execute through WPF Dispatcher.
- Do not mutate WPF-bound collections from background threads.

### Persistence compatibility

- Data directory is fixed: `%LOCALAPPDATA%\KeyStats\`
  - `daily_stats.json`
  - `history.json`
  - `settings.json`
- Keep JSON backward compatibility when adding fields.
- Prefer additive model changes; avoid breaking property renames/removals unless migration is implemented.

### Shutdown correctness

- Preserve exit sequence in `App.OnExit`: analytics flush -> monitor stop -> stats flush -> cleanup.
- Any new background/timer resource must be disposed on exit.

## Data Contracts You Must Respect

- `DailyStats`: daily totals, key breakdown, per-app stats, mouse/scroll distance
- `AppStats`: per-app counts (keys/clicks/scroll)
- `AppSettings`: notifications, startup, analytics, mouse calibration and unit settings
- `StatsManager.ExportPayload` versioned export format (`Version == 1` currently)

## Common Change Workflows

### 1) Add a new metric

1. Extend model(s): `DailyStats` and optionally `AppStats`.
2. Update event handling in `StatsManager` (increment + debounce/save behavior).
3. Include metric in clone/normalize/merge/export/import paths inside `StatsManager`.
4. Update formatting/query API if needed (`FormatHistoryValue`, chart data, summaries).
5. Surface in ViewModel + XAML (popup/app stats/settings).

### 2) Add/modify input event tracking

1. Implement in `InputMonitorService` hook switch.
2. Keep callback lightweight; dispatch through thread pool if needed.
3. Add event signature updates and consume in `StatsManager.SetupInputMonitor()`.
4. Verify no double-counting on key repeat / side buttons / synthetic spikes.

### 3) Add a setting

1. Add field in `AppSettings` (with safe default).
2. Read/write through `StatsManager.Settings` + `SaveSettings()`.
3. Wire UI in corresponding `Views/*Window.xaml(.cs)`.
4. Ensure behavior applies immediately or on next refresh intentionally.

### 4) Extend chart/heatmap

1. Add aggregation/query logic to `StatsManager`.
2. Keep history date range semantics consistent (today/week/month/all).
3. Update view model conversion and control rendering.
4. Validate theme-aware colors (light/dark) via `ThemeManager`.

## Build, Run, Validate

### Agent validation rule

- After updating Windows code, do not use `dotnet build` as the default validation step.
- Prefer targeted manual verification, focused reasoning, or another non-build validation path unless the user explicitly asks for a build.

### Build

```bash
cd KeyStats.Windows
dotnet build KeyStats/KeyStats.csproj -c Debug
dotnet build KeyStats/KeyStats.csproj -c Release
```

### Packaging

```powershell
cd KeyStats.Windows
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Configuration Release
```

### Manual validation checklist

- App starts once only (second launch blocked by mutex).
- Tray icon appears and tooltip updates with live stats.
- Keyboard/mouse counters increase correctly.
- Popup, settings, notification, calibration, heatmap windows open/close correctly.
- Import/export succeeds with overwrite and merge.
- Data survives restart and rolls over at midnight.
- Theme switches correctly on system light/dark change.
- Exit does not lose recent stats (`FlushPendingSave` path).

## Debugging Decision Hints

- No counters updating:
  - Check hook installation errors in `InputMonitorService.StartMonitoring()`.
  - Confirm app is not paused/closed and singleton services initialized.

- UI stale:
  - Verify `StatsUpdateRequested` is fired and consumed on Dispatcher.
  - Check view model cleanup/re-subscription lifecycle.

- Data mismatch after import:
  - Verify import mode (`Overwrite` vs `Merge`) and normalization path.
  - Ensure new fields are included in clone/merge/sanitize logic.

- Wrong app attribution:
  - Review `ActiveWindowManager` title/process heuristics and fallback behavior.

## Style and Implementation Conventions

- Keep one primary class per file; follow existing namespaces and folder boundaries.
- Use guard clauses for invalid state.
- Avoid forceful exception swallowing unless failure is intentionally non-fatal.
- Use concise comments only where logic is non-obvious (hook/filter/math/interop sections).
- Preserve existing Chinese-first user copy unless explicitly adding bilingual UI pattern.
- When adding a new page/window/popup, add matching analytics in the same change: emit a `pageview` for the page and `click` events for key entry/actions, using the shared tracking helpers and stable cross-platform names.

## High-Risk Files (Review Carefully)

- `KeyStats/Services/InputMonitorService.cs`
- `KeyStats/Services/StatsManager.cs`
- `KeyStats/App.xaml.cs`
- `KeyStats/Helpers/NativeInterop.cs`
- `KeyStats/Helpers/ThemeManager.cs`

Changes in these files can impact data integrity, global input capture, startup/exit stability, or all UI updates.
