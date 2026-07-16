[![Awesome](https://awesome.re/mentioned-badge.svg )](https://github.com/jaywcjlove/awesome-mac#menu-bar-tools)

English | [简体中文](./README_ZH.md)

<img width="128" height="128" alt="ICON-iOS-Default-256x256@2x" src="https://github.com/user-attachments/assets/842780ed-c7a1-4c1b-a901-1f1d8babe51a" />


# KeyStats - macOS/Windows Keyboard & Mouse Statistics Menu Bar App

KeyStats is a lightweight native menu bar application for macOS and Windows that tracks daily keyboard keystrokes, mouse clicks, mouse movement distance, and scroll distance, with optional end-to-end encrypted multi-device sync.

<img width="305" height="632" alt="image" src="https://github.com/user-attachments/assets/85c0b483-ad4a-458c-8bf4-c4f054b951bb" />

<img width="320" height="581" alt="image" src="https://github.com/user-attachments/assets/b363093e-9aad-4d8a-8b12-1918ef843b3f" />

<img width="1920" height="816" alt="image" src="https://github.com/user-attachments/assets/7f3e93bf-57de-415d-857f-7416efa67eda" />
<img width="1304" height="966" alt="image" src="https://github.com/user-attachments/assets/79dd41e4-94fc-46ef-826d-160a4b75ad35" />



## Installation & Usage

### macOS

#### Option 1: Install via Homebrew

```bash
# Tap the repository
brew tap debugtheworldbot/keystats

# Install the app
brew install keystats
```

Update the app:
```bash
brew upgrade keystats
```

#### Option 2: [Download from GitHub Releases](https://github.com/debugtheworldbot/keyStats/releases)

### Windows

#### Option 1: Install via Scoop

```bash
scoop bucket add keystats https://github.com/debugtheworldbot/scoop-keystats
scoop install keystats
```

#### Option 2: [Download from GitHub Releases](https://github.com/debugtheworldbot/keyStats/releases)

> **No dependencies required**: The Windows version uses .NET Framework 4.8, which is pre-installed on Windows 10 (1903+) and Windows 11 - ready to use out of the box. If your Windows 10 version is older (before 1903), you can upgrade your system or [manually install .NET Framework 4.8](https://dotnet.microsoft.com/download/dotnet-framework/net48).

### Linux

[Download the Linux version](https://github.com/0x5c0f/keyStats/releases)

## Features

- **Keyboard Keystroke Statistics**: Real-time tracking of daily key presses
- **Mouse Click Statistics**: Separate tracking of left and right clicks
- **Mouse Movement Distance**: Track total distance of mouse movement
- **Scroll Distance Statistics**: Record cumulative page scroll distance
- **Menu Bar Display**: Core data displayed directly in macOS menu bar
- **Detailed Panel**: Click menu bar icon to view complete statistics
- **Daily Auto-Reset**: Statistics automatically reset at midnight
- **Data Persistence**: Data persists after application restart
- **Multi-Device Sync**: End-to-end encrypted synchronization of supported daily keyboard and mouse-click statistics across paired devices

## System Requirements

### macOS
- macOS 13.0 (Ventura) or higher

### Windows
- **Windows 10 (1903+) or Windows 11**
- **No dependencies required**: Uses .NET Framework 4.8 (pre-installed on Windows 10/11, ready to use out of the box)
- **App size**: ~5-10 MB (lightweight, no additional runtime needed)

> **Note**: If your Windows 10 version is older (before 1903), you can:
> 1. Upgrade to Windows 10 1903 or higher (recommended)
> 2. Or manually install .NET Framework 4.8: [Download link](https://dotnet.microsoft.com/download/dotnet-framework/net48)


## First Run Permission Setup

### macOS

KeyStats requires **Accessibility permissions** to monitor keyboard and mouse events. On first run:

1. The app will prompt a permission request dialog
2. Click "Open System Settings"
3. Find KeyStats in "Privacy & Security" > "Accessibility"
4. Enable the permission toggle for KeyStats
5. Once authorized, the app will automatically start tracking

> **Note**: Without granting permissions, the app will not be able to track any data.
>
> **Reinstall/upgrade tip**: Because the app is not signed, macOS will not automatically update Accessibility authorization after each reinstall. Remove the existing KeyStats entry in "Privacy & Security" > "Accessibility", then return to the app and click the "Get Permission" button to request access again.
>
> **Auto-update tip (unsigned builds, macOS Ventura+)**: The first Sparkle update may fail. Enable KeyStats in "Privacy & Security" > "App Management" first. If it already failed, click the system authorization notification, turn on the toggle in Settings, and click "Update Now" again.

### Windows

The Windows version **requires no additional permission setup**. The app will automatically start tracking once launched.

> **Note**: On first launch, Windows may show a security warning. Click "Run anyway" to proceed.

## Privacy Statement

KeyStats stores aggregate statistics and **does NOT record**:
- Typed text or the order of keystrokes
- Specific cursor or click locations

Data stays on the local device by default. When you explicitly enable multi-device sync, supported daily key-press totals, per-key/key-combination counts, mouse-button click counts, and encrypted device information are encrypted locally before upload. Mouse movement distance, scroll distance, and per-app statistics are not currently synced, and the service cannot read the encrypted statistics.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=debugtheworldbot/keyStats&type=date&legend=top-left)](https://www.star-history.com/#debugtheworldbot/keyStats&type=date&legend=top-left)

## License

MIT License
