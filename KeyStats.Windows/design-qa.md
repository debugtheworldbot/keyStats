# Floating Stats Design QA

- Source feedback capture: `C:\Users\t\AppData\Local\Temp\codex-clipboard-67a8ee63-df85-4c65-ab56-4e22ddc7dab7.png`
- Single-row implementation: `C:\Users\t\.codex\visualizations\2026\08\23\01a02c9c-fa5e-7dc3-af63-d32cab43e2a6\floating-stats-single-row-tight.png`
- Double-row implementation: `C:\Users\t\.codex\visualizations\2026\08\23\01a02c9c-fa5e-7dc3-af63-d32cab43e2a6\floating-stats-double-row.png`
- Combined comparison: `C:\Users\t\.codex\visualizations\2026\08\23\01a02c9c-fa5e-7dc3-af63-d32cab43e2a6\floating-stats-layout-comparison.png`
- Viewports: single row 104 × 36 DIPs; double row 72 × 52 DIPs; both rendered at 96 DPI / 1× density
- Pixel dimensions: feedback capture 365 × 103; single-row implementation 104 × 36; double-row implementation 72 × 52; comparison canvas 790 × 150
- State: Windows light theme, values 225 and 252
- Normalization: the implementation captures are rendered at 1× and enlarged to 2× in the combined comparison to approximate the high-DPI scale of the supplied feedback screenshot.

## Full-view comparison evidence

The revised single-row surface materially reduces the wide outer and inter-value whitespace visible in the supplied screenshot while preserving two clearly separated values. The new double-row option uses a narrower vertical card with a horizontal divider and equal row heights. Both layouts retain the same typography, border, radius, material, and interaction affordances.

## Required fidelity surfaces

- Fonts and typography: both layouts retain the taskbar-aligned Segoe UI 11 px semibold values with display-mode formatting and ClearType rendering.
- Spacing and layout rhythm: single row is reduced from 136 × 36 to 104 × 36, with 4 px horizontal padding and a 7 px divider gutter. Double row is 72 × 52 with 4 px horizontal padding, 3 px vertical padding, and a centered 42 px divider.
- Colors and visual tokens: both layouts continue using the KeyStats dynamic primary text, divider, translucent backdrop tint, and popup border resources.
- Image quality and asset fidelity: neither layout contains raster imagery, icons, or decorative assets.
- Copy and content: only the two selected statistic values are visible; labels and exact expanded values remain available through settings and tooltips.

## Focused-region comparison evidence

No separate focused crop was needed because the values, separators, border, padding, and alignment are all legible in the combined comparison at the supplied high-DPI presentation scale.

## Findings

- No actionable P0, P1, or P2 differences.
- Accepted intentional difference: the double-row layout is narrower and taller than the supplied single-row capture because it prioritizes vertical stacking.
- P3: very long formatted distance values may truncate in the compact card; the full value remains available in the tooltip.

## Comparison history

- Earlier state: 136 × 36 single-row surface with excess horizontal whitespace at the user's display scale.
- Revision: reduced single-row width to 104 DIPs and added a 72 × 52 double-row layout selectable from Settings.
- Post-fix evidence: both exact production-XAML renders show centered values with no overlap or clipping for representative counts.

## Implementation checklist

- Single-row and double-row production XAML rendered and inspected.
- Layout selection persists through the additive settings model and applies immediately.
- Window size changes re-clamp the saved position to the visible work area.
- Debug build completed with 0 warnings and 0 errors.
- English, Simplified Chinese, and Traditional Chinese resources remain in parity.

final result: passed
