#!/bin/bash
# Build LexiSelectionHelper.app — the entire product is this Swift app.
#
#   ./build.sh          compile + codesign
#   ./build.sh run      build, kill any running instance, launch
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=(
  $(find App Design UI Data Services Debug -name '*.swift' | sort)
  main.swift
)

APP="LexiSelectionHelper.app"
BIN="$APP/Contents/MacOS/LexiSelectionHelper"
APPEX="$APP/Contents/PlugIns/LexiFinderSync.appex"
IDENTITY="Apple Development: chengweipeng123@163.com (D8YJ3P5B53)"

mkdir -p "$APPEX/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/Resources"
# 品牌标记：主程序（菜单栏状态图标）与 appex（Finder 菜单项）共用一份。
cp artwork/lexi-logo-c-cards.svg "$APP/Contents/Resources/LexiLogo.svg"
# Dock 图标：栅格化 logo 全尺寸 -> iconutil 打包 icns（系统组件链）。
swift artwork/make-icon.swift "$PWD/AppIcon.iconset" \
  && iconutil -c icns "$PWD/AppIcon.iconset" \
       -o "$APP/Contents/Resources/AppIcon.icns" \
  && rm -rf "$PWD/AppIcon.iconset"

xcrun swiftc -O "${SOURCES[@]}" -o "$BIN" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework Foundation \
  -framework Network \
  -framework ServiceManagement \
  -lsqlite3

# Finder 右键菜单扩展：独立编译单元，装配为嵌套 .appex。
xcrun swiftc -O FinderSync/FinderSync.swift FinderSync/main.swift Data/FinderSyncConfig.swift \
  -module-name LexiFinderSync \
  -o "$APPEX/Contents/MacOS/LexiFinderSync" \
  -framework Cocoa \
  -framework FinderSync
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements FinderSync/appex.entitlements "$APPEX"

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
echo "built $APP"

if [[ "${1:-}" == "run" ]]; then
  pkill -f "LexiSelectionHelper.app/Contents/MacOS/LexiSelectionHelper" 2>/dev/null || true
  sleep 1
  open "$PWD/$APP"
  echo "launched"
fi
