#!/usr/bin/env bash
#
# Build a release Relay.app and package it into build/Relay.dmg with a drag-to-
# Applications layout.
#
# Signing / notarization (optional, for distribution) — see README. To sign with a
# Developer ID before packaging:
#   CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/make_dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="build/Relay.app"
DMG="build/Relay.dmg"
STAGING="build/dmg-staging"

./scripts/build_app.sh release

# Optional Developer ID signing (overrides the ad-hoc signature from build_app.sh).
if [[ -n "${CODESIGN_ID:-}" ]]; then
  echo "==> signing with: $CODESIGN_ID"
  codesign --force --deep --options runtime --sign "$CODESIGN_ID" "$APP"
fi

echo "==> staging dmg contents"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# Installer for machines without notarization: strips quarantine + copies to
# /Applications so Gatekeeper doesn't block the ad-hoc-signed app.
cp "$ROOT/scripts/Install.command" "$STAGING/Install.command"
chmod +x "$STAGING/Install.command"

echo "==> creating $DMG"
hdiutil create \
  -volname "Relay" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> done: $DMG"
echo
echo "Distribution note: unsigned/ad-hoc apps are blocked by Gatekeeper on other"
echo "machines. To distribute, sign with a Developer ID and notarize (see README)."
