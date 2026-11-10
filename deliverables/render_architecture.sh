#!/usr/bin/env bash
# Rebuild architecture.svg and rasterise it with headless Chrome.
# Usage: bash deliverables/render_architecture.sh
set -euo pipefail
cd "$(dirname "$0")"
python3 build_architecture.py

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="${TMPDIR:-/tmp}/chrome-arch-profile"
mkdir -p "$PROFILE"

"$CHROME" --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --user-data-dir="$PROFILE" --force-device-scale-factor=2 \
  --screenshot=architecture.png --window-size=1920,1080 \
  "file://$PWD/architecture.html" 2>/dev/null

sips -Z 1920 architecture.png --out architecture-1920.png >/dev/null
echo "saved architecture.svg / architecture.png (3840x2160) / architecture-1920.png"
