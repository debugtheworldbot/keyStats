#!/bin/bash

set -euo pipefail

APP_NAME="KeyStats"
SCHEME="KeyStats"
PROJECT="KeyStats.xcodeproj"
CONFIGURATION="Release"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

usage() {
    echo "Usage: $0 <tag> [output-dir]"
    echo ""
    echo "Example:"
    echo "  $0 v1.0.0 build/release/v1.0.0"
    echo ""
    echo "Environment:"
    echo "  SPARKLE_BIN=/path/to/Sparkle/bin"
    echo "  SPARKLE_PRIVATE_KEY=base64_key"
    echo "  SPARKLE_PRIVATE_KEY_FILE=/path/to/keyfile"
}

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    usage
    exit 1
fi

OUTPUT_DIR="${2:-$BUILD_DIR/release/$TAG}"
SPARKLE_BIN="${SPARKLE_BIN:-/tmp/SparkleSwiftPM/bin}"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
PBXPROJ="$PROJECT_DIR/KeyStats.xcodeproj/project.pbxproj"
VERSION="${TAG#v}"

if [[ -z "$VERSION" ]]; then
    echo "Error: tag must include a version, e.g. v0.1 or v1.0.0"
    exit 1
fi

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "Error: generate_appcast not found at $GENERATE_APPCAST"
    echo "Download Sparkle tools or set SPARKLE_BIN."
    exit 1
fi

current_build=$(perl -ne 'if (/CURRENT_PROJECT_VERSION = ([0-9]+);/) { print $1; exit }' "$PBXPROJ")
if [[ -z "${current_build:-}" ]]; then
    echo "Error: unable to read CURRENT_PROJECT_VERSION from $PBXPROJ"
    exit 1
fi

new_build=$((current_build + 1))
perl -0pi -e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${new_build};/g; s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
echo "Set MARKETING_VERSION=$VERSION, CURRENT_PROJECT_VERSION=$new_build"

echo "Building $APP_NAME ($CONFIGURATION)..."
rm -rf "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

if command -v xcpretty >/dev/null 2>&1; then
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        CODE_SIGN_IDENTITY="-" | xcpretty
else
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        -archivePath "$ARCHIVE_PATH" \
        archive \
        CODE_SIGN_IDENTITY="-"
fi

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: built app not found at $APP_PATH"
    exit 1
fi

STAGING_DIR="$BUILD_DIR/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

ENTITLEMENTS="$PROJECT_DIR/KeyStats/KeyStats.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$STAGING_DIR/$APP_NAME.app"
else
    codesign --force --deep --sign - "$STAGING_DIR/$APP_NAME.app"
fi

INFO_PLIST="$STAGING_DIR/$APP_NAME.app/Contents/Info.plist"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")

ZIP_NAME="${APP_NAME}.zip"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"

echo "Creating update archive: $ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/$APP_NAME.app" "$ZIP_PATH"

DOWNLOAD_PREFIX="https://github.com/debugtheworldbot/keyStats/releases/download/$TAG"
APPCAST_PATH="$OUTPUT_DIR/appcast.xml"

echo "Generating appcast..."
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" \
        --ed-key-file - \
        --download-url-prefix "$DOWNLOAD_PREFIX/" \
        -o "$APPCAST_PATH" \
        "$OUTPUT_DIR"
elif [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    "$GENERATE_APPCAST" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
        --download-url-prefix "$DOWNLOAD_PREFIX/" \
        -o "$APPCAST_PATH" \
        "$OUTPUT_DIR"
else
    "$GENERATE_APPCAST" \
        --download-url-prefix "$DOWNLOAD_PREFIX/" \
        -o "$APPCAST_PATH" \
        "$OUTPUT_DIR"
fi

echo ""
echo "Release artifacts ready:"
echo "  $ZIP_PATH"
echo "  $APPCAST_PATH"
echo ""
echo "Upload both files to the GitHub release: $TAG"
