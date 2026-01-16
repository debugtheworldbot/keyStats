# KeyStats Windows 技术文档

## 架构概述

```
┌─────────────────────────────────────────────────────────────────┐
│                        App.xaml.cs                              │
│                    (应用入口 + 托盘图标)                          │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ StatsPopup    │    │ Settings      │    │ TrayIcon      │
│ Window        │    │ Window        │    │ ViewModel     │
└───────────────┘    └───────────────┘    └───────────────┘
        │                     │                     │
        └─────────────────────┼─────────────────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      StatsManager (单例)                         │
│  - 统计数据管理                                                   │
│  - 设置管理                                                      │
│  - 历史记录                                                      │
│  - APM计算                                                       │
└─────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│ InputMonitor  │    │ Notification  │    │ Startup       │
│ Service       │    │ Service       │    │ Manager       │
└───────────────┘    └───────────────┘    └───────────────┘
```

## 核心单例服务

### 1. InputMonitorService (`Services/InputMonitorService.cs`)

**职责**: 监听全局键盘/鼠标输入

**关键实现**:
```csharp
// 使用低级Windows钩子
SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, moduleHandle, 0);
SetWindowsHookEx(WH_MOUSE_LL, mouseProc, moduleHandle, 0);
```

**事件**:
- `KeyPressed(string keyName)` - 按键事件，keyName格式: `"A"`, `"Ctrl+C"`, `"Shift+Tab"`
- `LeftMouseClicked()` - 左键点击
- `RightMouseClicked()` - 右键点击
- `MouseMoved(double distance)` - 鼠标移动距离(像素)
- `MouseScrolled(double distance)` - 滚轮距离

**采样逻辑**:
- 鼠标移动: 30 FPS采样 (`_mouseSampleInterval = 1.0/30.0`)
- 跳跃过滤: `distance < 500` 才计入

### 2. StatsManager (`Services/StatsManager.cs`)

**职责**: 统计数据的核心管理器

**数据存储路径**: `%LOCALAPPDATA%\KeyStats\`
- `daily_stats.json` - 当日统计
- `history.json` - 历史记录 (Dictionary<string, DailyStats>, key格式: "yyyy-MM-dd")
- `settings.json` - 用户设置

**防抖保存**:
```csharp
_saveInterval = 2000ms  // 写入延迟
_statsUpdateDebounceInterval = 300ms  // UI更新防抖
```

**APM计算** (动态图标颜色):
```csharp
_inputRateWindowSeconds = 3.0      // 滑动窗口
_inputRateBucketInterval = 500ms   // 桶间隔
_inputRateApmThresholds = [0, 80, 160, 240]  // APM阈值

// 颜色映射:
// < 80 APM: 无色
// 80-160 APM: 浅绿 → 绿
// 160-240 APM: 黄 → 红
// >= 240 APM: 红
```

**事件**:
- `TrayUpdateRequested` - 托盘图标/tooltip需要更新
- `StatsUpdateRequested` - 统计数据变化，UI需要刷新

**午夜重置**:
```csharp
// 使用Timer在午夜触发
var nextMidnight = DateTime.Today.AddDays(1);
_midnightTimer = new Timer((nextMidnight - DateTime.Now).TotalMilliseconds);
```

### 3. NotificationService (`Services/NotificationService.cs`)

**职责**: Windows Toast通知

**使用**: Microsoft.Toolkit.Uwp.Notifications
```csharp
new ToastContentBuilder()
    .AddText("KeyStats")
    .AddText($"Today's key presses reached {count:N0}!")
    .Show();
```

### 4. StartupManager (`Services/StartupManager.cs`)

**职责**: 开机启动管理

**实现**: 注册表 `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`
```csharp
key.SetValue("KeyStats", $"\"{exePath}\"");
```

## 数据模型

### DailyStats (`Models/DailyStats.cs`)
```csharp
public class DailyStats {
    DateTime Date;                        // 日期 (只保留日期部分)
    int KeyPresses;                       // 总按键数
    Dictionary<string, int> KeyPressCounts;  // 按键分布 {"A": 100, "Ctrl+C": 50}
    int LeftClicks;
    int RightClicks;
    double MouseDistance;                 // 像素
    double ScrollDistance;                // 像素

    // 计算属性
    int TotalClicks => LeftClicks + RightClicks;
    string FormattedMouseDistance;        // "123.45 m" 或 "1.23 km"
    string FormattedScrollDistance;       // "1.5 k" 或 "500 px"
}
```

**距离单位转换**:
```csharp
const double MetersPerPixel = 0.000264583;  // 96 DPI下的换算
```

### AppSettings (`Models/AppSettings.cs`)
```csharp
public class AppSettings {
    bool ShowKeyPressesInTray = true;
    bool ShowMouseClicksInTray = true;
    bool NotificationsEnabled = false;
    int KeyPressNotifyThreshold = 1000;
    int ClickNotifyThreshold = 1000;
    bool EnableDynamicIconColor = false;
    DynamicIconColorStyle DynamicIconColorStyle = Icon;  // Icon | Dot
    bool LaunchAtStartup = false;
}
```

## ViewModel层

### TrayIconViewModel
- 绑定属性: `TrayIcon` (ImageSource), `TooltipText`
- 命令: `TogglePopupCommand`, `ShowStatsCommand`, `ShowSettingsCommand`, `QuitCommand`
- 订阅: `StatsManager.TrayUpdateRequested`

### StatsPopupViewModel
- 绑定属性: `KeyPresses`, `LeftClicks`, `RightClicks`, `MouseDistance`, `ScrollDistance`
- 按键分布: `Column1Items`, `Column2Items`, `Column3Items` (各5个)
- 图表: `ChartData` (ObservableCollection<ChartDataPoint>)
- 选择: `SelectedRangeIndex` (0=Week, 1=Month), `SelectedMetricIndex`, `SelectedChartStyleIndex`

### SettingsViewModel
- 所有设置项双向绑定到 `StatsManager.Settings`
- 修改后立即调用 `StatsManager.SaveSettings()`

## UI控件

### StatItemControl
```xaml
<controls:StatItemControl Icon="⌨️" Title="Key Presses" Value="{Binding KeyPresses}"/>
```
依赖属性: `Icon`, `Title`, `Value`

### KeyBreakdownControl
```xaml
<controls:KeyBreakdownControl
    Column1Items="{Binding Column1Items}"
    Column2Items="{Binding Column2Items}"
    Column3Items="{Binding Column3Items}"/>
```
- 3列布局，每列最多5个
- 空状态显示 "No key presses recorded yet"

### StatsChartControl
```xaml
<controls:StatsChartControl
    ChartData="{Binding ChartData}"
    ChartStyle="{Binding SelectedChartStyleIndex}"/>
```
- ChartStyle: 0=Line, 1=Bar
- 使用Canvas手绘，无第三方库依赖
- 包含网格线、坐标轴、数据点、悬停效果

## 关键Native API (NativeInterop.cs)

```csharp
// 钩子
SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId)
UnhookWindowsHookEx(IntPtr hhk)
CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam)

// 键盘状态
GetAsyncKeyState(int vKey)  // 检测修饰键
MapVirtualKey(uint uCode, uint uMapType)  // 虚拟键→扫描码
GetKeyNameText(int lParam, char[] lpString, int nSize)  // 获取键名

// 常量
WH_KEYBOARD_LL = 13
WH_MOUSE_LL = 14
WM_KEYDOWN = 0x0100
WM_LBUTTONDOWN = 0x0201
WM_RBUTTONDOWN = 0x0204
WM_MOUSEMOVE = 0x0200
WM_MOUSEWHEEL = 0x020A
```

## 键名映射 (KeyNameMapper.cs)

**特殊键映射表**:
```csharp
{ 0x08, "Backspace" }, { 0x09, "Tab" }, { 0x0D, "Enter" },
{ 0x1B, "Esc" }, { 0x20, "Space" },
{ 0x25, "Left" }, { 0x26, "Up" }, { 0x27, "Right" }, { 0x28, "Down" },
{ 0x70-0x7B, "F1"-"F12" },
// ... 完整映射见代码
```

**修饰键检测**:
```csharp
if (IsKeyDown(VK_CONTROL)) modifiers.Add("Ctrl");
if (IsKeyDown(VK_SHIFT)) modifiers.Add("Shift");
if (IsKeyDown(VK_MENU)) modifiers.Add("Alt");
if (IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN)) modifiers.Add("Win");
```

**输出格式**: `"Ctrl+Shift+A"`, `"Alt+Tab"`, `"Win+D"`

## 图标生成 (IconGenerator.cs)

**动态托盘图标**:
```csharp
// 16x16 位图，绘制键盘轮廓
using var bitmap = new Bitmap(16, 16, PixelFormat.Format32bppArgb);
// 根据APM设置颜色
var color = GetRateColor(ratePerSecond);
```

**APM颜色算法**:
```csharp
apm < 80: 无色 (null)
80-160: 浅绿 → 绿 (线性插值)
160-240: 黄 → 红 (线性插值)
>= 240: 红
```

## 窗口定位 (StatsPopupWindow.xaml.cs)

```csharp
// 检测任务栏位置，将弹窗定位到托盘图标附近
var workingArea = Screen.PrimaryScreen.WorkingArea;
var screenBounds = Screen.PrimaryScreen.Bounds;

if (workingArea.Bottom < screenBounds.Bottom) {
    // 任务栏在底部
    left = workingArea.Right - Width - 10;
    top = workingArea.Bottom - Height - 10;
}
// ... 处理顶部、左侧、右侧任务栏
```

## XAML值转换器 (Converters.cs)

```csharp
IntToBoolConverter      // RadioButton绑定: SelectedIndex ↔ IsChecked
BoolToVisibilityConverter  // bool ↔ Visibility.Visible/Collapsed
InverseBoolConverter    // bool取反
```

## 线程安全

- `StatsManager`: 使用 `lock(_lock)` 保护 `CurrentStats` 和 `_inputRateBuckets`
- UI更新: 通过 `Application.Current.Dispatcher.Invoke()` 回到UI线程
- Timer回调: 都在线程池线程，需要同步

## 依赖包

```xml
<PackageReference Include="Hardcodet.NotifyIcon.Wpf" Version="1.1.0" />
<PackageReference Include="Microsoft.Toolkit.Uwp.Notifications" Version="7.1.3" />
```

## 与macOS版本的对应关系

| macOS | Windows |
|-------|---------|
| `InputMonitor.swift` | `InputMonitorService.cs` |
| `StatsManager.swift` | `StatsManager.cs` |
| `MenuBarController.swift` | `App.xaml.cs` + `TrayIconViewModel.cs` |
| `StatsPopoverViewController.swift` | `StatsPopupWindow.xaml` + `StatsPopupViewModel.cs` |
| `SettingsViewController.swift` | `SettingsWindow.xaml` + `SettingsViewModel.cs` |
| `NotificationManager.swift` | `NotificationService.cs` |
| `LaunchAtLoginManager.swift` | `StartupManager.cs` |
| `UserDefaults` | JSON文件 (`%LOCALAPPDATA%\KeyStats\`) |
| `CGEvent.tapCreate` | `SetWindowsHookEx` |
| `NSStatusItem` | `Hardcodet.NotifyIcon.Wpf.TaskbarIcon` |
| `NSPopover` | 无边框WPF窗口 |
