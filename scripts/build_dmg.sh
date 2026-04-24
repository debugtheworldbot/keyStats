#!/bin/bash

# KeyStats DMG 打包脚本

set -e

# 配置
APP_NAME="KeyStats"
SCHEME="KeyStats"
PROJECT="KeyStats.xcodeproj"
CONFIGURATION="Release"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"

# 获取脚本所在目录的上级目录（项目根目录）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "📦 开始打包 $APP_NAME..."

# 清理旧的构建
echo "🧹 清理旧的构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$DMG_DIR" "$OUTPUT_DIR"

# 构建 Release 版本
echo "🔨 构建 Release 版本..."
xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    | xcpretty || xcodebuild -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO

# 导出 .app
echo "📤 导出应用..."
APP_PATH="$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ 构建失败：找不到 $APP_PATH"
    exit 1
fi

# 复制到 DMG 目录
cp -R "$APP_PATH" "$DMG_DIR/"

# 核对 helper 产物已嵌入（Embed Helper build phase 生效）
HELPER_BIN="$DMG_DIR/$APP_NAME.app/Contents/Resources/KeyStatsHelper.app/Contents/MacOS/KeyStatsHelper"
if [ ! -f "$HELPER_BIN" ]; then
    echo "❌ 未找到嵌入的 KeyStatsHelper：$HELPER_BIN"
    echo "   检查 KeyStats target 的 'Embed Helper' build phase 是否包含 KeyStatsHelper.app。"
    exit 1
fi
echo "✅ Helper 已嵌入: $HELPER_BIN"

# Ad-hoc 签名（重要：确保辅助功能权限正常工作）
#
# Helper 必须单独先签，外层 app 再签且不带 --deep。这样 helper 的 cdhash 只取决于
# 它自己的字节内容；外层主 app 重签不会污染 helper，Sparkle 升级时若 helper 源码
# 和资源没变，cdhash 保持稳定 ⇒ HelperSupervisor 跳过替换 ⇒ TCC 辅助功能授权保留。
# `--deep` 会把外层 entitlements 递归盖到 helper 上，并且每次都重算 helper 签名。
echo "🔏 签名应用..."
ENTITLEMENTS="$PROJECT_DIR/KeyStats/KeyStats.entitlements"
HELPER_APP_PATH="$DMG_DIR/$APP_NAME.app/Contents/Resources/KeyStatsHelper.app"
HELPER_ENTITLEMENTS="$PROJECT_DIR/KeyStatsHelper/KeyStatsHelper.entitlements"

# 1) Helper 内部如果还有嵌套的 signable bundle（当前没有）应从最内层开始签；
#    现在只需要签 helper.app 自身。
if [ -f "$HELPER_ENTITLEMENTS" ]; then
    codesign --force --sign - --entitlements "$HELPER_ENTITLEMENTS" "$HELPER_APP_PATH"
else
    codesign --force --sign - "$HELPER_APP_PATH"
fi

# 2) 外层主 app：不要 --deep，这样 helper 已经存在的签名原样作为 nested bundle
#    被参照进来，不会被重签。
if [ -f "$ENTITLEMENTS" ]; then
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$DMG_DIR/$APP_NAME.app"
else
    codesign --force --sign - "$DMG_DIR/$APP_NAME.app"
fi

# 打印 helper 的 cdhash，方便跨版本对照：只要两次打包结果相同，用户升级后不会被要求重新授权。
HELPER_CDHASH=$(codesign -d -vvv "$HELPER_APP_PATH" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}')
echo "🔑 KeyStatsHelper CDHash: ${HELPER_CDHASH:-<unknown>}"

# 创建 Applications 文件夹的符号链接
ln -s /Applications "$DMG_DIR/Applications"

DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

# 创建 DMG
echo "💿 创建 DMG..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# 清理临时文件
echo "🧹 清理临时文件..."
rm -rf "$DMG_DIR"
rm -rf "$BUILD_DIR/DerivedData"
rm -rf "$BUILD_DIR/$APP_NAME.xcarchive"

# 完成
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "✅ 打包完成！"
echo "📍 位置: $DMG_PATH"
echo "📊 大小: $DMG_SIZE"
