# Floating Stats Design QA

## Production geometry

- Layout scale baseline: WPF `FontSize="11"`.
- Single-row baseline: 72 × 28 DIPs; at the `FontSize="12"` default it renders at 79 × 31 DIPs.
- Double-row baseline: 32 × 38 DIPs; at the `FontSize="12"` default it renders at 35 × 41 DIPs.
- The production XAML starts in the default double-row, `FontSize="12"`, 35 × 41 DIP state.
- Other font sizes scale both window dimensions by `fontSize / 11` and round away from zero.

## Static inspection

- Both layouts use equal star-sized value regions with a dedicated separator region.
- Values are centered, use character ellipsis when space is exhausted, and expose the full value in a tooltip.
- Layout or font-size changes immediately re-clamp the window to the active monitor work area.
- Monitor work areas are converted from device pixels with each monitor's own scale factor.
- English, Simplified Chinese, and Traditional Chinese resources contain the same floating-stat keys.

## Manual verification matrix

The following checks remain required on Windows before release:

- Render single-row and double-row layouts at 100%, 125%, and 150% display scaling.
- Move the window between monitors with different scale factors and confirm that restore and edge clamping stay on the saved monitor.
- Verify the translucent surface and text contrast in light and dark themes.
- Exercise minimum and maximum font sizes with long distance values and confirm tooltip access.
- Open Settings on a low-height display and confirm all controls remain reachable through vertical scrolling.
