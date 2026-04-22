# KeyStatsHelper Xcode 手动配置步骤

> 配合 `2026-04-20-accessibility-helper-split.md` 的 MVP 实现使用。Swift 源文件已写好（`KeyStats/Shared/`、`KeyStats/Helper*.swift`、`KeyStats/RemoteEventProcessor.swift`、`KeyStatsHelper/`），接下来需要在 Xcode GUI 里完成项目文件（`KeyStats.xcodeproj`）的配置。
>
> 这些步骤只能手动在 Xcode 里做，做完一次 commit 到 `project.pbxproj`。之后的迭代不再需要动项目文件。

## Step 1 — 把主 app 端新文件加入 KeyStats target

把下面 6 个文件拖进 Xcode 项目导航器，**Target Membership 只勾 `KeyStats`**：

- `KeyStats/Shared/HelperLocations.swift`
- `KeyStats/Shared/HelperPayloadFields.swift`
- `KeyStats/Shared/HelperProtocols.swift`
- `KeyStats/HelperSupervisor.swift`
- `KeyStats/HelperXPCClient.swift`
- `KeyStats/RemoteEventProcessor.swift`

`KeyStats/Shared/` 下的 3 个文件在 Step 2 还会被 KeyStatsHelper target 共享，那时再补勾。

## Step 2 — 新建 KeyStatsHelper target

File → New → Target → **macOS App**（⚠️ 不要选 Command Line Tool，后者产物不是 `.app` bundle）。

- **Product Name:** `KeyStatsHelper`
- **Bundle Identifier:** `com.keystats.app.helper`
- **Language:** Swift
- **Interface:** 随便选（自动生成的文件会全部删掉）

Target 创建完成后：

1. **删干净 Xcode 自动生成的模板文件**（从 target 和磁盘都删）：
   - `KeyStatsHelper/KeyStatsHelperApp.swift` 或 `AppDelegate.swift`
   - `KeyStatsHelper/ContentView.swift`
   - `KeyStatsHelper/Assets.xcassets`
   - `KeyStatsHelper/Preview Content/`
   - Xcode 自动生成的 `Info.plist`（若被放到别处）

2. **加入我们仓库里已经写好的文件**到 `KeyStatsHelper` target：
   - `KeyStatsHelper/main.swift`
   - `KeyStatsHelper/EventTapController.swift`
   - `KeyStatsHelper/PayloadBuilder.swift`
   - `KeyStatsHelper/ButtonRoleClassifier.swift`
   - `KeyStatsHelper/HelperXPCListener.swift`
   - `KeyStatsHelper/HelperIdleSupervisor.swift`
   - `KeyStatsHelper/Info.plist`（不加入任何 target，仅通过 `INFOPLIST_FILE` 引用）
   - `KeyStatsHelper/KeyStatsHelper.entitlements`（同上）

3. **把 Shared 文件补勾 Target Membership：**
   - `KeyStats/Shared/HelperLocations.swift`
   - `KeyStats/Shared/HelperPayloadFields.swift`
   - `KeyStats/Shared/HelperProtocols.swift`

   每个文件的 Target Membership 应同时勾 `KeyStats` 和 `KeyStatsHelper`。

4. **Build Settings** — 选中 KeyStatsHelper target 设置：

   | Setting | Value |
   | --- | --- |
   | `INFOPLIST_FILE` | `KeyStatsHelper/Info.plist` |
   | `GENERATE_INFOPLIST_FILE` | `NO` |
   | `CODE_SIGN_ENTITLEMENTS` | `KeyStatsHelper/KeyStatsHelper.entitlements` |
   | `CODE_SIGN_IDENTITY` | `-`（ad-hoc） |
   | `CODE_SIGN_STYLE` | `Manual` |
   | `MACOSX_DEPLOYMENT_TARGET` | `13.0` |
   | `PRODUCT_BUNDLE_IDENTIFIER` | `com.keystats.app.helper` |
   | `SKIP_INSTALL` | `YES` |
   | `PRODUCT_NAME` | `KeyStatsHelper` |
   | `SWIFT_VERSION` | 和主 app 一致 |
   | `ENABLE_HARDENED_RUNTIME` | `NO`（MVP 阶段；正式发布再开） |

5. **Scheme：** Product → Scheme → Manage Schemes，确认 `KeyStatsHelper` 存在并勾选 **Shared**。

## Step 3 — KeyStats 主 app 嵌入 KeyStatsHelper.app

1. 选中 **KeyStats** target → Build Phases。
2. 顶部 `+` → **Add Target Dependency**，添加 `KeyStatsHelper`。
3. 再 `+` → **New Copy Files Phase**，重命名为 `Embed Helper`。
   - **Destination:** `Wrapper`（或选到 `Contents/Resources`）
   - **Subpath:** `Contents/Resources`
   - 拖入 `Products/KeyStatsHelper.app`（即 KeyStatsHelper target 的产物）。
   - 勾选 **Copy only when installing**: `NO`
   - 勾选 **Code Sign On Copy**: `YES`

完成后，KeyStats 主 app 编译产物应该长这样：

```
KeyStats.app/
  Contents/
    MacOS/KeyStats
    Resources/
      KeyStatsHelper.app/
        Contents/
          MacOS/KeyStatsHelper
          Info.plist
```

## Step 4 — 验证编译

`⌘B` 编译 KeyStats scheme，两个 target 都应该成功。

然后执行（替换 `KeyStats-xxx` 为实际 DerivedData 目录名）：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'KeyStats.app' -type d 2>/dev/null | head -1)
ls -la "$APP/Contents/Resources/KeyStatsHelper.app/Contents/MacOS/"
codesign -dvvv "$APP/Contents/Resources/KeyStatsHelper.app" 2>&1 | grep -E 'Identifier|CDHash'
codesign -dvvv "$APP/Contents/MacOS/KeyStats" 2>&1 | grep -E 'Identifier|CDHash'
```

预期：两个 bundle 都被 ad-hoc 签名，identifier 分别是 `com.keystats.app.helper` 和 `com.keystats.app`。

## Step 5 — 通知我

以上四步都通过后告知，我会写入 AppDelegate 的 DEBUG smoke 桩：
- 启动时 `HelperSupervisor.ensureInstalled()` 拷贝 helper 到 `~/Library/Application Support/KeyStats/Helper/` 并注册 LaunchAgent
- `HelperXPCClient.connect()` 做握手
- `HelperXPCClient.startMonitoring()` 让 helper 装 CGEventTap
- `RemoteEventProcessor` 打印收到的事件

## 常见坑

- **peer validation 被拒（DEBUG 构建）：** 主 app 在 Xcode DEBUG 构建时用的 signing identifier 可能不是 `com.keystats.app`。如果 Console 看到 `peer validation failed`，检查 `codesign -dvvv KeyStats.app | grep Identifier`。如果不对，修正主 app 的 `PRODUCT_BUNDLE_IDENTIFIER`。
- **LaunchAgent 启不起来：** 查 `launchctl print gui/$(id -u)/com.keystats.app.helper`。二进制路径必须是绝对可执行路径，权限必须 755。
- **双份 TCC 条目：** 首次跑 helper 时系统会提示授权。要在 System Settings → Privacy & Security → Accessibility 里授权 `KeyStatsHelper`（不是 KeyStats 本体）。旧的 KeyStats 条目可以保留（legacy InputMonitor 还在），MVP 阶段不处理迁移。
