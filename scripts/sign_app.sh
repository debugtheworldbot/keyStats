#!/bin/bash
# Inner-first ad-hoc 签名 KeyStats.app 及其内嵌 KeyStatsHelper.app。
#
# 先签 helper（用 helper 自己的 entitlements），再签外层主 app 且不带 --deep。
# 这样 helper 的 cdhash 只取决于自身字节，跨版本升级若 helper 未变 ⇒ cdhash 稳定
# ⇒ TCC 辅助功能授权保留 ⇒ 用户升级后无需重新授权。
#
# 用法: ./scripts/sign_app.sh <path-to-KeyStats.app>

set -e

APP_PATH="$1"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ 用法: $0 <path-to-KeyStats.app>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_ENTITLEMENTS="$PROJECT_DIR/KeyStats/KeyStats.entitlements"
HELPER_ENTITLEMENTS="$PROJECT_DIR/KeyStatsHelper/KeyStatsHelper.entitlements"
HELPER_APP_PATH="$APP_PATH/Contents/Resources/KeyStatsHelper.app"

if [ ! -d "$HELPER_APP_PATH" ]; then
    echo "❌ 未找到内嵌 KeyStatsHelper.app: $HELPER_APP_PATH" >&2
    exit 1
fi

# 1) 最内层先签：helper 自己的 entitlements
if [ -f "$HELPER_ENTITLEMENTS" ]; then
    codesign --force --sign - --entitlements "$HELPER_ENTITLEMENTS" "$HELPER_APP_PATH"
else
    codesign --force --sign - "$HELPER_APP_PATH"
fi

# 2) 外层主 app：不要 --deep，让 helper 已有签名作为 nested bundle 被原样参照
if [ -f "$APP_ENTITLEMENTS" ]; then
    codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
else
    codesign --force --sign - "$APP_PATH"
fi

HELPER_CDHASH=$(codesign -d -vvv "$HELPER_APP_PATH" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}')
echo "🔑 KeyStatsHelper CDHash: ${HELPER_CDHASH:-<unknown>}"
