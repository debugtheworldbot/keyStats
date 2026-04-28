#!/bin/bash
# Verify vendor/KeyStatsHelper.app's actual cdhash matches the value
# recorded in vendor/KeyStatsHelper.cdhash.txt.
#
# Run from CI and from local build_dmg.sh to detect a stale or
# corrupted vendored helper before any further build work.
#
# Exit 0 on match, 1 on mismatch / missing files.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_APP="$PROJECT_DIR/vendor/KeyStatsHelper.app"
EXPECTED_FILE="$PROJECT_DIR/vendor/KeyStatsHelper.cdhash.txt"

if [ ! -d "$VENDOR_APP" ]; then
    echo "❌ Missing vendored helper bundle: $VENDOR_APP"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

if [ ! -f "$EXPECTED_FILE" ]; then
    echo "❌ Missing expected cdhash file: $EXPECTED_FILE"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

EXPECTED=$(tr -d '[:space:]' < "$EXPECTED_FILE")
ACTUAL=$(codesign -d -vvv "$VENDOR_APP" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}' | tr -d '[:space:]')

if [ -z "$ACTUAL" ]; then
    echo "❌ Failed to extract cdhash from $VENDOR_APP (codesign -d failed?)"
    exit 1
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "❌ Vendored helper cdhash mismatch."
    echo "   Expected (vendor/KeyStatsHelper.cdhash.txt): $EXPECTED"
    echo "   Actual   (vendor/KeyStatsHelper.app):        $ACTUAL"
    echo ""
    echo "   The vendored bundle was modified without updating cdhash.txt,"
    echo "   or the helper sources changed without re-vendoring. Run:"
    echo "     ./scripts/rebuild_vendored_helper.sh"
    echo "   then commit both vendor/KeyStatsHelper.app and vendor/KeyStatsHelper.cdhash.txt."
    exit 1
fi

echo "✅ Vendored helper cdhash OK: $ACTUAL"
