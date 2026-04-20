# 辅助功能授权重塑：拆分常驻 Helper

- 日期：2026-04-20
- 作者：tian / Claude
- 状态：Draft —— 待评审
- 范围：macOS KeyStats（未签名发行版），目标 `MACOSX_DEPLOYMENT_TARGET = 13.0`，bundle id `com.keystats.app`

## 1. 背景与痛点

未签名 App 的 TCC（Transparency, Consent, Control）授权是用「bundle id + cdhash」绑定的。每次重新 `xcodebuild archive` 出来的二进制 cdhash 都会变，结果：

1. 用户升级 KeyStats 后 `AXIsProcessTrusted()` 返回 `false`。
2. 旧授权条目仍残留在 *系统设置 → 隐私与安全性 → 辅助功能* 里，但与新二进制的 cdhash 不匹配，系统把它视作「过期」，且它还会「遮蔽」新条目，导致用户必须先 **减号删除旧条目** 再 **重新拖入新版本**。
3. 每一个 KeyStats 版本升级都要重走这一套，是用户抱怨最多的点之一。

当前已有的 `PermissionFlow` 引导流程只能让「加新条目」这一步变顺滑，对「先删旧」完全无能为力。

在「不加开发者签名」的约束下，唯一能根治问题的方式是：**把需要授权的那个可执行文件独立出来，保证它的 cdhash 跨主 App 升级恒定不变**。本设计即围绕这一点展开。

## 2. 目标 / 非目标

**目标**
- 用户首次安装时授权一次 Helper，此后任何主 App 升级都不需要再去系统设置里动手。
- 主 App 继续按现有节奏迭代（周 / 双周一版），Helper 尽量长期不动。
- Sparkle 自动更新链路保持可用，不对发布脚本造成侵入式改动。
- 现存用户升级到 Helper 版本时，付出 **一次性** 的「删旧条目 + 授权 Helper」成本，但能被统一引导向导包裹。

**非目标**
- 不引入付费 Developer ID / Notarization。保持 Ad-hoc 签名。
- 不改现有数据模型 / 持久化 / UI 布局。
- 不做命令行 / SPM 单元测试以外的自动化测试（项目当前就没有 UI 测试）。
- 不支持多用户并发共享一个 Helper 实例（LaunchAgent 本身就是按登录用户隔离的，默认行为够用）。

## 3. 整体架构

```
┌──────────────────────────────┐        XPC / Mach        ┌────────────────────────────┐
│ KeyStats.app  (主 App)        │◄────────────────────────►│ KeyStatsHelper  (常驻)      │
│                               │                          │                            │
│  ├─ AppDelegate               │  事件流（keyDown/scroll/ │  ├─ CGEventTap             │
│  ├─ MenuBarController         │    mouseMove/flagsChg…）│  ├─ XPC listener            │
│  ├─ StatsManager              │                          │  ├─ 自重启 / 掉电恢复        │
│  ├─ AppActivityTracker        │                          │  └─ 运行于 LaunchAgent       │
│  ├─ RemoteEventProcessor ⚡新  │                          │                            │
│  └─ HelperSupervisor ⚡新      │                          │                            │
│     · 安装 / 升级 / 卸载 Helper │                          │                            │
│     · 管理 LaunchAgent 注册    │                          │                            │
└──────────────────────────────┘                          └────────────────────────────┘
         ▲
         │
  Sparkle 只替换 /Applications/KeyStats.app，
  不触碰 ~/Library/Application Support/KeyStats/Helper/
```

**职责切分原则**：Helper 做到极致薄 —— 只做 CGEventTap 的维护 + 把原始事件搬运过来；所有按键命名、前台 App 归属、聚合、持久化都留在主 App。薄 = 代码稳定 = 长期不需要重建 = cdhash 长期不变。

## 4. Helper 目标最小职责（严控范围）

Helper 只做以下事情：

1. **维护 CGEventTap**，监听集合与当前 `InputMonitor.startMonitoring` 里的 `eventMask` 完全一致。
2. **节流鼠标移动**：30Hz 采样逻辑留在 Helper 一侧，减少 IPC 数据量。
3. **把事件原始字段序列化** 并通过 XPC push 给主 App。保留字段：
   - `type`（CGEventType 原始值）
   - `keyCode`（`.keyboardEventKeycode`）
   - `keyboardType`（`.keyboardEventKeyboardType`）
   - `flags`（`event.flags.rawValue`）
   - `isAutoRepeat`（`.keyboardEventAutorepeat`）
   - `buttonNumber`（`.mouseEventButtonNumber`，仅 otherMouseDown）
   - `locationX/Y`（`event.location`，仅鼠标移动）
   - `scrollDX/DY`（`.scrollWheelEventDeltaAxis2 / Axis1`，仅滚动）
   - `sourcePID`（`.eventSourceUnixProcessID`，支撑 `AppActivityTracker`）
   - `timestamp`（`CFAbsoluteTimeGetCurrent()`，单调）
4. **处理 `kCGEventTapDisabledByTimeout` / `DisabledByUserInput`**：自动 `CGEvent.tapEnable(tap:true)` 重开。
5. **XPC 连接管理**：只接受单一主 App 连接；主 App 断开则关闭 tap（省 CPU），重连则重开。

Helper **不做**：按键名翻译（`UCKeyTranslate`、TIS 布局监听）、swap 左右键判断、鼠标距离滤波（>500 阈值）、按主 App 激活状态筛选、聚合、落盘、UI、上报 PostHog。

## 5. 安装位置 & cdhash 稳定策略

### 5.1 Helper 的「分发来源」和「运行位置」分离

- **分发来源（Committed Binary）**：把预构建好的 Helper `.app` 作为二进制资源提交进仓库，路径 `KeyStats/Resources/Helper/KeyStatsHelper.app/`。由 Xcode build phase 原样拷进主包 `KeyStats.app/Contents/Resources/Helper/KeyStatsHelper.app/`。
- **运行位置（Installed Binary）**：主 App 首次启动时，`HelperSupervisor` 把主包里那份 Helper 复制到 `~/Library/Application Support/KeyStats/Helper/KeyStatsHelper.app/`，并注册 LaunchAgent 启动它。**此后 CGEventTap 使用的永远是这个 installed 副本**。
- Sparkle 更新 `/Applications/KeyStats.app` → 只替换主 App 和主 App 内资源拷贝，不会动到 `~/Library/Application Support/KeyStats/Helper/`。Installed Helper 的 cdhash 保持不变 → TCC 条目有效。

### 5.2 保证 Committed Binary 字节恒定

Swift / Xcode 输出本身是不确定的（build timestamp、链接器填充、内嵌 UUID 等）。为避免每次 CI 跑都改一次 Helper 的 cdhash，我们 **故意不让 Helper 参与常规构建**：

- 新开脚本 `scripts/build_helper.sh`：`xcodebuild -scheme KeyStatsHelper archive`，产物 `--deep --force --sign -` ad-hoc 签名后拷贝覆盖到 `KeyStats/Resources/Helper/KeyStatsHelper.app/`。
- **这个脚本只在开发者 *有意* 修改 Helper 源码后手动跑**。产物直接 commit 进 git（bundle 体积预期 < 1MB）。
- 常规 `build_dmg.sh`、日常 Xcode build **不重建** Helper，只 copy。
- 仓库里维护文件 `KeyStats/Resources/Helper/HELPER_CDHASH.txt` 存当前 committed Helper 的 cdhash（由 `scripts/build_helper.sh` 生成）。主 App 代码里硬编码同一个常量 `HelperSupervisor.expectedCDHash`，作为「Helper 版本校验」的 ground truth。

### 5.3 Helper 变化时的处理

当 Helper 源码 *确实* 需要改（例：macOS 新版本 API 变化、tap 逻辑调整）：

1. 开发者跑 `scripts/build_helper.sh` → 新 Helper bundle + 新 cdhash commit。
2. 主 App 代码里 `HelperSupervisor.expectedCDHash` 同步更新。
3. 用户升级后启动主 App → `HelperSupervisor` 检查 `installed.cdhash != expected.cdhash` → 触发「Helper 升级流程」：
   - Bootout 旧 LaunchAgent。
   - 用主包内最新 Helper 覆盖 `~/Library/Application Support/KeyStats/Helper/`。
   - 引导用户重新授权（一次性）。
4. Helper 升级对用户而言是「罕见事件」，发生频率期望 < 每年一次。

## 6. IPC 协议

### 6.1 传输层

- `NSXPCConnection` + `NSXPCListener(machServiceName:)`。
- Mach service name：`com.keystats.helper`。
- LaunchAgent plist 里声明 `MachServices` 字典，launchd 负责 on-demand 启动 Helper 和 bootstrap 端口。

### 6.2 协议定义（Swift 伪代码）

```swift
@objc public protocol KeyStatsHelperProtocol {
    /// 主 App 握手，传入自身期望的协议版本；Helper 回应自身版本和授权状态
    func handshake(clientInterfaceVersion: Int,
                   reply: @escaping (_ helperVersion: Int,
                                     _ accessibilityGranted: Bool) -> Void)

    /// 启动 / 停止 tap
    func startMonitoring(reply: @escaping (_ ok: Bool, _ errorCode: Int) -> Void)
    func stopMonitoring()

    /// 纯信息：让主 App 手动触发「请求授权」
    /// Helper 只负责返回自身路径，真正打开系统设置由主 App 的 PermissionFlow 做
    func helperBundleURL(reply: @escaping (_ url: URL) -> Void)
}

@objc public protocol KeyStatsEventSinkProtocol {
    /// Helper → 主 App 的事件推送（由主 App 实现，通过 exportedObject 暴露）
    func receiveEvent(_ payload: [String: Any])
}
```

`receiveEvent` 的 payload 是一个字典，key 对应第 4 节列出的字段，value 为 plist 可序列化类型。避免自定义 Codable 对象是因为：Mach XPC 跨版本序列化出故障最常见的原因就是类型定义不一致；用字典做纯数据通道，版本容错最好，丢弃未知 key 即可。

### 6.3 版本协商

- `KeyStatsInterfaceVersion` 常量在 Helper 和主 App 代码里各自硬编码。
- 主 App 启动握手时比对：
  - `clientInterfaceVersion > helperVersion` → Helper 比主 App 老，触发 Helper 升级流程（第 5.3 节）。
  - `clientInterfaceVersion < helperVersion` → 主 App 太老（用户手动 rollback 情况），弹提示让用户重装主 App。
  - 相等 → 正常。

## 7. LaunchAgent 接入

### 7.1 选型：SMAppService vs 传统 plist

macOS 13.0+ 提供 `SMAppService.agent(plistName:)`，能从主 App 包 `Contents/Library/LaunchAgents/` 里的 plist 注册一个 per-user agent，无需管理员权限，会出现在「系统设置 → 通用 → 登录项」里可视化管理。

**选择：**SMAppService 优先。**风险：**该 API 要求 plist 引用的可执行文件位置有被 Apple 认可的路径约束；部分资料显示它希望可执行文件位于主 App 包内。我们的可执行文件在 `~/Library/Application Support/...`，这可能被拒绝。

**兜底方案：**若验证 SMAppService 拒绝 out-of-bundle 的可执行，退回到传统做法：

- `HelperSupervisor` 生成 `~/Library/LaunchAgents/com.keystats.helper.plist`，`ProgramArguments` 指向 installed Helper。
- 用 `launchctl bootstrap gui/<uid> <plist>` 加载（通过 `Process` 调用 `/bin/launchctl`）。
- 用 `launchctl bootout` 卸载。
- 不依赖签名，Apple 对传统 LaunchAgent 从不限制可执行文件位置。

**计划：**设计第一阶段就做 SPIKE 确认 SMAppService 是否接受 out-of-bundle 可执行，再落地最终实现。

### 7.2 plist 关键字段（传统方案）

```xml
<plist version="1.0">
<dict>
  <key>Label</key>                  <string>com.keystats.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/&lt;uid&gt;/Library/Application Support/KeyStats/Helper/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper</string>
  </array>
  <key>MachServices</key>
  <dict><key>com.keystats.helper</key><true/></dict>
  <key>RunAtLoad</key>              <true/>
  <key>KeepAlive</key>              <true/>
  <key>ProcessType</key>            <string>Interactive</string>
</dict>
</plist>
```

Helper 进程是 LSUIElement 风格（无 Dock 无菜单栏），直接跑 `NSApplication.shared.run()` 即可；或用 `CFRunLoopRun()`。由于没有 UI 事件源，纯 RunLoop 更轻。

## 8. 主 App 侧变更

### 8.1 新增类

- `HelperSupervisor`（单例）
  - `ensureInstalled()` —— 校验 installed Helper 存在 + cdhash 匹配 + LaunchAgent 注册。不匹配则执行 install / upgrade。
  - `uninstall()` —— 卸载 LaunchAgent + 删除 installed Helper + 删除 plist。
  - `isAuthorizedForAccessibility: Bool` —— 通过 XPC 握手结果缓存。
  - `reinstallForUpgrade()` —— Helper 版本升级路径。

- `RemoteEventProcessor`（替代 `InputMonitor` 的消费侧）
  - 实现 `KeyStatsEventSinkProtocol`，接收 Helper 推来的 payload。
  - 把现有 `InputMonitor.handleEvent(type:event:)` 拆成两半：
    - 解码 + 前台 App 识别 + 按键名翻译 → 保留在 `RemoteEventProcessor` 里。
    - 累计到 `StatsManager` 的部分不变。
  - 对外接口模拟现有 `InputMonitor.shared` 的 `hasAccessibilityPermission()` / `startMonitoring()` / `stopMonitoring()`，使上层（`AppDelegate`、`SettingsViewController`、`StatsPopoverViewController`）改动最小。

- `HelperXPCClient`
  - 对 `NSXPCConnection(machServiceName: "com.keystats.helper")` 的封装。
  - 握手、重连、错误处理、断连回调。

### 8.2 现有代码的取舍

- `InputMonitor.swift` 整体废弃，但把其中 `keyName(for:)`、`keyCodeMap`、`shouldSwapMouseButtons`、`refreshKeyboardLayoutCache` / `asciiKeyName`、`ModifierStandaloneTracker` 搬到一个新的 `InputEventDecoder.swift` 供 `RemoteEventProcessor` 复用。
- `AccessibilityPermissionCoordinator` 的 `appURLs` 从 `Bundle.main.bundleURL` 改为 installed Helper 的 URL（由 `HelperSupervisor.installedHelperURL` 提供）。
- `AppDelegate.checkAndRequestPermission` 的「授权成功」判断不再依赖 `AXIsProcessTrusted()`（主 App 本身永远不需要这个权限），改为：`HelperSupervisor.ensureInstalled()` → XPC 握手拿到 `accessibilityGranted == true`。
- 轮询逻辑 (`startPermissionPolling`) 相应改为每 2 秒发起一次 XPC `handshake`。

### 8.3 主 App 自身的 Accessibility 权限

主 App 本身 **不再** 需要 Accessibility 权限。所有事件监听都在 Helper 里发生。这是本次改造最大的架构收益：主 App 即使 cdhash 每次都变，TCC 也不在乎它。

## 9. 用户侧流程

### 9.1 全新安装

1. 用户从 DMG 拖入 `KeyStats.app`，首次启动。
2. `HelperSupervisor.ensureInstalled()` 发现 Helper 未装 → 安装到 Application Support + 注册 LaunchAgent。
3. XPC 握手 → `accessibilityGranted == false`。
4. 触发 `PermissionFlow` 引导：「请把 **KeyStatsHelper** 拖入辅助功能」。引导里的 `requiredAppURLs = [installedHelperURL]`，`PermissionFlow` 会高亮 Application Support 里那个 Helper。
5. 用户授权后 2 秒内 XPC 再次握手成功 → Helper 开 tap → 菜单栏开始计数。

### 9.2 主 App 升级（常态，预期 > 95% 的升级属此类）

1. Sparkle 替换 `/Applications/KeyStats.app`。
2. 主 App 重启，`HelperSupervisor.ensureInstalled()` 检查：
   - Installed Helper cdhash == expected → 无动作。
   - LaunchAgent 已注册 → 无动作。
3. XPC 握手成功 → 立即开始工作。用户完全无感。

### 9.3 Helper 升级（罕见）

1. 新版本主 App 里 `expectedCDHash` 变了。
2. `HelperSupervisor` 发现不匹配 → bootout 旧 agent → 复制新 Helper → bootstrap 新 agent → 弹窗：「输入监听组件升级，需要你重新授权（一次性）」。
3. 走一次 9.1 的授权流程。
4. 要引导用户删旧 `KeyStatsHelper` 条目 + 拖新的。我们可以顺便自动帮用户执行 `tccutil reset Accessibility com.keystats.helper`（TCC 辅助功能需要 sudo，实测可能不行，回落到「PermissionFlow 分步引导」）。

### 9.4 从当前 1.x 版本迁移到首个 Helper 版本

同 9.1 + 一段一次性文案：「这次更新之后，以后升级就不用再重新授权了。你需要在系统设置里删掉旧的 KeyStats 条目，并授权新的 KeyStatsHelper。」

用 `PermissionFlow` 或自写的 onboarding 里展示分步图，`tccutil reset Accessibility com.keystats.app` 若能一把清掉旧条目则直接调用，否则纯引导。

## 10. 失败与降级

| 场景 | 检测 | 行为 |
|------|------|------|
| Helper 崩溃 | LaunchAgent KeepAlive 自动拉起 | 主 App XPC 重连，1 秒内恢复 |
| XPC 连接异常 | `NSXPCConnection` invalidation handler | 显示菜单栏「连接丢失」状态，后台每 5s 重试 |
| Helper 被用户在系统设置里关闭 Accessibility | 握手返回 `granted == false` | 菜单栏显示「未授权」，点击走 PermissionFlow |
| Installed Helper 被用户手动删了 | `ensureInstalled()` 时 `fileExists == false` | 重新安装，走 9.1 |
| LaunchAgent plist 被用户清理 | `launchctl print` 里找不到 | 重新 bootstrap |
| 用户删了 `/Applications/KeyStats.app` 没走卸载 | Helper 运行时每 24 小时检查 `NSWorkspace.urlForApplication(withBundleIdentifier:)` | 返回 nil 则自己 `launchctl bootout`（阶段性 TODO） |

## 11. 构建 & 发布链路

- 新增 Xcode target `KeyStatsHelper`（Command Line Tool，但打包成 `.app`）。
  - `Info.plist`：`LSUIElement = true`、`CFBundleIdentifier = com.keystats.helper`、`CFBundlePackageType = APPL`。
  - 输出 `KeyStatsHelper.app`。
- 新增 `scripts/build_helper.sh`：
  - `xcodebuild -scheme KeyStatsHelper -configuration Release archive ...`
  - `codesign --force --deep --sign -` ad-hoc 签名（虽不影响 TCC 识别，但走一遍能避免 Gatekeeper 在首次运行时报警）。
  - 拷贝到 `KeyStats/Resources/Helper/KeyStatsHelper.app/`。
  - 计算 cdhash（`codesign -dvvv` 或 `codesign --display --verbose=4` 读 `CDHash` 字段），写入 `HELPER_CDHASH.txt`。
  - 提示开发者：是否同步更新 `HelperSupervisor.expectedCDHash` 常量（或由脚本直接 `sed` 改源码，需要开发者 review diff）。
- 主 `build_dmg.sh` 无需改动：Helper 已作为 bundle 资源嵌在主 App，`codesign --deep` 会一起签 —— 但 **关键约束**：主 App 的 `--deep` 签名会覆盖 Helper 的 ad-hoc 签名，从而改掉 Helper 的 cdhash。需要让 build phase 把 Helper 放在 `Contents/Resources/` 而非 `Contents/MacOS/` 或 `Contents/Library/...`，这样 `--deep` 不会递归重签。
- Sparkle：无变化。appcast 依然只描述主 App。

## 12. 风险与待验证项

- **R1（最高优先级）：SMAppService 是否接受引用 out-of-bundle 可执行的 plist？**
  必须在设计实现第一阶段做 SPIKE。若不接受，退回到传统 `launchctl bootstrap` 方案。
- **R2：`codesign --deep` 是否会改 Helper 的 cdhash？**
  如果会，必须把 Helper 放在 `Contents/Resources/` 之下（codesign 默认不递归 `Resources/` 里的嵌套 bundle）；若仍被覆盖，改成 build phase 在主 App 签完之后再 `codesign` 一次 Helper。
- **R3：Ad-hoc 签名 + 同一份二进制，跨 macOS 版本（13 → 14 → 15）cdhash 是否还一致？**
  预期一致（cdhash 是二进制内容的哈希），但 Apple 在 macOS 14 之后对未签名 / ad-hoc 的策略偶有收紧，需要在三个版本上各自实验一次。
- **R4：Gatekeeper quarantine 属性。**
  Helper 从主 App 里 copy 出来，理论上 `com.apple.quarantine` 扩展属性会被继承；首次 launchd 启动时可能触发 Gatekeeper 提示。解决：copy 后调用 `xattr -d com.apple.quarantine` 清理，或用 `FileManager` copy API 默认行为验证。
- **R5：tccutil reset 需要 sudo 吗？**
  文档说 per-user service 不需要，但 Accessibility 走的是 system TCC 库。需要实测 `tccutil reset Accessibility com.keystats.app` 是否能以普通用户身份清掉旧条目。若不能，纯引导用户手动操作。
- **R6：LSUIElement Helper 能否正常 host XPC listener？**
  理论上可以，但如果需要用 `NSXPCListener`（非 anonymous），launchd 得把 Mach port check-in 给进程，Helper 里用 `NSXPCListener.service()` 即可自动拿到，不需要自己 `bootstrap_check_in`。

## 13. 分阶段实施建议

按从小到大的风险顺序推进，每一步都能独立验证并回滚：

1. **Phase 0 —— SPIKE**：写一个最小验证程序，用 SMAppService 注册指向 `~/Library/...` 的 plist，确认是否成功。同步验证 R2 / R3 / R4 / R5。
2. **Phase 1 —— 抽离公共解码层**：新建 `InputEventDecoder`，把 `InputMonitor` 里能被 `RemoteEventProcessor` 复用的代码搬过去；老的 `InputMonitor` 改成调用 `InputEventDecoder`；无行为变化。
3. **Phase 2 —— 新增 Helper target + XPC 通道**：Helper 实现、主 App `HelperSupervisor` + `HelperXPCClient`、XPC 协议定义。主 App 暂不接入，`InputMonitor` 依然在主 App 里跑，只增加一个 Debug 开关 `USE_HELPER` 用于手动切换。
4. **Phase 3 —— 接入 `RemoteEventProcessor`**：`USE_HELPER=true` 时走 Helper，验证事件流完整、数据与老路径一致（可以 diff `StatsManager` 快照）。
5. **Phase 4 —— 迁移 UX**：授权入口从「授权 KeyStats」改成「授权 KeyStatsHelper」；迁移文案；一次性删旧条目引导。
6. **Phase 5 —— 发布灰度**：在 `build_dmg.sh` / `release.sh` 里把 `USE_HELPER` 默认开启；appcast 带一条「**升级后需要一次性重新授权**」提示。
7. **Phase 6 —— 清理**：彻底删除 `InputMonitor.swift`（被 `RemoteEventProcessor` + `InputEventDecoder` 替代），移除 `USE_HELPER` 开关。

## 14. 开放问题（待用户确认）

- Q1：Helper bundle id 定为 `com.keystats.helper` 可以吗？还是偏好 `com.keystats.app.helper`？
- Q2：Phase 0 的 SPIKE 结论是否会影响最终设计 —— 若 SMAppService 被否决、必须走传统 plist，是否接受「Login Items UI 不会展示 KeyStatsHelper 条目」这一副作用？
- Q3：Helper 发布后「完全卸载」入口放在主 App 设置里就够了吗？还是同时提供一个外挂脚本？
- Q4：一次性迁移的文案是否要在主 App 内做 onboarding 视频 / GIF，还是纯静态图文？（涉及到设计工作量）

---

**下一步**：待用户审阅并对 §14 的开放问题给出答复后，进入 writing-plans skill 产出实施计划。
