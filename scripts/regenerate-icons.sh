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

# 2. macOS tray icon — supersample 256, LANCZOS downscale to 32, smooth alpha.
#    No hard threshold: binary alpha was causing visible jaggies in the menu bar.
#    macOS template mode tints the shape; only the alpha channel matters.
rsvg-convert -w 256 -h 256 "$SVG_FILE" -o "$ICONS_DIR/.tray_256.png"

python - "$ICONS_DIR/.tray_256.png" "$ICONS_DIR/tray_icon_template.png" << 'PYEOF'
import sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert('RGBA').resize((32, 32), Image.LANCZOS)

# ink coverage = opacity x darkness, then normalized so the darkest ink hits full alpha
# (LANCZOS on non-premultiplied RGBA bleeds edge RGB toward black, so min-luminance
# normalization is unreliable; normalize by max coverage instead.)
cov = [
    (a / 255.0) * (1 - (0.299 * r + 0.587 * g + 0.114 * b) / 255.0)
    for r, g, b, a in img.get_flattened_data()
]
peak = max(cov)
out = Image.new('RGBA', (32, 32))
out.putdata([
    (0, 0, 0, max(0, min(255, round(c / peak * 255))))
    for c in cov
])
out.save(dst)
PYEOF
rm -f "$ICONS_DIR/.tray_256.png"

echo "  [OK] src-tauri/icons/tray_icon_template.png  (32x32, monochrome template)"

echo ""
echo "Done! Rebuild the app to see the new icons."
echo "  cargo tauri dev     # for development"
echo "  cargo tauri build   # for production bundle"
