#!/bin/bash
# Release pipeline (goty release.sh pattern, minus Sparkle — Lexi has no
# auto-update yet): build → DMG → push → GitHub release.
#
# Signing is automatic by what the keychain holds:
#   • "Developer ID Application" present → deep re-sign the app with that
#     identity + hardened runtime, notarize the DMG (xcrun notarytool,
#     stored profile "$NOTARY_PROFILE", default lexi-notary) and staple it.
#   • otherwise → ad-hoc (today's mode): the DMG ships unsigned; first
#     open is right-click → Open.
#
# The git remote for releases is GitHub (seascheng/lexi) — `origin` may
# point elsewhere (e.g. an internal GitLab), so a `github` remote is
# added on demand and never overwritten.
#
# Usage: Lexi/release.sh ["release notes, one bullet per line"]
set -euo pipefail
cd "$(dirname "$0")"

APP_BUNDLE="LexiSelectionHelper.app"
GITHUB_REPO="seascheng/lexi"
NOTARY_PROFILE="${NOTARY_PROFILE:-lexi-notary}"

echo "==> build"
./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_BUNDLE/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_BUNDLE/Contents/Info.plist")
DMG_NAME="Lexi-$VERSION-arm64.dmg"
TAG="v$VERSION"
echo "==> releasing $TAG (build $BUILD)"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application/ {print $2; exit}' || true)
if [ -n "$IDENTITY" ]; then
    echo "==> Developer ID re-sign ($IDENTITY)"
    APP_ENTS="$(mktemp).entitlements"
    codesign display --entitlements - "$APP_BUNDLE" > "$APP_ENTS" 2>/dev/null || true
    codesign --force --deep --sign "$IDENTITY" --options runtime \
        --entitlements "$APP_ENTS" "$APP_BUNDLE"
    rm -f "$APP_ENTS"
fi

echo "==> DMG"
mkdir -p dist
rm -rf dist/stage && mkdir dist/stage
cp -R "$APP_BUNDLE" dist/stage/
rm -f "dist/$DMG_NAME"

# create-dmg drives Finder through AppleScript and flakes now and then;
# a flaked run exits 2 AND leaves its interstitial rw.* image mounted,
# which then breaks the next attempt too. Detach any leftover first and
# retry once (goty 2026-08-28 lesson).
cleanup_interstitial() {
    hdiutil info | awk '/^image-path.*rw\./ {print}' >/dev/null
    for vol in $(hdiutil info | awk '/^image-path/ {print $3}' | grep 'rw\.'); do
        hdiutil detach "$vol" -force >/dev/null 2>&1 || true
    done
}

cleanup_interstitial
if ! create-dmg \
    --volname "Lexi" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 160 \
    --icon "$APP_BUNDLE" 180 170 \
    --app-drop-link 480 170 \
    --hide-extension "$APP_BUNDLE" \
    "dist/$DMG_NAME" \
    "dist/stage/$APP_BUNDLE" >/dev/null 2>&1; then
    echo "create-dmg flaked, retrying after cleanup"
    cleanup_interstitial
    create-dmg \
        --volname "Lexi" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 160 \
        --icon "$APP_BUNDLE" 180 170 \
        --app-drop-link 480 170 \
        --hide-extension "$APP_BUNDLE" \
        "dist/$DMG_NAME" \
        "dist/stage/$APP_BUNDLE" >/dev/null
fi

if [ -n "$IDENTITY" ]; then
    echo "==> notarize + staple"
    xcrun notarytool submit "dist/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "dist/$DMG_NAME"
fi

echo "==> git"
git push origin main
if git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag -f "$TAG" >/dev/null
fi
git push -f origin "$TAG"

echo "==> GitHub release"
NOTES="${1:-Lexi $VERSION.}"
gh release create "$TAG" "dist/$DMG_NAME" \
    --repo "$GITHUB_REPO" \
    --title "Lexi $VERSION" \
    --notes "$NOTES

macOS 13+ · Apple Silicon (arm64). Ad-hoc signed: on first open,
right-click the app → Open (once), or remove the quarantine flag:
\`\`\`
xattr -dr com.apple.quarantine /Applications/LexiSelectionHelper.app
\`\`\`"

echo "==> done: dist/$DMG_NAME"
