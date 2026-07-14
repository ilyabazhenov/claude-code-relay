#!/usr/bin/env bash
#
# Cut a Sparkle update: build the release .app, zip it, EdDSA-sign it, and (re)generate
# appcast.xml. Does NOT publish anything — it prints the exact commands to upload the
# artifacts and commit the appcast, so publishing stays a deliberate step.
#
# Usage:
#   scripts/release.sh
#
# Prerequisites (one-time):
#   - An EdDSA key pair in your login keychain. Check with:
#       .build/artifacts/sparkle/Sparkle/bin/generate_keys -p
#     If it prints a key, you're set (its public half must match SUPublicEDKey in
#     Resources/Info.plist). If not, run generate_keys once and paste the printed public
#     key into Resources/Info.plist.
#
# Release flow:
#   1. Bump the version in ./VERSION and commit (CFBundleVersion is the commit count, so
#      committing is what advances the build number Sparkle compares by).
#   2. Run this script.
#   3. Follow the printed "Next steps" to create the GitHub release + commit appcast.xml.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO_SLUG="ilyabazhenov/claude-code-relay"
APP="build/Relay.app"
STAGE="build/sparkle-updates"          # generate_appcast scans this dir of archives
APPCAST="$ROOT/appcast.xml"            # committed at repo root == SUFeedURL target

SHORT_VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
ZIP_NAME="Relay-$SHORT_VERSION.zip"          # Sparkle enclosure (in $STAGE)
DMG_NAME="Relay-$SHORT_VERSION.dmg"          # human first-install download (in build/)
DMG_PATH="$ROOT/build/$DMG_NAME"
TAG="v$SHORT_VERSION"
DOWNLOAD_PREFIX="https://github.com/$REPO_SLUG/releases/download/$TAG/"

# Locate Sparkle's CLI tools (resolved by SwiftPM under .build/artifacts).
TOOLS="$(find "$ROOT/.build/artifacts" -type d -path '*Sparkle/bin' 2>/dev/null | head -1)"
if [[ -z "$TOOLS" || ! -x "$TOOLS/generate_appcast" ]]; then
  echo "error: Sparkle tools not found — run 'swift build' first." >&2
  exit 1
fi

# 1) Build + sign the release bundle (embeds Sparkle, stamps version).
./scripts/build_app.sh release

# 2) Zip it with ditto so symlinks + the code signature survive the archive.
echo "==> packaging $ZIP_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/$ZIP_NAME"

# 3) Generate + EdDSA-sign the appcast. --download-url-prefix makes the enclosure URLs
#    point at the GitHub Release asset we're about to upload. The private key is read from
#    the login keychain automatically.
echo "==> generating appcast (EdDSA-signed)"
"$TOOLS/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$APPCAST" \
  "$STAGE"

# 4) Build the human-facing .dmg from the SAME signed bundle the zip was made from, so
#    its CFBundleVersion matches the shipped update exactly. Built into build/ (NOT $STAGE)
#    and only after the appcast is generated, so generate_appcast never treats the dmg as a
#    Sparkle enclosure. Sparkle updates use the zip; the dmg is just a nicer first install.
echo "==> packaging $DMG_NAME"
DMG_STAGING="$ROOT/build/dmg-staging"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "Relay" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

# 5) Generate the GitHub release notes, always including install + quarantine
#    instructions. First-timers land on the release page and download the .zip directly;
#    the ad-hoc app is quarantined on download, so they need the one-time xattr step.
#    (Sparkle updates handle quarantine themselves — no dance after the first install.)
NOTES="$STAGE/RELEASE_NOTES-$SHORT_VERSION.md"
sed "s/__VERSION__/$SHORT_VERSION/g; s/__DMG__/$DMG_NAME/g" > "$NOTES" <<'NOTES_TEMPLATE'
Relay __VERSION__ — menu-bar dispatcher for Claude Code sessions, with in-app auto-update (Sparkle).

<!-- Add release highlights here. -->

## Install

1. Download **__DMG__** below and open it.
2. Drag **Relay** onto **Applications**.
3. Relay is ad-hoc signed (not notarized), so macOS quarantines it on download. Clear the
   quarantine flag and launch it — run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Relay.app && open /Applications/Relay.app
   ```

   Without this, macOS shows *"Relay is damaged and can't be opened."* You only need it for
   the **first** install — Sparkle handles updates (and their quarantine) automatically.
4. On first launch approve the **Notifications** prompt, then open Relay's menu → **Install hooks**.

_(The `.zip` asset is what Sparkle downloads for auto-updates — you don't need it for a manual install.)_

## Updating

Already running an earlier Relay? Do nothing — it checks daily and offers this version, or
use **Check for Updates…** in the menu. No re-download, no quarantine step.
NOTES_TEMPLATE

echo
echo "==> done."
echo "    dmg (humans):   $DMG_PATH"
echo "    zip (Sparkle):  $STAGE/$ZIP_NAME"
echo "    appcast:        $APPCAST"
echo "    notes:          $NOTES"
echo
echo "Next steps (publish — nothing above left the machine):"
echo "  1. Create the GitHub release and upload BOTH assets (notes include install steps):"
echo "       gh release create $TAG \"$DMG_PATH\" \"$STAGE/$ZIP_NAME\" --title \"Relay $SHORT_VERSION\" --notes-file \"$NOTES\""
echo "  2. Commit the updated appcast so SUFeedURL serves it:"
echo "       git add appcast.xml VERSION && git commit -m \"Release $SHORT_VERSION\" && git push"
echo
echo "  (Edit $NOTES first if you want to add highlights.)"
echo "  Existing installs will pick it up on their next daily check (or via"
echo "  'Check for Updates…' in the menu)."
