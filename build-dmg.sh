#!/bin/bash
set -euo pipefail

APP_NAME="Lexi"
APP_PATH="src-tauri/target/release/bundle/macos/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
STAGING="/tmp/${APP_NAME}-dmg"

# Check app exists
if [ ! -d "$APP_PATH" ]; then
  echo "Error: ${APP_PATH} not found. Run build.sh first."
  exit 1
fi

# Clean previous staging
rm -rf "$STAGING" "$DMG_NAME"
mkdir -p "$STAGING"

# Copy app and Applications symlink
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME" -srcdir "$STAGING" -ov "$DMG_NAME"

# Cleanup
rm -rf "$STAGING"

echo "Done: ${DMG_NAME}"
