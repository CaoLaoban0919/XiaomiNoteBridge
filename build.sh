#!/bin/bash
# 米记桥 构建脚本
# 本机没有 Xcode，只用 Command Line Tools 的 swiftc 手工组装 .app，再用 hdiutil 打 dmg。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="MiNoteBridge"
DISPLAY_NAME="米记桥"
BUNDLE_ID="local.minotebridge.app"
VERSION="1.0"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"

ACTION="${1:-app}"   # app | dmg | run

# SwiftUI 的 @State / @StateObject 等是宏，需要 SwiftUIMacros 插件。
# Command Line Tools 自带的工具链里没有这个插件，只有 Xcode 里有。
# 所以这里自动切到 Xcode 工具链——不需要 sudo，也不会改动全局的 xcode-select。
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  echo "==> 使用 Xcode 工具链（宏插件来源）"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$PROJECT_DIR/Sources" -name '*.swift' | sort)
echo "    共 ${#SOURCES[@]} 个源文件"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -disable-sandbox \
  -framework Carbon \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "${SOURCES[@]}"

echo "==> 组装 .app"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/首次使用许可.md" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/Resources/权限清单.md" "$APP/Contents/Resources/"

echo "==> 生成图标"
if [ -f "$PROJECT_DIR/Tools/make_icon.swift" ] && [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  swift "$PROJECT_DIR/Tools/make_icon.swift" "$BUILD_DIR/icon.png" >/dev/null 2>&1 || true
  if [ -f "$BUILD_DIR/icon.png" ]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
      sips -z $s $s "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
      d=$((s*2))
      sips -z $d $d "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
  fi
fi

# Info.plist 里引用图标（存在才写，避免 CFBundleIconFile 指向不存在的文件）
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /'

echo "==> 校验"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$APP/Contents/Info.plist" >/dev/null \
  && echo "    NSAppleEventsUsageDescription 已就位" \
  || { echo "    !! 缺少 NSAppleEventsUsageDescription，授权弹窗会没有说明文字"; exit 1; }

if [ "$ACTION" = "dmg" ]; then
  echo "==> 打包 dmg"
  STAGE="$BUILD_DIR/dmg-stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -sf /Applications "$STAGE/Applications"
  DMG="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
  rm -f "$DMG"
  hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  echo "    产物：$DMG"
fi

if [ "$ACTION" = "run" ] || [ "$ACTION" = "app" ]; then
  echo "==> 启动"
  open "$APP"
fi

echo "完成：$APP"
