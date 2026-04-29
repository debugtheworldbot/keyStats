# Windows 版 KeyStats 中英文 i18n 设计

**日期**：2026-04-29
**分支**：`feat/win-i18n`
**状态**：已与用户对齐，待写实施计划

## 背景

KeyStats Windows 版（`KeyStats.Windows/`，WPF + .NET Framework 4.8）当前 UI 仅有简体中文，硬编码散落在 25 个 `*.cs` / `*.xaml` 文件中、约 358 处。macOS 版已有完整双语（`KeyStats/{en,zh-Hans}.lproj/Localizable.strings`，约 231 个 key）。

本次目标：让 Windows 版同时支持简体中文和英文，启动时跟随系统语言，并在 Settings 里提供手动覆盖。

## 目标

- 启动时根据系统 UI 语言决定显示中文或英文：
  - 简体中文（`zh-CN` / `zh-Hans*` / `zh`）→ 中文
  - 其它一切（含繁体 `zh-TW`/`zh-HK`、英文、日文等）→ 英文
- 在「设置」里提供 Language 下拉（System / 中文 / English），用户可手动覆盖系统判定
- 切换语言通过 **重启应用** 生效（用户确认后自动重启）
- 复用 macOS 版已有的翻译，避免术语不一致和重复翻译工作

## 非目标

- 不支持运行时实时切换语言（设计上选了重启方案）
- 不支持繁体中文（需要时再单独立项）
- 不本地化数字/日期格式（仅 UI 文案；`CurrentCulture` 保持系统默认）
- 不本地化 `KeyNameMapper` 输出的物理键名（`Backspace`/`Tab`/`Ctrl+Shift+A`，这是按键标签而非 UI 文案）
- 不本地化 PostHog 事件名/属性、Console 调试日志、JSON 持久化字段名、应用名 `KeyStats`、单位后缀 `m`/`km`/`px`/`k`、ISO 日期格式

## 技术方案：`.resx` + 强类型 `Strings` 静态类

### 选型理由

候选了两个方案：

| 方案 | 优点 | 缺点 |
|---|---|---|
| **`.resx` + 强类型 `Strings.Designer.cs`**（采纳） | .NET 原生零依赖；编译期 key 校验；VS 内建 `.resx` 编辑器；与"重启切换"模型完美契合 | XML merge conflict 略丑（key 数 ~200 可控） |
| JSON + 自定义 `L10n.T("key")` 辅助类 | key 命名风格自由；JSON 比 XML 友好 | 完全手写（MarkupExtension、loader、fallback）；失去编译期检查；重复造轮子 |

选 `.resx`：编译期 key 校验是 200+ key 工程的硬刚需；不需要自定义 MarkupExtension；以后想加运行时切换也能升级到 DynamicResource + 自定义 provider，不会卡死。

## 架构

### 文件布局

```
KeyStats.Windows/KeyStats/
├── Properties/
│   ├── Strings.resx              # 中性（英文，默认 + fallback）
│   ├── Strings.zh-Hans.resx      # 简体中文
│   └── Strings.Designer.cs       # 自动生成，入库
├── Helpers/
│   └── LocalizationManager.cs    # 新增：语言检测 + 应用 + 切换
├── Models/
│   └── AppSettings.cs            # 新增字段 LanguagePreference
└── Views/
    └── SettingsWindow.xaml       # 新增 Language 卡片（放在最后）
```

### 三个核心组件

#### 1. `Strings.resx`（资源）

- `Strings.resx` = 英文（中性 = 默认 = fallback）
- `Strings.zh-Hans.resx` = 简体中文
- 命名约定：`PascalCase + 类别前缀_`
  - `Settings_Title`、`Settings_DataImportExport`、`Settings_Language`
  - `Tray_OpenMainWindow`、`Tray_Quit`
  - `Notification_KeyThresholdReachedFormat`
  - `Error_AppAlreadyRunning`、`Error_StartupFailedFormat`
  - `Common_Ok`、`Common_Cancel`、`Common_Close`、`Common_Retry`
  - `Toast_ExportSuccess_Title`、`Toast_ExportSuccess_BodyFormat`
- 占位符用 `{0}` / `{1}`（C# `string.Format` 风格），不用 macOS 的 `%@` / `%1$@`
- `.resx` 和自动生成的 `Strings.Designer.cs` 都入库到 git
- key 数量预估 ~200，最终以盘点结果为准

#### 2. `LocalizationManager`（Helper 单例）

```csharp
public enum LanguagePreference { System, ZhHans, English }

public static class LocalizationManager
{
    // 启动时调用，必须在任何 UI 加载前
    public static void ApplyAtStartup(string languagePreference)
    {
        var culture = languagePreference switch
        {
            "zh-Hans" => new CultureInfo("zh-Hans"),
            "en"      => new CultureInfo("en"),
            _         => DetectFromSystem(),  // "system" 或任何未知值都走自动检测
        };

        Thread.CurrentThread.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        // CurrentCulture（数字/日期格式）保持系统默认，不动
    }

    private static CultureInfo DetectFromSystem()
    {
        var sys = CultureInfo.CurrentUICulture;
        if (sys.Name.StartsWith("zh-Hans", StringComparison.OrdinalIgnoreCase) ||
            sys.Name.Equals("zh-CN", StringComparison.OrdinalIgnoreCase) ||
            sys.Name.Equals("zh", StringComparison.OrdinalIgnoreCase))
        {
            return new CultureInfo("zh-Hans");
        }
        return new CultureInfo("en");
    }
}
```

关键点：
- 只设 `CurrentUICulture`（管资源查找），不动 `CurrentCulture`
- `zh-Hans` 是中性 culture，`ResourceManager` 会找到 `Strings.zh-Hans.resx`
- 解析失败 / 卫星 dll 缺失 → `ResourceManager` 自动回退到中性 `Strings.resx`（英文），不 crash
- `CultureInfo.DefaultThreadCurrentUICulture` 覆盖后续创建的所有线程

#### 3. `AppSettings.LanguagePreference`（持久化）

```csharp
[JsonPropertyName("languagePreference")]
public string LanguagePreference { get; set; } = "system";  // "system" | "zh-Hans" | "en"
```

字符串而非 enum：JSON 兼容老版本（老用户没这个字段，反序列化 default `"system"` = 自动检测）；写错值（如 `"fr"`）也安全 fallback 到自动检测。

### 数据流

```
App 启动
  → 加载 settings.json（StatsManager.Instance.Settings）
  → LocalizationManager.ApplyAtStartup(settings.LanguagePreference)
        ├─ "system" → DetectFromSystem() → en or zh-Hans
        ├─ "zh-Hans" → new CultureInfo("zh-Hans")
        └─ "en"     → new CultureInfo("en")
  → 设置 Thread.CurrentUICulture + DefaultThreadCurrentUICulture
  → ThemeManager.Initialize() ...
  → 后续所有 Strings.* 访问自动用这个 culture
  → XAML 加载时 x:Static 静态读取，UI 显示对应语言
```

切换流程：

```
用户在 Settings 下拉里改 Language
  → SelectionChanged 事件
  → 弹重启确认对话框
  ├─ 取消 → ComboBox 选回旧值，settings.json 不变
  └─ 确认 → 写 settings.LanguagePreference + SaveSettings()
         → Process.Start(exePath)（新进程会 mutex 重试 1-2 次）
         → Application.Current.Shutdown()
         → 旧进程 OnExit 跑完（flush stats + analytics + theme cleanup）
         → 新进程启动，按新语言加载 UI
```

## 启动流程改造

### 改动位置：`App.xaml.cs::OnStartup`

新流程在异常处理器之后、单实例 mutex 检查之前插入：

```csharp
protected override void OnStartup(StartupEventArgs e)
{
    base.OnStartup(e);
    // ... 异常处理器 ...

    // [新增] 提前加载 settings 拿到语言偏好
    var settings = StatsManager.Instance.Settings;

    // [新增] 应用语言（必须在任何 UI 加载之前）
    LocalizationManager.ApplyAtStartup(settings.LanguagePreference);

    // 单实例 mutex
    var mutex = new Mutex(true, "KeyStats_SingleInstance", out bool createdNew);
    if (!createdNew)
    {
        // mutex 失败时用纯英文兜底（语言已加载但保持简单一致）
        MessageBox.Show("KeyStats is already running.", "KeyStats",
                        MessageBoxButton.OK, MessageBoxImage.Information);
        Shutdown();
        return;
    }

    ThemeManager.Instance.Initialize();
    // ... 后续不变 ...
}
```

注意：mutex 失败提示用纯英文（不走 `Strings.*`），因为这是兜底场景，简单可靠优先。

## 迁移模式

### 类别 1：XAML 静态文本

XAML 顶部加 namespace：

```xml
xmlns:p="clr-namespace:KeyStats.Properties"
```

替换：

```xml
<!-- 前 -->
<Window Title="设置 - KeyStats" />
<TextBlock Text="数据导入 / 导出" />
<Button Content="导入" />
<TextBlock ToolTip="打开 GitHub 仓库" />

<!-- 后 -->
<Window Title="{x:Static p:Strings.Settings_WindowTitle}" />
<TextBlock Text="{x:Static p:Strings.Settings_DataImportExport}" />
<Button Content="{x:Static p:Strings.Common_Import}" />
<TextBlock ToolTip="{x:Static p:Strings.Settings_GitHubTooltip}" />
```

注意：`x:Static` 是编译期解析；新增 key 后必须重新构建一次让 Designer.cs 更新，XAML 才能识别。

### 类别 2：C# 错误提示和异常消息

```csharp
// 前
MessageBox.Show("启动错误: " + ex.Message, "按键统计错误", ...);

// 后
MessageBox.Show(string.Format(Strings.Error_StartupFailedFormat, ex.Message),
                Strings.App_Name, ...);
```

带占位符的 key 用 `*Format` 后缀：

```
Error_StartupFailedFormat = "Startup error: {0}"
Notification_KeysReachedFormat = "Today's key presses reached {0:N0}!"
```

### 类别 3：托盘菜单（`App.xaml.cs::CreateContextMenu`）

```csharp
// 前
var openMainWindowItem = new MenuItem { Header = "打开主界面" };

// 后
var openMainWindowItem = new MenuItem { Header = Strings.Tray_OpenMainWindow };
```

5 个菜单项全部走 `Strings.Tray_*`：`OpenMainWindow`、`Settings`、`StartAtLogin`、`KeyHistory`、`Quit`。

### 类别 4：Toast 通知

```csharp
// 前
new ToastContentBuilder()
    .AddText("导出成功")
    .AddText($"数据已保存到 {Path.GetFileName(dialog.FileName)}")
    .Show();

// 后
new ToastContentBuilder()
    .AddText(Strings.Toast_ExportSuccess_Title)
    .AddText(string.Format(Strings.Toast_ExportSuccess_BodyFormat, Path.GetFileName(dialog.FileName)))
    .Show();
```

### 类别 5：ViewModel 格式化字符串

业务文案翻译，物理单位保持英文：

```csharp
// 前
public string EmptyStateText => "暂无按键记录";
public string FormattedMouseDistance =>
    MouseDistance >= 1000 ? $"{MouseDistance / 1000:N2} km" : $"{MouseDistance:N2} m";

// 后
public string EmptyStateText => Strings.KeyBreakdown_EmptyState;
// 距离格式化保持原状（"m" / "km" 是国际单位，不翻译）
```

### 类别 6：Service 层

- 用户可见的异常 message（最终冒泡到 MessageBox）→ 翻译
- `Console.WriteLine` 调试日志 → **不翻译**，借此机会把残留的中文日志统一改成英文（可选）

```csharp
// 异常 message 翻译
throw new InvalidOperationException(Strings.Error_ImportInvalidFormat);

// Console 日志保持英文
Console.WriteLine("KeyStats starting...");
Console.WriteLine($"Failed to capture event {eventName}: {ex}");
```

### 类别 7：Window.Title

每个窗口的 `Title` 一律走 `{x:Static p:Strings.*_WindowTitle}`，9 个窗口都改：`SettingsWindow` / `StatsPopupWindow` / `AppStatsWindow` / `KeyboardHeatmapWindow` / `KeyHistoryWindow` / `MouseCalibrationWindow` / `NotificationSettingsWindow` / `ConfirmDialog` / `ImportModeDialog`。

## Settings UI 改动

### XAML 新增「Language」卡片（放在最后）

放在「数据导入/导出」、「通知设置」、「距离校准」之后，沿用现有 `CardBorder` + `GhostButton` 风格：

```xml
<Border Style="{DynamicResource CardBorder}" Margin="0,0,0,4" Padding="14,12">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
            <TextBlock Text="{x:Static p:Strings.Settings_Language}"
                       FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource TextPrimaryBrush}"/>
            <TextBlock Text="{x:Static p:Strings.Settings_LanguageDescription}"
                       FontSize="12"
                       Foreground="{DynamicResource TextSecondaryBrush}" Margin="0,4,0,0"/>
        </StackPanel>
        <ComboBox Grid.Column="1"
                  x:Name="LanguageComboBox"
                  MinWidth="140"
                  SelectionChanged="LanguageComboBox_SelectionChanged">
            <ComboBoxItem Content="{x:Static p:Strings.Settings_Language_System}" Tag="system"/>
            <ComboBoxItem Content="中文" Tag="zh-Hans"/>
            <ComboBoxItem Content="English" Tag="en"/>
        </ComboBox>
    </Grid>
</Border>
```

注意：`中文` 和 `English` 自指（不管当前 UI 是什么语言，看到 "中文" 就知道是中文，看到 "English" 就知道是英文），不走 `Strings.*`。只有 "System / 跟随系统" 这一项随当前 UI 翻译。

### Code-behind 行为（`SettingsWindow.xaml.cs`）

```csharp
private bool _isInitializing = true;

private void OnLoaded(...)
{
    var current = StatsManager.Instance.Settings.LanguagePreference;
    LanguageComboBox.SelectedItem = LanguageComboBox.Items
        .Cast<ComboBoxItem>()
        .FirstOrDefault(i => (string)i.Tag == current)
        ?? LanguageComboBox.Items[0];
    _isInitializing = false;
}

private void LanguageComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
{
    if (_isInitializing) return;

    var newPref = (string)((ComboBoxItem)LanguageComboBox.SelectedItem).Tag;
    var oldPref = StatsManager.Instance.Settings.LanguagePreference;
    if (newPref == oldPref) return;

    var result = MessageBox.Show(
        Strings.Language_RestartPromptMessage,
        Strings.Language_RestartPromptTitle,
        MessageBoxButton.OKCancel,
        MessageBoxImage.Information);

    if (result == MessageBoxResult.OK)
    {
        StatsManager.Instance.Settings.LanguagePreference = newPref;
        StatsManager.Instance.SaveSettings();
        RestartApp();
    }
    else
    {
        // 用户取消 → ComboBox 选回旧值
        _isInitializing = true;
        LanguageComboBox.SelectedItem = LanguageComboBox.Items
            .Cast<ComboBoxItem>()
            .FirstOrDefault(i => (string)i.Tag == oldPref);
        _isInitializing = false;
    }
}

private static void RestartApp()
{
    var exePath = Process.GetCurrentProcess().MainModule?.FileName;
    if (!string.IsNullOrEmpty(exePath))
    {
        Process.Start(exePath);
    }
    Application.Current.Shutdown();
}
```

### 重启时 mutex 冲突处理

旧进程 `Shutdown()` 后会跑 `OnExit`（flush + cleanup），mutex 在 `OnExit` 末尾才释放。新进程立即启动可能 mutex 还在。

方案：**新进程启动时 mutex 重试 1-2 次**（500ms 间隔）。改 `OnStartup` 的 mutex 检查：

```csharp
Mutex? mutex = null;
bool createdNew = false;
for (int attempt = 0; attempt < 3; attempt++)
{
    mutex = new Mutex(true, "KeyStats_SingleInstance", out createdNew);
    if (createdNew) break;
    mutex.Dispose();
    Thread.Sleep(500);
}

if (!createdNew)
{
    MessageBox.Show("KeyStats is already running.", "KeyStats", ...);
    Shutdown();
    return;
}
_singleInstanceMutex = mutex;
```

### 重启对话框文案

```
en:
  Language_RestartPromptTitle    = "Restart Required"
  Language_RestartPromptMessage  = "KeyStats needs to restart to apply the new language. Restart now?"

zh-Hans:
  Language_RestartPromptTitle    = "需要重启"
  Language_RestartPromptMessage  = "需要重启 KeyStats 才能切换语言。是否立即重启？"
```

## 翻译来源

### macOS 版 key 映射规则

macOS `Localizable.strings` 用点分式 + camelCase（`settings.title`、`notification.threshold.body.keys`）；WPF `.resx` 用下划线分隔的 PascalCase（`Settings_Title`、`Notification_Threshold_Body_Keys`）。

规则：
1. `.` → `_`
2. 每段首字母大写
3. `%@` → `{0}`，`%1$@` / `%2$@` → `{0}` / `{1}`
4. 多个占位符的 key 加 `Format` 后缀

例：

```
macOS:  "settings.mouseDistanceCalibration.success.message" = "10 cm ≈ %1$@, factor updated to %2$@.";
WPF:    Settings_MouseDistanceCalibration_Success_MessageFormat = "10 cm ≈ {0}, factor updated to {1}."
```

### 复用 vs 新增

**直接复用 macOS 翻译**（约 60-70%）：
- 设置项标题（"通知设置" / "Notification Settings"）
- 通用按钮（"OK" / "Cancel" / "Close" / "Retry"）
- 错误/成功提示通用文案
- 时间标签（"今日" / "Today"）

**Windows 独有 key**：
- 托盘相关：`Tray_OpenMainWindow`、`Tray_KeyHistory`、`Tray_Quit`
- 启动错误：`Error_StartupFailedFormat`、`Error_AppAlreadyRunning`
- Toast 通知（macOS 用 `UNUserNotificationCenter`，文案略不同）
- 导入对话框：`Import_Mode_Merge`、`Import_Mode_Overwrite`、`Import_Mode_Cancel`
- 重启提示：`Language_RestartPromptTitle/Message`
- Language 设置卡片：`Settings_Language`、`Settings_LanguageDescription`、`Settings_Language_System`

**macOS 有但 Windows 不需要**：
- `permission.*`（macOS 辅助功能权限对话框，Windows 没有）
- `menu.window`、`menu.closeWindow`（macOS 主菜单栏）
- 部分 macOS 独有 setting key

实施时一次性把所有中文抽到 `Strings.resx` / `Strings.zh-Hans.resx`，不分阶段；翻译质量靠对照 macOS 同概念词 + 自检 + 用户 review。

## 迁移文件清单

按 5 批次组织（可独立 PR 也可合并为一个大 PR）：

### 第 1 批：基础设施（约 0.5 人天）

| 文件 | 改动 |
|---|---|
| `Properties/Strings.resx` | 新建（英文，约 200 个 key） |
| `Properties/Strings.zh-Hans.resx` | 新建（简体中文） |
| `Helpers/LocalizationManager.cs` | 新建（约 60 行） |
| `Models/AppSettings.cs` | 加 `LanguagePreference` 字段 |
| `KeyStats.csproj` | 配 `.resx` 的 EmbeddedResource + 卫星程序集 culture |

### 第 2 批：启动流程（约 0.25 人天）

| 文件 | 改动要点 |
|---|---|
| `App.xaml.cs`（39 处中文） | mutex 错误、托盘菜单 5 个 item、导入/导出 toast、startup shortcut description、mutex 重试逻辑 |

### 第 3 批：主要 UI 窗口（约 1.5 人天）

| 文件 | 备注 |
|---|---|
| `Views/SettingsWindow.xaml` + `.cs`（14+1） | 同时新增 Language 卡片 |
| `Views/StatsPopupWindow.xaml` + `.cs`（27+34） | 主弹窗，工作量最大 |
| `Views/AppStatsWindow.xaml`（8） | |
| `Views/KeyboardHeatmapWindow.xaml` + `.cs`（7+11） | |
| `Views/KeyHistoryWindow.xaml`（9） | |
| `Views/MouseCalibrationWindow.xaml` + `.cs`（15+9） | 鼠标校准向导，文案多 |
| `Views/NotificationSettingsWindow.xaml`（11） | |
| `Views/ImportModeDialog.xaml`（7） | |
| `Views/ConfirmDialog.xaml` + `.cs`（4+3） | |

### 第 4 批：自定义控件（约 0.5 人天）

| 文件 | 备注 |
|---|---|
| `Views/Controls/KeyBreakdownControl.xaml`（1） | 空状态文案 |
| `Views/Controls/StatsChartControl.xaml.cs`（15） | 图例/工具提示 |
| `Views/Controls/KeyDistributionPieChartControl.xaml.cs`（4） | 图例 |

### 第 5 批：ViewModel + Service（约 0.5 人天）

| 文件 | 备注 |
|---|---|
| `ViewModels/StatsPopupViewModel.cs`（2） | 格式化字符串 |
| `ViewModels/AppStatsViewModel.cs`（11） | 应用统计标签 |
| `ViewModels/KeyHistoryViewModel.cs`（2） | 时间范围标签 |
| `Services/StatsManager.cs`（11） | 异常 message 翻译；Console 日志改英文 |
| `Services/NotificationService.cs`（3） | Toast 模板 |
| `Services/InputMonitorService.cs`（6） | 核查后多为 Console 日志，改英文 |

### 总计

- **新建**：3 文件
- **修改**：25 文件，约 358 处中文字符串迁移
- **预估总工作量**：约 3-3.5 人天

## 测试与验收

### 自动化检查

1. **编译期 key 校验**：`.resx` 自动生成静态属性，XAML 写错 key 直接编译失败
2. **零中文残留扫描**：
   ```bash
   grep -rE '[一-鿿]' KeyStats.Windows/KeyStats/ \
        --include='*.cs' --include='*.xaml' \
        --exclude='*.Designer.cs'
   ```
   除注释、`Strings.zh-Hans.resx`、`KeyNameMapper` 等允许列表外应为 0
3. **resx key 完整性脚本**（建议加 PowerShell/Python 检查）：
   - 扫描 `Strings.resx` 所有 key
   - 验证 `Strings.zh-Hans.resx` 同样存在（缺则警告但不阻断 — fallback 到英文不算 bug）
   - 列出 only-in-zh-Hans 的 key（删除时漏删）

### 手动测试矩阵

#### 启动语言检测

| 系统 UI 语言 | 期望 |
|---|---|
| `zh-CN` | 中文 UI |
| `zh-Hans-CN` | 中文 UI |
| `zh-TW` | 英文 UI（严格规则验证） |
| `en-US` | 英文 UI |
| `ja-JP` | 英文 UI（fallback 验证） |
| `de-DE` | 英文 UI |

测试方法：Windows Settings → Time & Language → 切换显示语言后重启应用；或 PowerShell `Set-WinUILanguageOverride`。

#### 手动覆盖

| 场景 | 期望 |
|---|---|
| 首次启动（无 settings.json） | 跟随系统检测 |
| `languagePreference = "system"` | 跟随系统检测 |
| `languagePreference = "zh-Hans"` | 强制中文（即使系统是英文） |
| `languagePreference = "en"` | 强制英文（即使系统是中文） |
| 老版本升级（缺该字段） | 默认 `"system"`，不破坏现有用户体验 |
| 写错值 `"fr"` | fallback 到 `DetectFromSystem()`，不 crash |

#### 切换流程

1. 中文 UI 下打开 Settings → 选 English → 弹重启对话框（中文）→ 确认 → 退出 → 自动启动 → 全英文 UI ✅
2. 同上但点取消 → ComboBox 选回原值，不重启，settings.json 不变 ✅
3. 切换瞬间 mutex 冲突 → 新进程重试 1-2 次（500ms 间隔）→ 成功启动 ✅
4. 切换前未保存的统计数据 → `OnExit` 的 `FlushPendingSave` 跑完 → 重启后数据完整 ✅

#### UI 完整性

每个窗口在中英文下各打开一次，检查窗口标题、所有按钮、Label/TextBlock、ToolTip、错误对话框、Toast 通知、空状态。9 个窗口：StatsPopup / Settings / NotificationSettings / MouseCalibration / AppStats / KeyboardHeatmap / KeyHistory / ImportModeDialog / ConfirmDialog。

#### 边界

- **长字符串溢出**：英文比中文长（"Mouse Distance Calibration" vs "距离校准"），检查 SettingsWindow 卡片不会撑破布局
- **数字格式**：只动 `CurrentUICulture`，`CurrentCulture` 保持系统默认 → 数字 `1,234.56` 显示规则不变
- **运行期系统语言变化**：app 不响应（要重启），符合预期
- **Toast 历史**：旧 toast 不回退翻译，新发的用新语言

### PR checklist

- [ ] `Strings.resx` 和 `Strings.zh-Hans.resx` key 数量一致
- [ ] 全文搜索 `[一-鿿]` 在 `*.cs` / `*.xaml` 文件里仅命中允许列表
- [ ] 所有 9 个窗口在中英文下各跑一遍
- [ ] 系统语言切换 4 个 case（zh-CN / zh-TW / en-US / ja-JP）启动测试
- [ ] 升级测试：用旧版 settings.json 启动新版，确认无 crash 且默认跟随系统
- [ ] 打包后从 `dist/` zip 启动验证（卫星程序集 `zh-Hans/KeyStats.resources.dll` 正确打包）

### 验收 Demo 路径

5 分钟可跑完：
1. 系统语言为 `zh-CN`，启动 → 中文 UI
2. 打开 Settings → 改 Language 为 English → 弹重启对话框（中文）→ 确认
3. 重启后全英文 UI
4. 改回 中文 → 弹重启对话框（英文）→ 确认 → 重启后中文

## 已对齐的关键决策

| 决策点 | 选项 |
|---|---|
| 是否提供手动语言切换 | 是（Settings 里加下拉，自动检测 + 手动覆盖） |
| 系统语言判定规则 | 严格简体（`zh-CN`/`zh-Hans*`/`zh` → 中文；其它 → 英文） |
| 切换语言生效方式 | 重启 app（弹确认对话框） |
| 翻译技术方案 | `.resx` + 强类型 `Strings.Designer.cs` |
| 中性 `.resx` 用哪种语言 | 英文（也是 fallback 兜底） |
| `LanguagePreference` 持久化类型 | 字符串 `"system"` / `"zh-Hans"` / `"en"` |
| `Strings.Designer.cs` 入库 | 入库（VS 默认行为） |
| Settings 卡片位置 | 放最后 |
| mutex 冲突处理 | 新进程启动时重试 1-2 次（500ms 间隔） |
| mutex 失败提示 | 纯英文兜底（不走 `Strings.*`） |
| Console 日志翻译 | 不翻译，借机统一改成英文（可选） |
