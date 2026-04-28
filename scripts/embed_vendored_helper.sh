#!/bin/bash
# Replace the embedded KeyStatsHelper.app inside a built KeyStats.app
# with the pre-vendored, pre-signed bundle from vendor/.
#
# Run AFTER xcodebuild produces KeyStats.app (with helper embedded by
# Xcode's Embed Helper phase) and BEFORE sign_app.sh re-signs the outer
# app. The vendored bundle is the source of truth for helper cdhash;
# sign_app.sh's re-sign of the helper with the same
# KeyStatsHelper.entitlements is deterministic (verified) and preserves
# cdhash.
#
# Usage: ./scripts/embed_vendored_helper.sh <path-to-KeyStats.app>

set -e

APP_PATH="$1"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Usage: $0 <path-to-KeyStats.app>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_HELPER="$PROJECT_DIR/vendor/KeyStatsHelper.app"
EMBEDDED_HELPER="$APP_PATH/Contents/Resources/KeyStatsHelper.app"

# Verify vendor is intact first (sources didn't change without re-vendoring)
"$SCRIPT_DIR/check_vendored_helper.sh"

if [ ! -d "$EMBEDDED_HELPER" ]; then
    echo "❌ No embedded helper at $EMBEDDED_HELPER (xcodebuild didn't run Embed Helper phase?)"
    exit 1
fi

echo "📦 Replacing embedded helper with vendored copy..."
rm -rf "$EMBEDDED_HELPER"
ditto "$VENDOR_HELPER" "$EMBEDDED_HELPER"
echo "✅ Embedded vendored helper (cdhash $(tr -d '[:space:]' < "$PROJECT_DIR/vendor/KeyStatsHelper.cdhash.txt"))"
