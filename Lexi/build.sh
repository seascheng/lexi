#!/bin/bash
# Build LexiSelectionHelper.app — the entire product is this Swift app.
#
#   ./build.sh          compile + codesign
#   ./build.sh run      build, kill any running instance, launch
set -euo pipefail
cd "$(dirname "$0")"

SOURCES=(
  SelectionToolbarHelper.swift
  LauncherPanel.swift
  PanelDesign.swift
  ClipboardStore.swift
  ClipboardMonitor.swift
  ClipboardPanel.swift
  LexiStore.swift
  SettingsWindow.swift
  SettingsPanes.swift
  AIService.swift
  SM2.swift
  StudyPanes.swift
  ContentPanes.swift
  MarkdownText.swift
  SurfacePanes.swift
  PanelCoordinator.swift
  ShortcutMonitor.swift
  SelectionPipeline.swift
  main.swift
)

APP="LexiSelectionHelper.app"
BIN="$APP/Contents/MacOS/LexiSelectionHelper"
IDENTITY="Apple Development: chengweipeng123@163.com (D8YJ3P5B53)"

xcrun swiftc -O "${SOURCES[@]}" -o "$BIN" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework Foundation \
  -framework Network \
  -framework ServiceManagement \
  -lsqlite3

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
echo "built $APP"

if [[ "${1:-}" == "run" ]]; then
  pkill -f "LexiSelectionHelper.app/Contents/MacOS/LexiSelectionHelper" 2>/dev/null || true
  sleep 1
  open "$PWD/$APP"
  echo "launched"
fi
