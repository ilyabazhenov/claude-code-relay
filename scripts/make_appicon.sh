#!/usr/bin/env bash
#
# Generate the Relay .app icon (Resources/AppIcon.icns) from scratch.
#
# Usage:
#   scripts/make_appicon.sh
#
# Renders every icon size vectorially (scripts/render_icon.swift) and packs them into
# an .icns with `iconutil`. Re-run whenever the mark changes. build_app.sh copies the
# resulting .icns into the bundle if it exists.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering icon sizes"
swift "$ROOT/scripts/render_icon.swift" "$ICONSET"

echo "==> packing AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> done: Resources/AppIcon.icns"
