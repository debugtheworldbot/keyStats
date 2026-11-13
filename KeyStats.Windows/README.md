# KeyStats for Windows

一个轻量级的键盘和鼠标统计工具，适用于 Windows 系统。从 macOS 版本移植而来。

## 功能特性

- **输入监控**：追踪按键次数、鼠标点击、鼠标移动距离和滚动距离
- **系统托盘集成**：在系统托盘运行，点击查看详细统计
- **统计弹窗**：点击托盘图标查看详细统计信息
- **按键分析**：显示最常按的 15 个按键
- **历史图表**：以折线图或柱状图查看历史数据（周/月）
- **通知提醒**：达到里程碑时收到通知
- **开机自启**：可选择在系统启动时自动运行

## 系统要求

- **Windows 10 (1903+) 或 Windows 11**
- **无需安装任何依赖**：使用 .NET Framework 4.8（Windows 10/11 已预装，开箱即用）
- **应用大小**：约 5-10 MB（轻量级，无需额外运行时）

> **注意**：如果你的 Windows 10 版本较旧（早于 1903），可以：
> 1. 升级到 Windows 10 1903 或更高版本（推荐）
> 2. 或手动安装 .NET Framework 4.8：[下载链接](https://dotnet.microsoft.com/download/dotnet-framework/net48)

## 快速开始

### 下载与安装

1. 从 [Releases](https://github.com/your-repo/releases) 下载最新版本的 `KeyStats-Windows-*.zip`
2. 解压到任意目录（例如 `C:\Program Files\KeyStats`）
3. 运行 `KeyStats.exe` 即可开始使用

### 首次使用

1. **启动应用**：双击 `KeyStats.exe`，应用会在系统托盘显示图标
2. **查看统计**：点击托盘图标查看详细统计信息
3. **设置选项**：在统计窗口中可以：
   - 开启/关闭托盘显示
   - 设置通知阈值
   - 设置开机自启

### 数据存储

应用数据存储在 `%LOCALAPPDATA%\KeyStats\` 目录：
- `daily_stats.json` - 当日统计数据
- `history.json` - 历史数据（全量保留）
- `settings.json` - 用户设置

卸载应用时，只需删除程序文件夹，数据会保留在用户数据目录中。

## 开发者指南

### 构建要求

- Visual Studio 2019 或更高版本（包含 .NET 桌面开发工作负载）
- 或 .NET SDK（支持 .NET Framework 4.8）

### 使用 Visual Studio 构建

1. 在 Visual Studio 中打开 `KeyStats.sln`
2. 构建解决方案（Ctrl+Shift+B）
3. 按 F5 运行，或从 bin 文件夹运行

### 使用命令行构建

```bash
cd KeyStats.Windows
dotnet build -c Release
```

输出文件位于 `bin/Release/net48/` 目录。

### 打包发布

#### 使用打包脚本（推荐）

**方法 1：使用批处理文件（最简单）**

```cmd
# 直接双击运行，或命令行执行
build.bat
```

**方法 2：使用 PowerShell 脚本**

如果遇到执行策略错误，可以使用：

```powershell
# 方式 A：使用 -ExecutionPolicy Bypass 参数
powershell -ExecutionPolicy Bypass -File .\build.ps1

# 方式 B：临时设置执行策略（仅当前会话）
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\build.ps1

# 方式 C：使用批处理文件（推荐）
build.bat
```

**参数说明：**
- `Configuration`: `Release` 或 `Debug`（默认：Release）

**输出：**
- 发布文件：`publish/` 目录
- 打包文件：`dist/KeyStats-Windows-<版本>.zip`

#### 为什么选择 .NET Framework 4.8？

| 特性 | .NET Framework 4.8 |
|------|-------------------|
| **文件大小** | ~5-10 MB ✅ |
| **需要安装运行时** | ❌ 不需要（Windows 10/11 已预装） |
| **安装难度** | 开箱即用 ✅ |
| **启动速度** | 快速 ✅ |
| **适用场景** | 所有用户 ✅ |
| **推荐度** | ⭐⭐⭐⭐⭐ 强烈推荐 |

**优势：**
- Windows 10 (1903+) 和 Windows 11 都预装了 .NET Framework 4.8
- 应用本身只有 5-10 MB，无需打包运行时
- 用户无需安装任何额外依赖，真正开箱即用
- 性能优秀，启动快速

## 项目结构

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
│       └── Converters.cs                 # XAML value converters
```


## 技术说明

### 输入监控

使用 Windows 底层钩子（`SetWindowsHookEx`）：
- `WH_KEYBOARD_LL` - 键盘事件
- `WH_MOUSE_LL` - 鼠标事件

鼠标移动以 30 FPS 采样，避免过度占用 CPU。
超过 500 像素的跳跃会被过滤（例如鼠标突然移动）。

## 与 macOS 版本的差异

| 方面 | macOS | Windows |
|------|-------|---------|
| 权限 | 需要辅助功能权限 | 无需特殊权限 |
| 托盘显示 | 显示文本 + 图标 | 仅图标 |
| 弹窗行为 | NSPopover 锚定到菜单栏 | 无边框窗口靠近托盘 |
| 钩子机制 | CGEvent tap | SetWindowsHookEx |
| 开机自启 | SMAppService | 注册表 Run 键 |

## 常见问题

### Q: 应用无法启动？
A: 确保你的 Windows 版本是 10 (1903+) 或 11。如果版本较旧，请升级系统或手动安装 .NET Framework 4.8。

### Q: 统计数据丢失了？
A: 数据存储在 `%LOCALAPPDATA%\KeyStats\`。如果数据丢失，检查该目录下的文件是否存在。

### Q: 如何卸载？
A: 直接删除程序文件夹即可。数据会保留在用户数据目录中，如需完全清除，可手动删除 `%LOCALAPPDATA%\KeyStats\` 目录。

### Q: 支持哪些 Windows 版本？
A: Windows 10 (1903+) 和 Windows 11。更早的版本需要手动安装 .NET Framework 4.8。

## 许可证

与 macOS KeyStats 应用使用相同的许可证。
