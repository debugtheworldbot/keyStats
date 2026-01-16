# Icons

This folder should contain the following icon files:

## Required Icons

1. **app.ico** - The main application icon (multi-resolution ICO file)
   - 16x16, 32x32, 48x48, 256x256 resolutions
   - Used for the taskbar, window title, and system tray

## Generating Icons

You can use the macOS KeyStats app icon as a source and convert it using tools like:
- ImageMagick: `convert AppIcon.png -resize 256x256 app.ico`
- Online tools: icoconvert.com or similar

## Dynamic Icon Generation

The tray icon is generated dynamically at runtime by `IconGenerator.cs` in the Helpers folder.
This allows the icon color to change based on typing speed (APM).
