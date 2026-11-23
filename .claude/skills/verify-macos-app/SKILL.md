---
name: verify-macos-app
description: Build, run and self-verify the KeyStats macOS app after a change — Xcode build, launch a test copy without breaking the helper's TCC grant, inject input, screenshot the real menu bar/screen, then restore the installed app. Use whenever a macOS fix or UI change should be confirmed in the running app, not just with `swift test`.
---

# Verify KeyStats on this Mac

`swift test` does not cover `StatsManager.swift` / UI code. Confirm visible behavior in the real app with this flow.

## Prerequisites (one-time, user grants)
Commands run under **T3 Code (Beta)**; macOS attributes permissions to it. It needs, in System Settings → Privacy & Security:
- **Accessibility** — `CGEventPost` input injection and `System Events` AX queries (without it, injected keys are silently dropped).
- **Screen & System Audio Recording** — `screencapture` (without it: `could not create image from display`).

Quick check: `screencapture -x /tmp/ksverify/s.png && echo ok` and
`osascript -e 'tell application "System Events" to get name of first process'`.

## Steps
1. **Build + launch test copy**: `scripts/launch_test_build.sh`
   - Builds through Xcode via AppleScript (project rule: no `xcodebuild`).
   - Copies to `/tmp/ksverify/KeyStats.app` and embeds the helper from `/Applications/KeyStats.app`, so the installed helper's cdhash is unchanged → no helper reinstall, no Accessibility re-grant. (A raw Xcode dev build would reinstall a different-cdhash helper.)
   - Quits the user's running KeyStats first. Tell the user this.
2. **Verify**
   - Menu bar dynamic color: `scripts/probe_menubar.sh [keys] [kps] [sampleSeconds]` — sends F18 presses (no text side effect; they do add to today's key count), samples the status item's real screen pixels, prints a timeline and `RESULT: PASS/FAIL`. Requires `enableDynamicIconColor` on (`defaults read com.keystats.app enableDynamicIconColor`).
   - Anything else: `screencapture -x /tmp/ksverify/shot.png` (or `-R x,y,w,h`) and Read the PNG to look at it.
   - Internal state that the screen can't show: add temporary file logging (`/tmp/ksverify/*.log`, tag lines `KSDEBUG-TEMP`, never log key names/content), rebuild, and remove before committing. `NSLog` output shows as `<private>` in `log stream`, so write to a file instead.
3. **Restore**: `scripts/restore_installed.sh`, then `rm -rf /tmp/ksverify` when done.

## Lessons
- Compare **app state vs screen pixels** separately: a correct state with stale pixels is a rendering/redraw bug, not a logic bug.
- **Check every display.** Secondary displays show a *replica* of the menu bar that refreshes only on a real redisplay; the tint-stuck bug (PR #159) appeared only there. `menubar_probe` samples the item on all screens.
- Always run a **negative control** (the pre-fix commit, e.g. `git switch --detach origin/main`) to prove the probe actually catches the bug before trusting a PASS.
- Frequent `screencapture` polling doesn't mask redraw bugs here, but if in doubt also test a single capture after an idle delay.
