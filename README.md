[English](./README_EN.md) | 简体中文


<img width="128" height="128" alt="ICON-iOS-Default-256x256@2x" src="https://github.com/user-attachments/assets/842780ed-c7a1-4c1b-a901-1f1d8babe51a" />


# KeyStats - macOS 键鼠统计菜单栏应用


KeyStats 是一款轻量级的 macOS 原生菜单栏应用，用于统计用户每日的键盘敲击次数、鼠标点击次数、鼠标移动距离和滚动距离。


<img width="300" height="581" alt="image" src="https://github.com/user-attachments/assets/c5146f66-0aa3-49ce-9184-2c75301bf398" />



## 安装与使用

### 方式一：使用 Homebrew 安装

```bash
# 订阅 tap
brew tap debugtheworldbot/keystats

# 安装应用
brew install keystats
```

更新应用：
```bash
brew upgrade keystats
```

### 方式二：[从 GitHub Release 下载](https://github.com/debugtheworldbot/keyStats/releases)

## 功能特性

- **键盘敲击统计**：实时统计每日键盘按键次数
- **鼠标点击统计**：分别统计左键和右键点击次数
- **鼠标移动距离**：追踪鼠标移动的总距离
- **滚动距离统计**：记录页面滚动的累计距离
- **菜单栏显示**：核心数据直接显示在 macOS 菜单栏
- **详细面板**：点击菜单栏图标查看完整统计信息
- **每日自动重置**：午夜自动重置统计数据
- **数据持久化**：应用重启后数据不丢失

## 系统要求

- macOS 13.0 (Ventura) 或更高版本


## 首次运行权限设置

KeyStats 需要**辅助功能权限**才能监听键盘和鼠标事件。首次运行时：

1. 应用会弹出权限请求对话框
2. 点击"打开系统设置"
3. 在"隐私与安全性" > "辅助功能"中找到 KeyStats
4. 开启 KeyStats 的权限开关
5. 授权后应用将自动开始统计

> **注意**：如果没有授予权限，应用将无法统计任何数据。
>
> **重新安装/升级app提示**：由于应用未进行签名，每次重新安装后 macOS 不会自动更新辅助功能授权。请先在“隐私与安全性”>“辅助功能”中移除 KeyStats 的旧授权，再回到应用点击“获取权限”按钮重新授权即可。

## 使用说明

### 菜单栏显示

应用运行后，菜单栏会显示：

```
123
45
```

- 上面的数字表示今日键盘按下的总次数
- 下面的数字表示今日鼠标点击的总次数（包含左右键）

当数字较大时会自动格式化：
- 1,000+ 显示为 `1.0K`
- 1,000,000+ 显示为 `1.0M`

### 详细面板

点击菜单栏图标会弹出详细统计面板，显示：

| 统计项 | 说明 |
|--------|------|
| 键盘敲击 | 今日按键总次数 |
| 左键点击 | 鼠标左键点击次数 |
| 右键点击 | 鼠标右键点击次数 |
| 鼠标移动 | 鼠标移动的总距离 |
| 滚动距离 | 页面滚动的累计距离 |

### 功能按钮

- **重置统计**：手动清零今日所有统计数据
- **退出应用**：关闭 KeyStats

## 项目结构

```
KeyStats/
├── KeyStats.xcodeproj/     # Xcode 项目文件
├── KeyStats/
│   ├── AppDelegate.swift           # 应用入口，权限管理
│   ├── InputMonitor.swift          # 输入事件监听器
│   ├── StatsManager.swift          # 统计数据管理
│   ├── MenuBarController.swift     # 菜单栏控制器
│   ├── StatsPopoverViewController.swift  # 详细面板视图
│   ├── Info.plist                  # 应用配置
│   ├── KeyStats.entitlements       # 权限配置
│   ├── Main.storyboard             # 主界面
│   └── Assets.xcassets/            # 资源文件
└── README.md
```

## 技术实现

- **语言**：Swift 5.0
- **框架**：AppKit, CoreGraphics
- **事件监听**：使用 `CGEvent.tapCreate` 创建全局事件监听器
- **数据存储**：使用 `UserDefaults` 进行本地持久化
- **UI 模式**：纯菜单栏应用（LSUIElement = true）

## 隐私说明

KeyStats 仅统计按键和点击的**次数**，**不会记录**：
- 具体按下了哪些键
- 输入的文字内容
- 点击的具体位置或应用

所有数据仅存储在本地，不会上传到任何服务器。

## 许可证

MIT License
