#!/bin/bash
# regenerate-icons.sh
#
# Convert logo.svg to all required icon formats for the app.
# Place your logo.svg in the project root, then run:
#   bash scripts/regenerate-icons.sh
#
# Prerequisites:
#   brew install librsvg    (for rsvg-convert)
#   pip3 install Pillow     (for tray icon monochrome conversion)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SVG_FILE="$PROJECT_ROOT/logo.svg"
ICONS_DIR="$PROJECT_ROOT/src-tauri/icons"

# Check prerequisites
if ! command -v rsvg-convert &>/dev/null; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg"
    exit 1
fi

if ! python -c "from PIL import Image" 2>/dev/null; then
    echo "Error: Pillow not found. Install with: pip3 install Pillow"
    exit 1
fi

if [ ! -f "$SVG_FILE" ]; then
    echo "Error: logo.svg not found at project root."
    echo "Place your logo SVG file at: $PROJECT_ROOT/logo.svg"
    exit 1
fi

mkdir -p "$ICONS_DIR"

echo "Generating icons from logo.svg..."

# 1. App icon — 512x512, keep original colors
rsvg-convert -w 512 -h 512 "$SVG_FILE" -o "$ICONS_DIR/icon.png"
echo "  [OK] src-tauri/icons/icon.png  (512x512, full color)"

# 2. macOS tray icon — 32x32, monochrome black on transparent
#    macOS template mode uses this as a silhouette and auto-adapts to light/dark menu bar.
rsvg-convert -w 32 -h 32 "$SVG_FILE" -o "$ICONS_DIR/tray_icon_template.png"

python - "$ICONS_DIR/tray_icon_template.png" << 'PYEOF'
import sys
from PIL import Image

path = sys.argv[1]
img = Image.open(path).convert('RGBA')
pixels = img.load()

for y in range(img.height):
    for x in range(img.width):
        r, g, b, a = pixels[x, y]
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        # "Ink coverage" = opacity × darkness.
        # High ink → part of the design → opaque black.
        # Low ink  → background/gap → transparent.
        ink = (a / 255.0) * (1.0 - lum / 255.0)
        if ink > 0.25:
            pixels[x, y] = (0, 0, 0, 255)
        else:
            pixels[x, y] = (0, 0, 0, 0)

img.save(path)
PYEOF

echo "  [OK] src-tauri/icons/tray_icon_template.png  (32x32, monochrome template)"

echo ""
echo "Done! Rebuild the app to see the new icons."
echo "  cargo tauri dev     # for development"
echo "  cargo tauri build   # for production bundle"
