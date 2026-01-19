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

- Windows 10 (1903+) or Windows 11
- **无需安装任何依赖**（使用 .NET Framework 4.8，Windows 10/11 已预装，开箱即用）
- **应用大小：约 5-10 MB**（相比自包含版本的 100-120 MB 大幅减小）

## Building

### Prerequisites

- Visual Studio 2019 or later with .NET desktop development workload
- Or .NET SDK (支持 .NET Framework 4.8)

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

**方法 1：使用批处理文件（推荐，自动处理执行策略）**

```cmd
# 直接双击运行，或命令行执行
build.bat
```

**方法 2：使用 PowerShell 脚本**

如果直接运行 PowerShell 脚本遇到执行策略错误，可以使用以下方式：

```powershell
# 方式 A：使用 -ExecutionPolicy Bypass 参数
powershell -ExecutionPolicy Bypass -File .\build.ps1

# 方式 B：临时设置执行策略（仅当前会话）
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\build.ps1

# 方式 C：使用批处理文件（推荐）
build.bat
```

**注意**：如果遇到 "无法加载文件，因为在此系统上禁止运行脚本" 的错误，请使用 `build.bat` 或上述方式 A/B。

**参数说明：**
- `Configuration`: `Release` 或 `Debug`（默认：Release）

**输出：**
- 发布文件：`publish/` 目录
- 打包文件：`dist/KeyStats-Windows-<版本>-NetFramework48.zip`

#### .NET Framework 4.8 方案优势

| 特性 | .NET Framework 4.8 |
|------|-------------------|
| **文件大小** | ~5-10 MB ✅ |
| **需要安装 .NET** | ❌ 不需要（Windows 10/11 已预装） |
| **安装难度** | 开箱即用 ✅ |
| **启动速度** | 快速 ✅ |
| **适用场景** | 所有用户 ✅ |
| **推荐度** | ⭐⭐⭐⭐⭐ 强烈推荐 |

**为什么选择 .NET Framework 4.8？**
- Windows 10 (1903+) 和 Windows 11 都预装了 .NET Framework 4.8
- 应用本身只有 5-10 MB，无需打包运行时
- 用户无需安装任何额外依赖，真正开箱即用
- 性能优秀，启动快速

**系统要求：**

- Windows 10 (版本 1903 或更高) - 已预装 .NET Framework 4.8
- Windows 11 - 已预装 .NET Framework 4.8

如果你的 Windows 10 版本较旧（早于 1903），可以：
1. 升级到 Windows 10 1903 或更高版本（推荐）
2. 或手动安装 .NET Framework 4.8：https://dotnet.microsoft.com/download/dotnet-framework/net48

#### 手动构建

```bash
# .NET Framework 4.8 版本（推荐）
dotnet build -c Release

# 输出在 bin/Release/net48/ 目录
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
