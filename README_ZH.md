[![Awesome](https://awesome.re/mentioned-badge.svg )](https://github.com/jaywcjlove/awesome-mac#menu-bar-tools)

[English](./README_EN.md) | 简体中文


<img width="128" height="128" alt="ICON-iOS-Default-256x256@2x" src="https://github.com/user-attachments/assets/842780ed-c7a1-4c1b-a901-1f1d8babe51a" />


# KeyStats - macOS/Windows 键鼠统计菜单栏应用


KeyStats 可以统计用户每日的键盘敲击次数、鼠标点击次数、鼠标移动距离和滚动距离，并支持可选的端到端加密多设备数据同步。


  
<img width="300" height="581" alt="image" src="https://github.com/user-attachments/assets/c5146f66-0aa3-49ce-9184-2c75301bf398" />

<img width="320" height="581" alt="image" src="https://github.com/user-attachments/assets/b363093e-9aad-4d8a-8b12-1918ef843b3f" />

<img width="360" height="681" alt="image" src="https://github.com/user-attachments/assets/24a796a1-6d21-4186-9568-b223ac309078" />


## 安装与使用

### macOS

#### 方式一：使用 Homebrew 安装

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

#### 方式二：[从 GitHub Release 下载](https://github.com/debugtheworldbot/keyStats/releases)

### Windows

#### 方式一：使用 Scoop 安装

```bash
scoop bucket add keystats https://github.com/debugtheworldbot/scoop-keystats
scoop install keystats
```

#### 方式二：[从 GitHub Release 下载](https://github.com/debugtheworldbot/keyStats/releases) Windows 版本安装包

> **无需安装任何依赖**：Windows 版本使用 .NET Framework 4.8，Windows 10 (1903+) 和 Windows 11 已预装，开箱即用。如果你的 Windows 10 版本较旧（早于 1903），可以升级系统或[手动安装 .NET Framework 4.8](https://dotnet.microsoft.com/download/dotnet-framework/net48)。

### Linux

[下载 Linux 版本](https://github.com/0x5c0f/keyStats/releases)

## 功能特性

- **键盘敲击统计**：实时统计每日键盘按键次数
- **鼠标点击统计**：分别统计左键和右键点击次数
- **鼠标移动距离**：追踪鼠标移动的总距离
- **滚动距离统计**：记录页面滚动的累计距离
- **菜单栏显示**：核心数据直接显示在菜单栏
- **详细面板**：点击菜单栏图标查看完整统计信息
- **每日自动重置**：午夜自动重置统计数据
- **数据持久化**：应用重启后数据不丢失
- **多设备数据同步**：在已配对设备之间端到端加密同步支持的每日键盘和鼠标点击统计

## 系统要求

### macOS
- macOS 13.0 (Ventura) 或更高版本

### Windows
- **Windows 10 (1903+) 或 Windows 11**
- **无需安装任何依赖**：使用 .NET Framework 4.8（Windows 10/11 已预装，开箱即用）
- **应用大小**：约 5-10 MB（轻量级，无需额外运行时）

> **注意**：如果你的 Windows 10 版本较旧（早于 1903），可以：
> 1. 升级到 Windows 10 1903 或更高版本（推荐）
> 2. 或手动安装 .NET Framework 4.8：[下载链接](https://dotnet.microsoft.com/download/dotnet-framework/net48)


## 首次运行权限设置

### macOS

KeyStats 需要**辅助功能权限**才能监听键盘和鼠标事件。首次运行时：

1. 应用会弹出权限请求对话框
2. 点击"打开系统设置"
3. 在"隐私与安全性" > "辅助功能"中找到 KeyStats
4. 开启 KeyStats 的权限开关
5. 授权后应用将自动开始统计

> **注意**：如果没有授予权限，应用将无法统计任何数据。
>
> **重新安装/升级app提示**：由于应用未进行签名，每次重新安装后 macOS 不会自动更新辅助功能授权。请先在"隐私与安全性">"辅助功能"中移除 KeyStats 的旧授权，再回到应用点击"获取权限"按钮重新授权即可。
>
> **自动更新提示（未签名版本，macOS Ventura+）**：首次 Sparkle 自动更新可能失败。请先在“隐私与安全性”>"App 管理"中开启 KeyStats；如果已失败，可点击系统授权通知进入设置打开开关，再点“立即更新”重试。

### Windows

Windows 版本**无需额外权限设置**，应用启动后会自动开始统计。

> **注意**：首次启动时，Windows 可能会弹出安全警告，点击"仍要运行"即可。

## 隐私说明

KeyStats 仅保存聚合统计，**不会记录**：
- 输入的文字内容或按键顺序
- 鼠标光标或点击的具体位置

默认情况下，数据只保存在本机。只有用户主动开启多设备同步后，支持的每日按键总次数、各按键/组合键累计次数、鼠标按键点击次数和加密设备信息才会在本机加密后上传。目前不会同步鼠标移动距离、滚动距离和分应用统计，服务端也无法读取加密后的统计数据。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=debugtheworldbot/keyStats&type=date&legend=top-left)](https://www.star-history.com/#debugtheworldbot/keyStats&type=date&legend=top-left)

## 许可证

MIT License
