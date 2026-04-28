# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

- **Use Xcode** to build and run (`⌘R`). Do not use `xcodebuild` from command line.
- **Tests:** `swift test` (runs model tests via SPM — see `Package.swift` for the `KeyStatsCore` test target)
- **Distribution:** `./scripts/build_dmg.sh`

## Architecture

KeyStats is a **macOS menu bar app** (LSUIElement) that tracks keyboard/mouse input statistics — counts and distances only, never content.

**Data flow:**
```
KeyStatsHelper (launchd agent)
  └─ CGEventTap @ cgSessionEventTap
       └─ XPC (com.keystats.app.helper)
            └─ RemoteEventProcessor → StatsManager → MenuBarController (display)
                                                   → UserDefaults (persistence, debounced 2s)
                                                   → StatsPopoverViewController (detail panel)
```

Helper 是独立 `.app` bundle（target 名 `helper`，产物 `KeyStatsHelper.app`、bundle id `com.keystats.app.helper`）。首次启动时主 app 把它从 `Contents/Resources/KeyStatsHelper.app` 拷到 `~/Library/Application Support/KeyStats/Helper/`，写入 `~/Library/LaunchAgents/com.keystats.app.helper.plist`，再通过 XPC 握手。cdhash 稳定跨主 app 升级 ⇒ TCC 授权保留。

**Core singletons:**
- `HelperSupervisor.shared` — 安装 / 升级 Helper，注册 LaunchAgent。用 cdhash 判断是否重装。
- `HelperXPCClient.shared` — 主 app 侧 XPC 客户端（握手、startMonitoring、state observer）。
- `RemoteEventProcessor.shared` — 接收 helper 事件，还原键名（内嵌 `InputEventDecoder`），喂给 `StatsManager`。
- `StatsManager.shared` — Aggregates daily stats, per-app stats, per-key counts, peak KPS/CPS (sliding window). Handles persistence, midnight auto-reset, and menu bar update callbacks.
- `MenuBarController` — NSStatusItem with compact dual-line display (SwiftUI `MenuBarStatusSwiftUIView` hosted in `MenuBarStatusView`). Manages popover lifecycle and highlight state.

**Data models** (`AppStats.swift`, `StatsModels.swift`):
- `DailyStats` — per-day aggregate with history dictionary
- `AppStats` — per-bundle-ID breakdown
- Both are `Codable`, persisted as JSON in UserDefaults

**Windows variant** lives in `KeyStats.Windows/` (C#/.NET, separate codebase).

## Critical Rules

### Privacy
- NEVER log actual keystrokes, mouse positions, or user input content — only aggregate counts and distances

### Thread Safety
- Helper 的 CGEventTap 回调在 helper 进程主 run loop 执行；事件通过 XPC 跨进程进入主 app（回调线程为 XPC 队列）。`RemoteEventProcessor` 自己加 lock，UI 更新仍要 dispatch 回 main。
- Three `NSLock`s protect concurrent access: `inputRateLock`, `statsStateLock`, `mouseDistanceCalibrationLock`
- `HelperXPCClient.State` observer 可能在任意线程触发，订阅方（如 `StatsPopoverViewController`）自行切主队列。

### Dark Mode
- `CALayer.backgroundColor`/`borderColor` use `CGColor` (static snapshot) — they don't auto-follow appearance changes
- Always resolve dynamic colors under current `effectiveAppearance` using `resolvedCGColor(color, alpha:, for:)` helper
- Re-assign layer colors on every theme change; never cache `CGColor` values
- Prefer dynamic colors (`NSColor.labelColor`, `NSColor.controlBackgroundColor`) over hardcoded values

### UI Style
- Soft glass-card surfaces: `controlBackgroundColor` with alpha ~0.6–0.85
- Thin 0.5pt separators with low alpha, subtle shadows, 10–12pt corner radius for cards
- When adding a new page/window/popover, add matching PostHog analytics: a `pageview` event and `click` events for key actions

### Code Conventions
- Localize user-facing strings with `NSLocalizedString()` (English + Simplified Chinese)
- Use `[weak self]` in closures to prevent retain cycles
- Maintain backward compatibility with existing UserDefaults keys when changing data models

### Vendored Helper

`KeyStatsHelper.app` is **vendored** at `vendor/KeyStatsHelper.app/` (binary-tracked via `.gitattributes`). Both `scripts/build_dmg.sh` and `.github/workflows/release.yml` overwrite Xcode's freshly-built helper with this exact bundle (via `scripts/embed_vendored_helper.sh`) before `sign_app.sh` re-signs the outer app. Re-signing the helper with the unchanged `KeyStatsHelper.entitlements` is deterministic, so the shipped helper's cdhash equals `vendor/KeyStatsHelper.cdhash.txt` regardless of toolchain — TCC Accessibility grant survives Sparkle updates.

**Dev builds (Xcode `⌘R`) use the freshly-built helper, not the vendored copy** (no Xcode build phase changes). That's intentional: dev iteration shouldn't require re-vendoring after every helper edit. Only `build_dmg.sh` and CI use the vendored bundle.

**When you change anything under `KeyStatsHelper/` (sources, Info.plist, entitlements, build settings):**
1. Run `./scripts/rebuild_vendored_helper.sh` (rebuilds + signs + writes new `vendor/KeyStatsHelper.app` and `cdhash.txt`).
2. Commit `vendor/` together with the helper source change.
3. CI's `Verify vendored helper` step + `build_dmg.sh`'s fail-fast check will reject the build if you forget — the actual cdhash of `vendor/KeyStatsHelper.app` won't match the committed `cdhash.txt`.

## Dependencies (SPM)

- **PostHog** (posthog-ios) — Analytics, initialized in AppDelegate
- **Sparkle** — Auto-updates via GitHub releases appcast
