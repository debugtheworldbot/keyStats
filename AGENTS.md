# KeyStats - AI Agent Development Guide

**Project Type**: macOS Native Menu Bar Application
**Language**: Swift 5.0
**Target**: macOS 13.0+ (Ventura)
**Architecture**: Event-driven singleton pattern with AppKit UI

## Quick Context

KeyStats is a privacy-focused macOS menu bar app that tracks keyboard/mouse statistics (counts only, no content logging). Core components:

- `InputMonitor`: Global event tap for keyboard/mouse monitoring
- `StatsManager`: Data aggregation and persistence (UserDefaults)
- `MenuBarController`: Status bar UI with compact dual-line display
- `StatsPopoverViewController`: Detailed statistics panel

**Privacy First**: NEVER log actual keystrokes, mouse positions, or user input content - only aggregate counts and distances.

---

## Decision Trees for Common Tasks

### 🔧 Before Making Any Code Changes

```
1. Read the relevant file(s) first
2. Check existing patterns and naming conventions
3. Verify Swift version compatibility (5.0+)
4. Consider thread safety (main vs background threads)
5. Check if changes affect permissions or privacy
```

### 🎯 When Adding New Features

```
New feature request?
├─ UI-related?
│  ├─ Menu bar display? → Update MenuBarController
│  └─ Detail panel? → Update StatsPopoverViewController
├─ Statistics tracking?
│  ├─ New metric? → Update StatsManager.Stats struct + persistence
│  └─ New event type? → Update InputMonitor event callbacks
├─ Data persistence? → Update StatsManager Codable conformance
└─ Permissions needed? → Update Info.plist + AppDelegate
```

### 🐛 When Debugging Issues

```
Issue type?
├─ No statistics updating?
│  ├─ Check: AXIsProcessTrusted() returns true
│  ├─ Check: InputMonitor.isMonitoring is true
│  └─ Check: Event tap is active (not nil)
├─ UI not updating?
│  ├─ Verify: Updates on DispatchQueue.main
│  └─ Check: menuBarUpdateHandler is set
├─ Data not persisting?
│  └─ Check: StatsManager.saveStats() called on changes
└─ Performance issues?
    └─ Review: Event sampling rates and debounce timers
```

---

## Critical Rules

### 🔴 MUST Follow (Security & Privacy)

- ✅ Only track counts and distances, NEVER content
- ✅ Always check accessibility permissions before monitoring
- ✅ Use `weak` references for delegates/closures to prevent leaks
- ✅ Dispatch UI updates on `DispatchQueue.main`
- ✅ Clean up event taps in `stopMonitoring()` and `deinit`

### 🟡 SHOULD Follow (Quality)

- ✅ One class per file, filename matches class name
- ✅ Use `// MARK: -` for code organization
- ✅ Use `guard` for early returns and validation
- ✅ Use descriptive names, avoid magic numbers
- ✅ Localize user-facing strings with `NSLocalizedString()`
- ✅ Ensure UI colors adapt to dark mode (use dynamic colors + `resolvedCGColor`/`resolvedColor`)
- ✅ When adding a new page/window/popover, add matching analytics at the same time: a `pageview` for the page itself and `click` events for key entry/actions, reusing the shared helper and stable event/property names

### 🌗 Dark/Light Theme Switching Notes (Critical)

- ✅ `CALayer.backgroundColor` / `borderColor` use `CGColor` (a static snapshot) and do not automatically follow appearance changes
- ✅ Do not cache `NSColor.controlBackgroundColor.withAlphaComponent(...)` and reuse it across updates (especially when launched in dark mode), as it may lock in the old appearance
- ✅ For "dynamic system color + alpha", always resolve under the current `effectiveAppearance` using a helper, e.g. `resolvedCGColor(color, alpha:for:)`
- ✅ Re-assign layer colors on every theme change; do not rely on existing `CGColor` values to auto-update
- ✅ Prefer multi-source appearance refresh triggers: `AppearanceTrackingView`, `NSApp.effectiveAppearance`, `AppleInterfaceThemeChangedNotification`, and `NSApplication.didBecomeActiveNotification`
- ✅ When debugging theme issues, log `app/view/window` appearance plus final layer RGBA first to distinguish "trigger path issues" from "color resolution issues"

### 🟢 RECOMMENDED (Best Practices)

- ✅ Document public APIs with `///` comments
- ✅ Use `private` for internal implementation details
- ✅ Implement Codable for data structures needing persistence
- ✅ Batch UI updates to reduce main thread blocking

---

## Build & Development Commands

### Building

```bash
# Development (Xcode - recommended)
open KeyStats.xcodeproj
# Press ⌘R to build and run

# Command line (Debug)
xcodebuild -project KeyStats.xcodeproj -scheme KeyStats -configuration Debug build

# Command line (Release)
xcodebuild -project KeyStats.xcodeproj -scheme KeyStats -configuration Release build
```

### Distribution

```bash
# Create DMG for distribution
./scripts/build_dmg.sh
```

### Testing

```bash
# Currently no automated tests
# When adding: Use XCTest framework in separate Tests target
xcodebuild test -project KeyStats.xcodeproj -scheme KeyStats
```

---

## Code Patterns & Examples

### Singleton Pattern (Thread-Safe)

```swift
class StatsManager {
    static let shared = StatsManager()
    private init() {
        // Load from persistence
    }
}
```

### Permission Checking

```swift
// Check permission status
let trusted = AXIsProcessTrusted()

// Request permissions with prompt
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
AXIsProcessTrustedWithOptions(options as CFDictionary)
```

### Main Thread UI Updates

```swift
DispatchQueue.main.async {
    self.updateMenuBarDisplay()
    self.menuBarUpdateHandler?()
}
```

### Event Monitoring Setup

```swift
let eventMask = (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.leftMouseDown.rawValue)

eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: eventCallback,
    userInfo: nil
)
```

### Debounced Updates

```swift
private var updateTimer: Timer?

func scheduleDebouncedStatsUpdate() {
    updateTimer?.invalidate()
    updateTimer = Timer.scheduledTimer(
        withTimeInterval: 0.5,
        repeats: false
    ) { [weak self] _ in
        self?.updateMenuBar()
    }
}
```

### Data Persistence (Codable)

```swift
struct Stats: Codable {
    var keyPresses: Int = 0
    var leftClicks: Int = 0
    // ... other properties
}

func saveStats() {
    if let encoded = try? JSONEncoder().encode(currentStats) {
        UserDefaults.standard.set(encoded, forKey: "currentStats")
    }
}

func loadStats() -> Stats? {
    guard let data = UserDefaults.standard.data(forKey: "currentStats") else { return nil }
    return try? JSONDecoder().decode(Stats.self, from: data)
}
```

---

## File Structure & Responsibilities

```
KeyStats/
├── AppDelegate.swift
│   ├─ App lifecycle & menu bar setup
│   ├─ Permission checking & request handling
│   └─ Window/status bar initialization
│
├── InputMonitor.swift
│   ├─ Global event tap creation (CGEvent.tapCreate)
│   ├─ Keyboard event handling (keyDown)
│   ├─ Mouse event handling (left/right clicks, movement)
│   └─ 30Hz mouse sampling for performance
│
├── StatsManager.swift
│   ├─ Statistics data model (Codable struct)
│   ├─ Data aggregation & calculation
│   ├─ UserDefaults persistence
│   ├─ Daily auto-reset at midnight
│   └─ Debounced UI update callbacks
│
├── MenuBarController.swift
│   ├─ NSStatusItem management
│   ├─ Dual-line compact display (keyPresses/clicks)
│   ├─ Number formatting (K/M suffixes)
│   └─ Popover presentation trigger
│
└── StatsPopoverViewController.swift
    ├─ Detailed statistics display (all metrics)
    ├─ Reset button handling
    └─ Quit button handling
```

---

## Common Modification Scenarios

### Adding a New Statistic

1. **Update Stats struct** in `StatsManager.swift`:

```swift
struct Stats: Codable {
    var newMetric: Int = 0  // Add new property
    // ... existing properties
}
```

2. **Add tracking logic** in `InputMonitor.swift`:

```swift
private let eventCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    // ... existing logic
    StatsManager.shared.incrementNewMetric()  // Add call
}
```

3. **Add increment method** in `StatsManager.swift`:

```swift
func incrementNewMetric() {
    currentStats.newMetric += 1
    scheduleDebouncedStatsUpdate()
}
```

4. **Update UI** in `StatsPopoverViewController.swift`:

```swift
// Add label and update in refreshStats()
newMetricLabel.stringValue = "\(stats.newMetric)"
```

### Modifying Menu Bar Display

Edit `MenuBarController.updateMenuBarText()`:

```swift
func updateMenuBarText(keyPresses: Int, mouseClicks: Int) {
    let line1 = formatNumber(keyPresses)  // Top line
    let line2 = formatNumber(mouseClicks) // Bottom line
    // Update attributed string
}
```

### Changing Reset Behavior

Edit `StatsManager.resetStats()`:

```swift
func resetStats() {
    currentStats = Stats()  // Reset to defaults
    saveStats()             // Persist immediately
    updateMenuBar()         // Update UI
}
```

---

## UI Style (macOS Liquid Glass)

### Design Rules

- Prefer soft surfaces: use `controlBackgroundColor` with alpha ~0.6–0.85 for panels/cards
- Avoid heavy borders: use thin 0.5pt separators with low alpha instead of 1pt strokes
- Use subtle shadows: small radius, low opacity, slight upward offset
- Keep corners consistent: 10–12pt for cards, smaller (6–8pt) for compact elements
- Always resolve dynamic colors with `resolvedCGColor(...)` for dark mode consistency

### Helper Pattern

```swift
private func applyGlassCardStyle(_ layer: CALayer?, for view: NSView) {
    guard let layer = layer else { return }
    layer.masksToBounds = false
    layer.shadowColor = resolvedCGColor(NSColor.black.withAlphaComponent(0.07), for: view)
    layer.shadowOpacity = 1
    layer.shadowRadius = 8
    layer.shadowOffset = NSSize(width: 0, height: -1)
    layer.borderWidth = 0.5
    layer.borderColor = resolvedCGColor(NSColor.separatorColor.withAlphaComponent(0.16), for: view)
}
```

---

## Threading & Performance

### Thread Safety Rules

- **Event callbacks**: Run on background threads → dispatch UI updates to main
- **UI updates**: ALWAYS use `DispatchQueue.main.async`
- **Timers**: Run on RunLoop → ensure main thread for UI-affecting timers

### Performance Optimizations

- **Mouse sampling**: 30Hz (1/30 second) instead of every event
- **Debounced saves**: 500ms delay to batch rapid changes
- **Lazy UI updates**: Only refresh when popover is visible

---

## Localization

### String Localization Pattern

```swift
// In code
let title = NSLocalizedString("stats.title", comment: "")

// In Localizable.strings (English)
"stats.title" = "Statistics";

// In zh-Hans.strings (Chinese)
"stats.title" = "统计数据";
```

### Supported Languages

- English (default)
- 简体中文 (zh-Hans)

---

## Testing & Validation Checklist

### Before Committing Changes

- [ ] Build succeeds (⌘B in Xcode)
- [ ] App runs without crashes
- [ ] Accessibility permission prompt works
- [ ] Statistics update in real-time
- [ ] Menu bar display formats correctly
- [ ] Data persists across app restarts
- [ ] Daily reset works at midnight
- [ ] No force unwraps added (use `if let` or `guard`)
- [ ] No retain cycles (use `[weak self]` in closures)
- [ ] UI updates on main thread

### Manual Testing Steps

1. Grant accessibility permission
2. Type and click to verify counter increments
3. Check menu bar display updates
4. Open popover to verify detailed stats
5. Test reset button
6. Quit and relaunch to verify persistence
7. Wait past midnight to verify auto-reset

---

## Important Constants

```swift
// Mouse sampling rate
private let mouseSampleInterval: TimeInterval = 1.0 / 30.0  // 30Hz

// Debounce delay for stats updates
private let updateDebounceDelay: TimeInterval = 0.5  // 500ms

// Number formatting thresholds
let thousandThreshold = 1_000
let millionThreshold = 1_000_000

// UserDefaults keys
let statsKey = "currentStats"
let lastResetDateKey = "lastResetDate"
```

---

## Documentation References

### Apple Documentation

- [CGEvent Reference](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Accessibility API](https://developer.apple.com/documentation/applicationservices/axuielement)
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)

### Project Documentation

- [README.md](./README.md) - Chinese documentation
- [README_EN.md](./README_EN.md) - English documentation
- [QUICKSTART.md](./QUICKSTART.md) - Quick start guide

---

## Agent-Specific Guidance

### When Analyzing Code

1. Read files before making suggestions
2. Follow existing patterns (singleton, weak delegates, main thread UI)
3. Check for thread safety implications
4. Verify privacy compliance (no content logging)

### When Writing Code

1. Match existing code style and naming
2. Use `// MARK:` sections for organization
3. Add `weak` to delegate/closure references
4. Localize user-facing strings
5. Document public methods with `///`

### When Debugging

1. Check permission status first
2. Verify event tap is active
3. Confirm main thread for UI updates
4. Review debounce timers and sampling rates

### When Refactoring

1. Maintain backward compatibility with UserDefaults keys
2. Keep singleton patterns intact
3. Preserve thread safety
4. Update all UI references if changing data models
