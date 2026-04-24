# Helper 拆分首发版本 — 发布说明模板

> 这份模板用于首次发布包含 `KeyStatsHelper` 的版本。之后常规升级不需要重复这段内容。

## Appcast / GitHub Release 文案（English）

```
## One-time authorization

This release moves keyboard and mouse monitoring into a lightweight
helper. After updating, you'll be asked ONCE to:

1. Remove the old "KeyStats" entry in
   System Settings → Privacy & Security → Accessibility (minus button).
2. Authorize "KeyStatsHelper" when KeyStats prompts you.

KeyStats attempts to clear the old entry for you automatically. You'll
only need to do this dance once — future updates keep the helper in
place and never require re-authorization.

## What's new

- <list normal bullet changes here>
```

## 中文版本

```
## 一次性授权更新

本版将键鼠监听拆到了独立的轻量 Helper。升级后你需要完成一次性步骤：

1. 打开 系统设置 → 隐私与安全性 → 辅助功能，用减号删掉旧的
   "KeyStats" 条目。
2. 在 KeyStats 的弹窗引导下授权 "KeyStatsHelper"。

KeyStats 会尽力自动清理旧条目。此操作仅此一次——以后升级 KeyStats 不
会再提示重新授权。

## 更新内容

- <列其他改动>
```

## 发布前 checklist

- [ ] `codesign -dvvv KeyStats.app/Contents/Resources/KeyStatsHelper.app | grep CDHash` 对比上一版本，确认同源编译 cdhash 一致
- [ ] `./scripts/build_dmg.sh` 成功产出 DMG，且嵌入断言通过
- [ ] 在干净测试账号上：全新安装 DMG → 迁移弹窗出现一次 → 授权 KeyStatsHelper → 菜单栏计数增长
- [ ] 升级测试：从上一版本升到本版本 → 迁移弹窗出现一次 → 授权 KeyStatsHelper → 旧 KeyStats 条目被清理 或 有清晰引导
- [ ] Settings → 卸载 Helper 工作（helper 进程退出、Application Support 目录清空、TCC 条目消失）
- [ ] 再启动主 app → helper 自动重装并重新要求授权
