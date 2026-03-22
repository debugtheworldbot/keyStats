# TODOS

## Focus Tracking Follow-ups

### Translate Focus strings to Chinese (zh-Hans)
**What:** Add Chinese translations to Localizable.strings for the new Focus section strings (section.focus, stats.focused, stats.longestBlock, stats.switches, focus.noActivity).
**Why:** The codebase has Chinese-language comments throughout, suggesting a Chinese-speaking user base. English-only strings are inconsistent with existing localization.
**Pros:** Consistent localization quality; no second-class string experience for Chinese users.
**Cons:** Requires translation — either by the author or a contributor.
**Context:** The Focus section was added in the focus-tracking PR. NSLocalizedString keys were added but only English entries were created. Chinese strings should be added to the zh-Hans.lproj/Localizable.strings file (or created if it doesn't exist). Check existing Localizable.strings for the pattern.
**Depends on:** Focus tracking feature shipped.

---

### Revisit 500-session/day cap design
**What:** The current design caps FocusTracker's pending buffer at 500 entries independently of persisted state in DailyStats. This avoids a circular dependency (FocusTracker → StatsManager.currentStats). However, on relaunch after already having 499 persisted sessions, a new day's first 500 events fill the buffer before checking persisted count.
**Why:** UserDefaults has a ~1MB practical limit per app. At 200 sessions/day × 100 bytes × 90 days ≈ 1.8MB before history stripping. With history stripping (sessions only in dailyStats key), the main risk is single-day accumulation.
**Pros:** Revisiting could enable a cleaner cap that accounts for persisted state.
**Cons:** Requires breaking the circular dependency or redesigning FocusTracker as a StatsManager extension.
**Context:** The v1 implementation caps the in-memory pending buffer at 500 in FocusTracker.appendSession(). The persisted count (DailyStats.focusSessions.count) is NOT checked at append time due to the circular dependency concern. Monitor UserDefaults size with `UserDefaults.standard.dictionaryRepresentation().values.compactMap { $0 as? Data }.map(\.count).reduce(0, +)` in the debug console.
**Depends on:** Focus tracking feature shipped, real-world usage data.

