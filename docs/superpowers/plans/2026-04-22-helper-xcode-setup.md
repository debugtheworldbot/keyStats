# KeyStatsHelper Xcode 配置说明

> 配合 `2026-04-20-accessibility-helper-split.md` 的 MVP 实现使用。

## 最终项目结构

- **Target 名：** `helper`（Xcode 新建时用的名字）
- **产物名：** `KeyStatsHelper.app`（通过 `PRODUCT_NAME = KeyStatsHelper` 设置）
- **Bundle ID：** `com.keystats.app.helper`
- **目录：** `KeyStatsHelper/` 挂 synchronized root group（Xcode 15+），自动同步目录下所有文件到两个 target

### 目录里文件归属

`KeyStatsHelper/` 目录下的文件通过 `PBXFileSystemSynchronizedBuildFileExceptionSet` 控制：

| 文件 | KeyStats target | helper target |
|---|---|---|
| `HelperLocations.swift` | ✅ | ✅ |
| `HelperPayloadFields.swift` | ✅ | ✅ |
| `HelperProtocols.swift` | ✅ | ✅ |
| `EventTapController.swift` | ❌ | ✅ |
| `PayloadBuilder.swift` | ❌ | ✅ |
| `ButtonRoleClassifier.swift` | ❌ | ✅ |
| `HelperXPCListener.swift` | ❌ | ✅ |
| `HelperIdleSupervisor.swift` | ❌ | ✅ |
| `main.swift` | ❌ | ✅ |
| `Info.plist` | ❌ | 通过 `INFOPLIST_FILE` 引用 |
| `KeyStatsHelper.entitlements` | ❌ | 通过 `CODE_SIGN_ENTITLEMENTS` 引用 |

`exception set` 的 `target` 指向 KeyStats，里面列的是**从 KeyStats 排除**（即仅归 helper 用）。三个 Shared 文件不在排除列表里，所以两个 target 同时共享。

`KeyStats/` 根目录下的 main-app-only 文件（独立加到 KeyStats target）：
- `HelperSupervisor.swift`
- `HelperXPCClient.swift`
- `RemoteEventProcessor.swift`

## helper target build settings（已设定）

| Setting | Value |
|---|---|
| `PRODUCT_NAME` | `KeyStatsHelper` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `com.keystats.app.helper` |
| `MACOSX_DEPLOYMENT_TARGET` | `13.0` |
| `ENABLE_APP_SANDBOX` | `NO` |
| `ENABLE_HARDENED_RUNTIME` | `NO`（MVP 阶段；Release 后再开） |
| `GENERATE_INFOPLIST_FILE` | `NO` |
| `INFOPLIST_FILE` | `KeyStatsHelper/Info.plist` |
| `CODE_SIGN_ENTITLEMENTS` | `KeyStatsHelper/KeyStatsHelper.entitlements` |
| `CODE_SIGN_STYLE` | `Manual` |
| `CODE_SIGN_IDENTITY` | `-`（ad-hoc） |
| `SKIP_INSTALL` | `YES` |
| `SWIFT_VERSION` | `5.0` |

Scheme 已自动生成并 shared。

## KeyStats target 已嵌入 helper 产物

`Embed Helper` Copy Files build phase：
- Destination: `Contents/Resources`
- Copies `KeyStatsHelper.app`（helper target 的产物）
- 主 app build 完后结构：

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

## 验证 build

在 Xcode 里选 **KeyStats** scheme → `⌘B`。两个 target 应该都能编译通过。

验证产物：

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'KeyStats.app' -type d 2>/dev/null | head -1)
ls -la "$APP/Contents/Resources/KeyStatsHelper.app/Contents/MacOS/"
codesign -dvvv "$APP/Contents/Resources/KeyStatsHelper.app" 2>&1 | grep -E 'Identifier|CDHash'
codesign -dvvv "$APP/Contents/MacOS/KeyStats" 2>&1 | grep -E 'Identifier|CDHash'
```

预期两个 bundle 都是 ad-hoc 签名，identifier 分别是 `com.keystats.app.helper` 和 `com.keystats.app`。

## 历史坑（本次配置踩过的）

- **⚠️ 新建 target 要选 macOS App，不是 Command Line Tool。** Command Line Tool 产物不是 `.app` bundle，LaunchAgent + MachServices 走不通。
- **Synchronized Root Group 会自动把目录下所有文件加到 target。** 不要把 Shared 文件放到 `KeyStats/Shared/` 再手动拖进 Xcode——Xcode 15+ 会复制一份到目标 group 对应的目录。直接把 Shared 文件放到 `KeyStatsHelper/` 目录里，利用 exception set 让它们在 KeyStats target 里也可见，省事。
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 会破坏 EventTapController 等类。** Xcode 默认模板可能开启；已在 helper target 配置里删除。
- **`ENABLE_APP_SANDBOX = YES` 会让 CGEventTap 失败。** 默认 Xcode 模板开启；已关闭。
- **`SWIFT_OBJC_BRIDGING_HEADER` 是 Xcode 创建 target 时自动加的空桥。** 我们全 Swift，不需要；已删除。

## 常见运行期坑（后续 smoke 测试时会碰到）

- **peer validation 被拒（DEBUG 构建）：** 主 app Xcode DEBUG 构建的 signing identifier 可能不是 `com.keystats.app`。查 Console.app，搜 `peer validation failed`。
- **LaunchAgent 启不起来：** `launchctl print gui/$(id -u)/com.keystats.app.helper` 确认。二进制路径必须绝对。
- **双份 TCC 条目：** 第一次跑会提示授权 `KeyStatsHelper`。旧的 `KeyStats` 条目 MVP 阶段保留（legacy InputMonitor 还在），不做迁移。
