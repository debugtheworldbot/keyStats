# 辅助功能授权重塑：拆分常驻 Helper

- 日期：2026-04-20
- 作者：tian / Claude
- 状态：Reviewed —— 待进入 implementation planning
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
- 不破坏现有「是否开机启动」语义。用户控制的仍然是 `KeyStats.app` 本体；Helper 不额外暴露成一个单独的登录项开关。
- Helper 只有在主 App 建立通过校验的会话后才开始采集；默认不对同会话内任意进程暴露输入事件流。

**非目标**
- 不引入付费 Developer ID / Notarization。保持 Ad-hoc 签名。
- 不改现有数据模型 / 持久化 / UI 布局。
- 不做命令行 / SPM 单元测试以外的自动化测试（项目当前就没有 UI 测试）。
- 不支持多用户并发共享一个 Helper 实例（LaunchAgent 本身就是按登录用户隔离的，默认行为够用）。
- 不把当前 ad-hoc 签名条件下的 Helper XPC 鉴权包装成「强安全边界」。若未来要抵御同一登录用户下的恶意进程，需要单独引入稳定的加密签名身份，这不在本轮范围内。

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

**职责切分原则**：Helper 做到极致薄 —— 只做 CGEventTap 的维护、少量无法在主 App 可靠重建的事件归一化、以及事件搬运；所有按键命名、前台 App 归属、聚合、持久化都留在主 App。薄 = 代码稳定 = 长期不需要重建 = cdhash 长期不变。

**安全边界原则**：
- Helper 是高敏感组件。默认 dormant，不允许“先连上再说”，必须先校验客户端再开始采集。
- 当前约束下（主 App 仍为 ad-hoc 签名），XPC 侧只能做到**强约束的 guardrail**，不能做到类似 Developer ID 那样的密码学级别身份证明。
- 设计必须显式写出这个边界，避免实现阶段把“单连接”误当成“已鉴权”。

## 4. Helper 目标最小职责（严控范围）

Helper 只做以下事情：

1. **维护 CGEventTap**，监听集合与当前 `InputMonitor.startMonitoring` 里的 `eventMask` 完全一致。
2. **节流鼠标移动**：30Hz 采样逻辑留在 Helper 一侧，减少 IPC 数据量。
3. **做两类不可逆但必要的轻量归一化**：
   - 为点击事件计算 `buttonRole`（`primary` / `secondary` / `back` / `forward`），以保留当前「主按钮在右侧」+ 鼠标/触控板差异的行为语义。
   - 记录单调时钟 `monotonicTime`（使用 `ProcessInfo.processInfo.systemUptime`），供主 App 的速率窗口和峰值统计继续使用单调时间基准。
4. **把最小必要字段序列化** 并通过 XPC push 给主 App。保留字段：
   - `type`（CGEventType 原始值）
   - `keyCode`（`.keyboardEventKeycode`）
   - `keyboardType`（`.keyboardEventKeyboardType`）
   - `flags`（`event.flags.rawValue`）
   - `isAutoRepeat`（`.keyboardEventAutorepeat`）
   - `buttonRole`（仅点击事件）
   - `locationX/Y`（仅鼠标移动）
   - `scrollDX/DY`（`.scrollWheelEventDeltaAxis2 / Axis1`，仅滚动）
   - `sourcePID`（`.eventSourceUnixProcessID`，支撑 `AppActivityTracker`）
   - `monotonicTime`
5. **处理 `kCGEventTapDisabledByTimeout` / `DisabledByUserInput`**：自动 `CGEvent.tapEnable(tap:true)` 重开。
6. **XPC 连接管理**：只保留单一已校验的主 App 会话；连接失效时立刻关闭 tap、清空敏感状态，并进入短暂 idle 退出。

Helper **不做**：按键名翻译（`UCKeyTranslate`、TIS 布局监听）、前台 App 归属、鼠标距离滤波（>500 阈值）、按主 App 激活状态筛选、聚合、落盘、UI、上报 PostHog。

## 5. 安装位置 & cdhash 稳定策略

### 5.1 Helper 的「分发来源」和「运行位置」分离

- **分发来源（Committed Payload）**：把预构建好的 Helper `.app` 打成归档资源后提交进仓库，路径改为 `KeyStats/Resources/Helper/KeyStatsHelper.app.zip`，旁边附一个 `HelperManifest.json`。Xcode build phase 只把这两个**数据文件**原样拷进主包 `KeyStats.app/Contents/Resources/Helper/`。
- **运行位置（Installed Binary）**：主 App 首次启动时，`HelperSupervisor` 将 zip 解包到临时目录，先递归移除 `com.apple.quarantine`，再校验 bundle id / 接口版本 / cdhash / `codesign --verify` 均符合 manifest，最后原子性落到 `~/Library/Application Support/KeyStats/Helper/KeyStatsHelper.app/` 并注册 LaunchAgent。**此后 CGEventTap 使用的永远是这个 installed 副本**。
- Sparkle 更新 `/Applications/KeyStats.app` → 只替换主 App 和主包内的 zip payload，不会动到 `~/Library/Application Support/KeyStats/Helper/`。Installed Helper 的 cdhash 保持不变 → TCC 条目有效。

### 5.2 保证 Committed Payload 字节恒定

Swift / Xcode 输出本身是不确定的（build timestamp、链接器填充、内嵌 UUID 等）。为避免每次 CI 跑都改一次 Helper 的 cdhash，我们 **故意不让 Helper 参与常规主 App 构建**：

- 新开脚本 `scripts/build_helper.sh`：
  - `xcodebuild -scheme KeyStatsHelper archive`
  - 对 `KeyStatsHelper.app` 做 ad-hoc 签名
  - 用 `ditto -c -k --keepParent` 打出 `KeyStatsHelper.app.zip`
  - 计算 Helper 可执行文件的 cdhash
  - 生成 `HelperManifest.json`（包含 `bundleId`、`interfaceVersion`、`cdhash`、`archiveName`）
- **这个脚本只在开发者 *有意* 修改 Helper 源码后手动跑**。zip + manifest 直接 commit 进 git。
- 常规 `build_dmg.sh`、日常 Xcode build **不重建** Helper，只 copy zip + manifest。
- 主 App 运行时从 `HelperManifest.json` 读取 expected helper metadata；不再在源码里硬编码 `expectedCDHash`，避免 manifest / 代码双写漂移。
- 不能只依赖“开发者记得手动跑脚本”。`build_helper.sh` 需要把 Helper 的版本字段和构建输入固定为显式输入，不在脚本里隐式改写；若 Phase 0 证明同源码重复构建仍有漂移，再补最小必要的 linker reproducibility 设置（优先评估 `-Wl,-reproducible`，`-Wl,-no_uuid` 仅在确认不影响崩溃定位 / 调试工作流后才可采用）。
- 增加一个 payload 一致性校验脚本 / CI job：读取 committed `KeyStatsHelper.app.zip` 里的 Helper 可执行文件 cdhash，与 `HelperManifest.json` 对比；不一致直接 fail。这样能拦住“改了 Helper 源码但忘了重打 payload”或“打了 payload 但 manifest / zip 没一起提交”。

### 5.3 Helper 变化时的处理

当 Helper 源码 *确实* 需要改（例：macOS 新版本 API 变化、tap 逻辑调整）：

1. 开发者跑 `scripts/build_helper.sh` → 新 zip payload + 新 manifest commit。
2. 用户升级后启动主 App → `HelperSupervisor` 读 manifest，发现 `installed.cdhash != manifest.cdhash` → 触发「Helper 升级流程」：
   - 断开现有 XPC / bootout 旧 LaunchAgent。
   - 解包并校验新的 Helper。
   - 用新的 installed Helper 原子替换旧副本。
   - 重新注册 LaunchAgent。
   - 引导用户重新授权（一次性）。
3. Helper 升级对用户而言是「罕见事件」，发生频率期望 < 每年一次。

## 6. IPC 协议

### 6.1 传输层

- 主 App：`NSXPCConnection(machServiceName:)`
- Helper：`NSXPCListener(machServiceName:)`
- Mach service name：`com.keystats.app.helper`
- LaunchAgent plist 里声明 `MachServices` 字典，launchd 负责按需拉起 Helper 和托管 bootstrap 端口。
- 这里是 **LaunchAgent + MachServices** 模型，不是 app bundle 内的 XPC Service；实现中不使用 `NSXPCListener.service()`。
- 在 macOS 13+ 上，Helper listener 先用 `setConnectionCodeSigningRequirement(_:)` 做第一层预过滤；只要 requirement 不满足，连接在 delegate 介入前就会被系统拒绝。

### 6.2 连接接受与对端校验

Helper 在 `listener(_:shouldAcceptNewConnection:)` 里再做第二层 peer validation。实现路径明确为 Foundation / Security 的公开 API，不依赖未公开的 `auditToken` 属性。校验顺序：

1. listener 预先设置 code signing requirement，至少要求 peer identifier 为 `com.keystats.app`。
2. 读取 `newConnection.effectiveUserIdentifier` 与 `auditSessionIdentifier`，确认调用方属于当前登录用户和当前 GUI session。
3. 读取 `newConnection.processIdentifier`，仅把它作为**即时查询** live peer code object 的输入，不把 PID 本身当作身份缓存。
4. 用 `SecCodeCopyGuestWithAttributes(... kSecGuestAttributePid ...)` + `SecCodeCheckValidity(...)` 获取并校验当前 peer 的 `SecCode`；随后用 `SecCodeCopySigningInformation(...)` 读取 signing identifier，并用 `SecCodeCopyPath(...)` 读取实际 bundle / executable 路径。
5. 比对 signing identifier == `com.keystats.app`，且路径 == `HelperSupervisor` 维护的 canonical main app path。
6. 校验协议版本兼容。

通过后才：

- 设置 `exportedInterface` / `remoteObjectInterface`
- 记录为唯一 active client
- 允许 `startMonitoring()`

失败则立即 `invalidate()` 连接，不暴露任何事件流。

**边界说明**：这套校验在 ad-hoc 签名前提下属于 defense-in-depth，不是密码学意义上的强身份认证。它的目标是避免“同会话任意进程误连 Helper”这一类问题；如果未来要抵御同 uid 的恶意仿冒进程，必须单独引入稳定签名身份。

### 6.3 协议定义（Swift 伪代码）

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

`receiveEvent` 的 payload 是一个字典，key 对应第 4 节列出的字段，value 严格限制为 property-list types。避免自定义 Codable 对象是因为：Mach XPC 跨版本序列化出故障最常见的原因就是类型定义不一致；用字典做纯数据通道，版本容错最好，丢弃未知 key 即可。

实现要求：

- 即便 property-list collection 默认可被 NSXPC 接受，`NSXPCInterface` 仍然要对 `receiveEvent(_:)` 的第一个参数显式 `setClasses(...)`，把集合内容收窄到 `NSDictionary` / `NSString` / `NSNumber` 这一组 allowlist，避免后续字段演化时无意引入非预期对象类型。
- payload 继续只承载 plist 值；若将来协议复杂到需要嵌套集合或非 plist 类型，再单独评估是否切换为 `NSSecureCoding` 封装对象，而不是现在提前引入自定义 model class。

### 6.4 版本协商

- `KeyStatsInterfaceVersion` 常量在 Helper 和主 App 代码里各自硬编码。
- 主 App 启动握手时比对：
  - `clientInterfaceVersion > helperVersion` → Helper 比主 App 老，触发 Helper 升级流程（第 5.3 节）。
  - `clientInterfaceVersion < helperVersion` → 主 App 太老（用户手动 rollback 情况），弹提示让用户重装主 App。
  - 相等 → 正常。

## 7. LaunchAgent 接入

### 7.1 选型：直接使用传统 LaunchAgent（放弃 SMAppService.agent）

本设计**直接选传统 per-user LaunchAgent + MachServices**，不再把 `SMAppService.agent(plistName:)` 当主路径，原因：

- Helper 的可执行文件明确位于 `~/Library/Application Support/...`，不是主包内 code item。
- Helper 需要的是“按需被主 App 叫起”的后台组件，而不是一个单独可见的登录项入口。
- 当前产品已经有 `SMAppService.mainApp` 控制 `KeyStats.app` 是否登录时启动；继续沿用这一条用户可见语义最清晰。
- 这样可以彻底避免“Helper 自己在登录项里跑起来，但主 App 其实没被用户允许开机启动”的行为回归。

因此：

- `KeyStats.app` 是否开机启动：继续由现有 `LaunchAtLoginManager` 控制。
- `KeyStatsHelper` 是否运行：由主 App 是否建立 XPC 连接决定，默认 on-demand，不在登录时单独常驻。

### 7.2 plist 关键字段（传统方案）

```xml
<plist version="1.0">
<dict>
  <key>Label</key>                  <string>com.keystats.app.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/&lt;uid&gt;/Library/Application Support/KeyStats/Helper/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper</string>
  </array>
  <key>MachServices</key>
  <dict><key>com.keystats.app.helper</key><true/></dict>
  <key>LimitLoadToSessionType</key> <array><string>Aqua</string></array>
  <key>ProcessType</key>            <string>Interactive</string>
</dict>
</plist>
```

这个 plist **不是**仓库里的一份静态文件，而是安装时由 `HelperSupervisor` 动态生成：

- 文件名遵循 `<Label>.plist`，即 `com.keystats.app.helper.plist`
- `ProgramArguments[0]` 写入 `installedHelperURL.path`
- 路径必须是绝对路径；不能依赖 `~`、`$HOME` 或相对路径展开

不设置 `RunAtLoad` / `KeepAlive`：

- 第一次 XPC 连接时由 launchd 拉起。
- Helper 崩溃后，主 App 的重连动作会触发 launchd 再次拉起。
- 主 App 正常退出后，Helper 关闭 tap 并在短 idle timeout 后退出，不在后台长期挂着。

Helper 进程是 LSUIElement 风格（无 Dock 无菜单栏），直接跑 `CFRunLoopRun()` 即可；不需要额外 UI 事件源。

### 7.3 生命周期约定

- `ensureInstalled()` 负责“安装文件 + 注册 LaunchAgent”，不负责把 Helper 永久跑起来。
- `RemoteEventProcessor.startMonitoring()` 建立 XPC 连接后，Helper 才真正进入监控状态。
- 连接断开时，Helper 必须立刻停 tap、清理事件会话状态，并在 idle timeout 后自行退出。
- 用户关闭「开机启动」后，登录时不会有任何 KeyStats 组件自动运行；直到用户手动打开 `KeyStats.app`。

## 8. 主 App 侧变更

### 8.1 新增类

- `HelperSupervisor`（单例）
  - `ensureInstalled()` —— 校验 installed Helper 存在 + manifest 匹配 + LaunchAgent 注册。不匹配则执行 install / upgrade。
  - `uninstall()` —— 卸载 LaunchAgent + 删除 installed Helper + 删除 plist。
  - `isAuthorizedForAccessibility: Bool` —— 通过 XPC 握手结果缓存。
  - `reinstallForUpgrade()` —— Helper 版本升级路径。
  - `syncAuthorizedClientLocation()` —— 记录 canonical main app path，供 Helper 做 peer validation。

  `uninstall()` 的顺序固定为：
  1. `launchctl bootout` 当前用户域中的 `com.keystats.app.helper`
  2. 删除 `~/Library/LaunchAgents/com.keystats.app.helper.plist`
  3. 删除 `~/Library/Application Support/KeyStats/Helper/`
  4. best-effort 执行 `tccutil reset Accessibility com.keystats.app.helper`
  5. 若 reset 失败，提示用户到系统设置中手动移除旧条目

- `RemoteEventProcessor`（替代 `InputMonitor` 的消费侧）
  - 实现 `KeyStatsEventSinkProtocol`，接收 Helper 推来的 payload。
  - 把现有 `InputMonitor.handleEvent(type:event:)` 拆成两半：
    - 解码 + 前台 App 识别 + 按键名翻译 → 保留在 `RemoteEventProcessor` 里。
    - 累计到 `StatsManager` 的部分不变。
  - 对外接口模拟现有 `InputMonitor.shared` 的 `hasAccessibilityPermission()` / `startMonitoring()` / `stopMonitoring()`，使上层（`AppDelegate`、`SettingsViewController`、`StatsPopoverViewController`）改动最小。

- `HelperXPCClient`
  - 对 `NSXPCConnection(machServiceName: "com.keystats.app.helper")` 的封装。
  - 握手、重连、错误处理、断连回调。

### 8.2 现有代码的取舍

- `InputMonitor.swift` 整体废弃，但把其中 `keyName(for:)`、`keyCodeMap`、`refreshKeyboardLayoutCache` / `asciiKeyName`、`ModifierStandaloneTracker` 搬到一个新的 `InputEventDecoder.swift` 供 `RemoteEventProcessor` 复用。
- 左右键对调 + 鼠标/触控板差异判断保留在 Helper 侧，主 App 只消费已经归一化后的 `buttonRole`。
- `AccessibilityPermissionCoordinator` 的 `appURLs` 从 `Bundle.main.bundleURL` 改为 installed Helper 的 URL（由 `HelperSupervisor.installedHelperURL` 提供）。
- `AppDelegate.checkAndRequestPermission` 的「授权成功」判断不再依赖 `AXIsProcessTrusted()`（主 App 本身永远不需要这个权限），改为：`HelperSupervisor.ensureInstalled()` → XPC 握手拿到 `accessibilityGranted == true`。
- 轮询逻辑 (`startPermissionPolling`) 相应改为每 2 秒发起一次 XPC `handshake`。
- `StatsManager` 当前使用单调时间窗口的逻辑继续沿用，但输入时间戳来源改为 Helper payload 里的 `monotonicTime`。
- 在切换到 Helper 路径前，先做一次全仓库 sweep：把所有 `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions()` / `InputMonitor.hasAccessibilityPermission()` 的调用点统一迁移到 `HelperSupervisor.isAuthorizedForAccessibility`，避免新旧权限判断并存。

### 8.3 主 App 自身的 Accessibility 权限

主 App 本身 **不再** 需要 Accessibility 权限。所有事件监听都在 Helper 里发生。这是本次改造最大的架构收益：主 App 即使 cdhash 每次都变，TCC 也不在乎它。

## 9. 用户侧流程

### 9.1 全新安装

1. 用户从 DMG 拖入 `KeyStats.app`，首次启动。
2. `HelperSupervisor.ensureInstalled()` 发现 Helper 未装 → 从主包内 zip payload 解包、校验并安装到 Application Support，再注册 LaunchAgent。
3. XPC 握手 → `accessibilityGranted == false`。
4. 触发 `PermissionFlow` 引导：「请把 **KeyStatsHelper** 拖入辅助功能」。引导里的 `requiredAppURLs = [installedHelperURL]`，`PermissionFlow` 会高亮 Application Support 里那个 Helper。
   - 引导文案要提前解释路径原因，例如：「KeyStats 把监听组件安装在这里，是为了以后升级主 App 时不用重复授权。」
5. 用户授权后 2 秒内 XPC 再次握手成功 → Helper 开 tap → 菜单栏开始计数。

### 9.2 主 App 升级（常态，预期 > 95% 的升级属此类）

1. Sparkle 替换 `/Applications/KeyStats.app`。
2. 主 App 重启，`HelperSupervisor.ensureInstalled()` 检查：
   - Installed Helper 与 bundled manifest 一致 → 无动作。
   - LaunchAgent 已注册 → 无动作。
3. XPC 握手成功 → 立即开始工作。用户完全无感。

### 9.3 Helper 升级（罕见）

1. 新版本主 App 内置的 `HelperManifest.json` 变了。
2. `HelperSupervisor` 发现 installed Helper 与新 manifest 不匹配 → bootout 旧 agent → 解包并安装新 Helper → bootstrap 新 agent → 弹窗：「输入监听组件升级，需要你重新授权（一次性）」。
3. 走一次 9.1 的授权流程。
4. 要引导用户删旧 `KeyStatsHelper` 条目 + 拖新的。我们可以顺便自动帮用户执行 `tccutil reset Accessibility com.keystats.app.helper`（TCC 辅助功能需要 sudo，实测可能不行，回落到「PermissionFlow 分步引导」）。

### 9.4 从当前 1.x 版本迁移到首个 Helper 版本

同 9.1 + 一段一次性文案：「这次更新之后，以后升级就不用再重新授权了。你需要在系统设置里删掉旧的 KeyStats 条目，并授权新的 KeyStatsHelper。」

用 `PermissionFlow` 或自写的 onboarding 里展示分步图，`tccutil reset Accessibility com.keystats.app` 若能一把清掉旧条目则直接调用，否则纯引导。

## 10. 失败与降级

| 场景 | 检测 | 行为 |
|------|------|------|
| Helper 崩溃 | `NSXPCConnection` interruption / invalidation | 主 App 关闭监控态并重连；launchd 在下一次连接尝试时重新拉起 Helper |
| XPC 连接异常 | `NSXPCConnection` invalidation handler | 显示菜单栏「连接丢失」状态，后台每 5s 重试 |
| XPC peer validation 失败 | Helper 拒绝连接 | 视为安全/安装异常，提示用户重装主 App 或修复安装位置，不启动 tap |
| Helper 被用户在系统设置里关闭 Accessibility | 握手返回 `granted == false` | 菜单栏显示「未授权」，点击走 PermissionFlow |
| Installed Helper 被用户手动删了 | `ensureInstalled()` 时 `fileExists == false` | 重新从 zip payload 安装，走 9.1 |
| LaunchAgent plist 被用户清理 | `launchctl print` 里找不到 | 重新 bootstrap |
| 主 App 被用户移动到新路径 | peer validation 用旧 canonical path 失败，或 `Bundle.main.bundleURL` 与记录值不符 | `HelperSupervisor.syncAuthorizedClientLocation()` 更新记录并重新建立连接 |

### 10.1 可观测性

- Helper 使用独立的 `Logger(subsystem: "com.keystats.app.helper", category: ...)`，至少覆盖 `lifecycle`、`xpc`、`eventtap`、`install` 四类日志。
- 约定运维查询命令：`log show --predicate 'subsystem == "com.keystats.app.helper"' --last 10m`
- 主 App 启动时可 best-effort 扫描 `~/Library/Logs/DiagnosticReports/KeyStatsHelper*.ips`；若发现新崩溃，仅上报元数据到 PostHog（版本、异常类型、主线程签名、发生时间），不得包含任何输入事件内容。
- 设定连续崩溃退避：例如 60 秒内连续失败 3 次后，停止自动重连，菜单栏进入明显异常态，并引导用户查看权限 / 安装状态。

## 11. 构建 & 发布链路

- 新增 Xcode target `KeyStatsHelper`（Command Line Tool，但打包成 `.app`）。
  - `Info.plist`：`LSUIElement = true`、`CFBundleIdentifier = com.keystats.app.helper`、`CFBundlePackageType = APPL`。
  - 输出 `KeyStatsHelper.app`。
  - entitlements：显式保持 `com.apple.security.app-sandbox = false`。
  - 不为本方案额外启用 Hardened Runtime 或 runtime exception entitlements；若未来分发策略变化导致需要 notarization，再单独评估。
  - 基线只使用 `LSUIElement = true`；不默认同时设置 `LSBackgroundOnly = true`，因为后者语义更严格，会改变激活 / 窗口行为，而当前 Helper 不需要这层约束。
- 新增 `scripts/build_helper.sh`：
  - `xcodebuild -scheme KeyStatsHelper -configuration Release archive ...`
  - 对 `KeyStatsHelper.app` 做 ad-hoc 签名。
  - 用 `ditto -c -k --keepParent` 打出 `KeyStats/Resources/Helper/KeyStatsHelper.app.zip`。
  - 计算 Helper cdhash 并写入 `HelperManifest.json`。
  - 让开发者 review zip + manifest diff。
- 新增 CI / 本地校验脚本 `verify_helper_payload`：
  - 解出 committed zip 中的 `KeyStatsHelper.app`
  - 读取可执行文件 cdhash
  - 与 `HelperManifest.json` 比对
  - 不一致立即 fail
- 主 `build_dmg.sh` 可以在第一阶段保持现状：Helper payload 在主包里只是普通数据文件，不再依赖 `codesign --deep` 对嵌套 bundle 的具体行为。
- 后续如要继续硬化发布链路，可以把主包顶层的 `codesign --deep` 替换为显式嵌套签名流程；但这不是 Helper 方案的前置条件。
- Sparkle：无变化。appcast 依然只描述主 App。

## 12. 风险与待验证项

- **R1（最高优先级）：ad-hoc 前提下的 peer validation 不是强身份认证。**
  需要明确 threat model：它足以约束误连/低成本误用，但不足以抵御同 uid 下的恶意仿冒进程。这个边界必须在实现和文档里都保留。
- **R2：zip 解包后代码签名与 quarantine 行为。**
  需要验证 `ditto` 打包/解包后 Helper 仍满足签名校验，并确认递归移除 `com.apple.quarantine` 后，首次 launchd 启动不会被 Gatekeeper / xattr 状态卡住。
- **R3：MachServices + on-demand LaunchAgent 的恢复路径。**
  需要实测 Helper 崩溃、主 App 重连、用户注销/登录、Sparkle 重启等场景下，是否都能稳定恢复。
- **R4：tccutil reset 需要 sudo 吗？**
  文档说 per-user service 不需要，但 Accessibility 走的是 system TCC 库。需要实测 `tccutil reset Accessibility com.keystats.app` / `com.keystats.app.helper` 是否能以普通用户身份清掉旧条目。若不能，纯引导用户手动操作。
- **R5：Helper 升级时是否仍然必须重新授权。**
  当前设计按“需要重新授权”保守处理；若后续实验表明显式 designated requirement 能稳定跨 Helper 版本复用 TCC 条目，可作为后续优化，不阻塞本方案。
- **R6：main app path 变化与 canonical path 同步。**
  需要验证 Sparkle 更新、用户手动拖动 App 位置、从非 `/Applications` 启动首装等情况下，`syncAuthorizedClientLocation()` 是否足够稳健。

## 13. 分阶段实施建议

按从小到大的风险顺序推进，每一步都能独立验证并回滚：

1. **Phase 0 —— SPIKE**：验证 zip payload 解包后的签名可用；验证 LaunchAgent + MachServices 的按需拉起；验证 peer validation 技术路径；同步验证 `tccutil reset` 行为。
   - 同一台机器、同一份源码连续跑 3 次 `build_helper.sh`，确认生成的 Helper cdhash 一致；若不一致，再引入最小必要的 reproducibility 设置并重复验证。
   - 走完整路径验证：DMG → `/Applications` → 首次启动 → 解包 Helper → 清理 quarantine → `codesign --verify` → 建立 XPC / launchd 按需拉起，全链路都不被 xattr 卡住。
   - 以普通 GUI 用户身份实测 `tccutil reset Accessibility com.keystats.app` 与 `com.keystats.app.helper`，记录是否需要 sudo / 是否会失败。
2. **Phase 1 —— 抽离公共解码层**：新建 `InputEventDecoder`，把 `InputMonitor` 里仍需保留在主 App 的键盘解码逻辑搬过去；点击归一化则明确转移到 Helper 侧；老的 `InputMonitor` 改成调用新边界，行为不变。
3. **Phase 2 —— 新增 Helper target + payload 构建链路**：Helper target、`build_helper.sh`、zip payload、manifest 生成、`HelperSupervisor.ensureInstalled()` 的解包校验逻辑。
4. **Phase 3 —— LaunchAgent + XPC 通道 + peer validation**：落地 `HelperXPCClient`、Mach service、连接接受校验、单活会话和 idle exit。
5. **Phase 4 —— 接入 `RemoteEventProcessor`**：`USE_HELPER=true` 时走 Helper，验证事件流完整、统计结果与老路径一致（可以 diff `StatsManager` 快照）；并完成全仓库 `AXIsProcessTrusted*` 调用点 sweep。
6. **Phase 5 —— 迁移 UX**：授权入口从「授权 KeyStats」改成「授权 KeyStatsHelper」；补一次性删旧条目引导；确认不会破坏现有 launch-at-login 提示链路。
7. **Phase 6 —— 发布灰度**：在 `build_dmg.sh` / `release.sh` 的发布分支上把 `USE_HELPER` 默认开启；appcast 带一条「**升级后需要一次性重新授权**」提示。
8. **Phase 7 —— 清理**：彻底删除 `InputMonitor.swift`（被 `RemoteEventProcessor` + `InputEventDecoder` 替代），移除 `USE_HELPER` 开关。

## 14. 已确认决策

- Helper bundle id 采用 `com.keystats.app.helper`；Mach service name 与 LaunchAgent label 保持同名，统一为 `com.keystats.app.helper`。
- 接受当前轮的安全边界定义：Helper 做严格 peer validation，但不承诺抵御同 uid 的恶意仿冒进程；若未来要提升到强身份认证，单独立项。
- Helper 的「完全卸载」入口仅放在主 App 内，不额外提供外挂脚本。
- 首次迁移与罕见 Helper 升级都采用静态图文文案，不做视频 / GIF 版 onboarding。

---

**下一步**：当前 spec 已收敛完毕，可以进入 writing-plans skill 产出 implementation plan。
