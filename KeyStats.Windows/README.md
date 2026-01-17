# KeyStats for Windows

A keyboard and mouse statistics tracker for Windows, ported from the macOS version.

## Features

- **Input Monitoring**: Tracks key presses, mouse clicks, mouse movement distance, and scroll distance
- **System Tray Integration**: Runs in the system tray with a tooltip showing current stats
- **Statistics Popup**: Click the tray icon to see detailed statistics
- **Key Breakdown**: Shows the top 15 most pressed keys
- **History Charts**: View historical data in line or bar chart format (week/month)
- **Dynamic Icon Color**: Icon color changes based on typing speed (APM)
- **Notifications**: Get notified when you reach milestones
- **Startup with Windows**: Option to launch automatically at system startup

## Requirements

- Windows 10 or Windows 11
- .NET 8.0 Runtime

## Building

### Prerequisites

- Visual Studio 2022 (17.8 or later) with .NET desktop development workload
- Or .NET 8.0 SDK

### Build with Visual Studio

1. Open `KeyStats.sln` in Visual Studio
2. Build the solution (Ctrl+Shift+B)
3. Run with F5 or from the bin folder

### Build with Command Line

```bash
cd KeyStats.Windows
dotnet build
dotnet run --project KeyStats
```

### Publish for Distribution

#### 使用打包脚本（推荐）

```powershell
# PowerShell
.\build.ps1

# 或指定参数
.\build.ps1 -Configuration Release -PublishType SelfContained -Runtime win-x64

# 批处理文件（Windows）
build.bat Release SelfContained
```

**参数说明：**
- `Configuration`: `Release` 或 `Debug`（默认：Release）
- `PublishType`: `SelfContained`（自包含，无需 .NET 运行时）或 `FrameworkDependent`（需要 .NET 运行时，默认：SelfContained）
- `Runtime`: `win-x64`、`win-x86` 或 `win-arm64`（默认：win-x64）

**输出：**
- 发布文件：`publish/` 目录
- 打包文件：`dist/KeyStats-Windows-<版本>-<运行时>-<类型>.zip`

#### 手动发布

```bash
# Self-contained single-file executable
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true

# Framework-dependent (smaller size, requires .NET runtime)
dotnet publish -c Release -r win-x64 --self-contained false
```

## Project Structure

```
KeyStats.Windows/
├── KeyStats.sln                          # Solution file
├── KeyStats/
│   ├── App.xaml(.cs)                     # Application entry point
│   ├── Services/
│   │   ├── InputMonitorService.cs        # Keyboard/mouse hooks
│   │   ├── StatsManager.cs               # Statistics management
│   │   ├── NotificationService.cs        # Toast notifications
│   │   └── StartupManager.cs             # Windows startup
│   ├── ViewModels/
│   │   ├── ViewModelBase.cs              # MVVM base class
│   │   ├── TrayIconViewModel.cs          # Tray icon logic
│   │   ├── StatsPopupViewModel.cs        # Stats popup logic
│   │   └── SettingsViewModel.cs          # Settings logic
│   ├── Views/
│   │   ├── StatsPopupWindow.xaml         # Stats popup UI
│   │   ├── SettingsWindow.xaml           # Settings UI
│   │   └── Controls/
│   │       ├── StatItemControl.xaml      # Single stat display
│   │       ├── KeyBreakdownControl.xaml  # Key breakdown grid
│   │       └── StatsChartControl.xaml    # History chart
│   ├── Models/
│   │   ├── DailyStats.cs                 # Daily statistics model
│   │   └── AppSettings.cs                # User settings model
│   └── Helpers/
│       ├── NativeInterop.cs              # Windows API P/Invoke
│       ├── KeyNameMapper.cs              # Virtual key to name mapping
│       ├── IconGenerator.cs              # Dynamic icon generation
│       └── Converters.cs                 # XAML value converters
```

## Data Storage

Data is stored in `%LOCALAPPDATA%\KeyStats\`:
- `daily_stats.json` - Current day's statistics
- `history.json` - Historical data (30 days)
- `settings.json` - User preferences

## Technical Notes

### Input Monitoring

Uses low-level Windows hooks (`SetWindowsHookEx`) with:
- `WH_KEYBOARD_LL` for keyboard events
- `WH_MOUSE_LL` for mouse events

Mouse movement is sampled at 30 FPS to avoid excessive CPU usage.
Jumps greater than 500 pixels are filtered out (e.g., when mouse teleports).

### Dynamic Icon Color (APM)

The tray icon color changes based on typing speed:
- No color: < 80 APM
- Light green to green: 80-160 APM
- Yellow to red: 160-240+ APM

APM is calculated using a 3-second sliding window with 0.5-second buckets.

## Differences from macOS Version

| Aspect | macOS | Windows |
|--------|-------|---------|
| Permissions | Accessibility permission required | No special permissions |
| Tray display | Shows text + icon | Icon only (text in tooltip) |
| Popup behavior | NSPopover anchored to menu bar | Borderless window near tray |
| Hook mechanism | CGEvent tap | SetWindowsHookEx |
| Startup | SMAppService | Registry Run key |

## License

Same license as the macOS KeyStats application.
