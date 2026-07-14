#!/usr/bin/env bash
#
# Double-click this from the mounted Relay disk image to install Relay.
#
# Relay is ad-hoc signed (not notarized), so macOS quarantines it on download and
# refuses to open it ("Relay is damaged"). This script copies Relay into
# /Applications and strips the quarantine flag so it launches normally. Nothing here
# needs admin rights or touches anything but Relay.app.

set -euo pipefail

# The .command runs from wherever it sits — the mounted dmg volume next to Relay.app.
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/Relay.app"
DEST="/Applications/Relay.app"

if [[ ! -d "$SRC" ]]; then
  echo "Relay.app not found next to this installer ($SRC)." >&2
  echo "Run Install.command from the mounted Relay disk image." >&2
  exit 1
fi

echo "==> Installing Relay to /Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Removing the quarantine flag"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> Launching Relay (look for the menu-bar icon, no Dock icon)"
open "$DEST"

echo
echo "Done. Next: open Relay's menu → Install hooks, then run Claude Code via ./cc."
echo "You can close this window."
