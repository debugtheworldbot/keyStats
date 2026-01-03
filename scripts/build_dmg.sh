#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/KeyStats.xcodeproj"
SCHEME="KeyStats"
CONFIGURATION="Release"
APP_NAME="KeyStats"
APP_LINK_NAME="$(osascript -e 'tell application "Finder" to get name of (path to applications folder)' 2>/dev/null || true)"
APP_LINK_NAME="$(printf '%s' "$APP_LINK_NAME" | tr -d '\r\n')"
if [[ -z "$APP_LINK_NAME" ]]; then
  APP_LINK_NAME="Applications"
fi
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg-staging"
MOUNT_DIR="$BUILD_DIR/dmg-mount"
TMP_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
BACKGROUND_IMAGE="$STAGING_DIR/background.png"
DMG_PATH="$ROOT_DIR/$APP_NAME.dmg"

cleanup_mount() {
  if mount | grep -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup_mount EXIT

echo "Building $APP_NAME..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found at $APP_PATH" >&2
  exit 1
fi

cleanup_mount
rm -rf "$STAGING_DIR"
rm -rf "$MOUNT_DIR"
rm -f "$TMP_DMG"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"

BACKGROUND_IMAGE="$BACKGROUND_IMAGE" /usr/bin/swift - <<'EOF'
import AppKit
import Foundation

let outputPath = ProcessInfo.processInfo.environment["BACKGROUND_IMAGE"] ?? ""
if outputPath.isEmpty {
    exit(1)
}

let width: CGFloat = 720
let height: CGFloat = 260
let size = NSSize(width: width, height: height)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.set()
NSRect(origin: .zero, size: size).fill()

let strokeColor = NSColor(calibratedWhite: 0.1, alpha: 0.9)
strokeColor.set()

let line = NSBezierPath()
line.lineWidth = 8
line.lineCapStyle = .round
line.lineJoinStyle = .round
line.move(to: NSPoint(x: 230, y: 130))
line.line(to: NSPoint(x: 460, y: 130))
line.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 460, y: 130))
head.line(to: NSPoint(x: 430, y: 152))
head.line(to: NSPoint(x: 430, y: 108))
head.close()
head.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}

try data.write(to: URL(fileURLWithPath: outputPath))
EOF

echo "Creating DMG..."
ln -s /Applications "$STAGING_DIR/$APP_LINK_NAME"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW "$TMP_DMG"
mkdir -p "$MOUNT_DIR"
hdiutil attach "$TMP_DMG" -nobrowse -readwrite -mountpoint "$MOUNT_DIR"

BACKGROUND_PATH="$MOUNT_DIR/background.png" MOUNT_DIR="$MOUNT_DIR" osascript <<EOF
set backgroundAlias to POSIX file "$BACKGROUND_PATH" as alias
set mountAlias to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
    set dmgDisk to disk of mountAlias
    tell dmgDisk
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 820, 360}
        set iconViewOptions to the icon view options of container window
        set arrangement of iconViewOptions to not arranged
        set icon size of iconViewOptions to 96
        set background picture of iconViewOptions to backgroundAlias
        delay 0.5
        try
            set position of item "$APP_NAME.app" of container window to {170, 170}
        end try
        try
            set position of item "$APP_LINK_NAME" of container window to {520, 170}
        on error
            try
                set position of item "Applications" of container window to {380, 170}
            end try
        end try
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

chflags hidden "$MOUNT_DIR/background.png"

hdiutil detach "$MOUNT_DIR"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH"
rm -f "$TMP_DMG"

echo "DMG created at $DMG_PATH"
