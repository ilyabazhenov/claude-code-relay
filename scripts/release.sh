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
ZIP_NAME="Relay-$SHORT_VERSION.zip"
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

echo
echo "==> done."
echo "    archive:  $STAGE/$ZIP_NAME"
echo "    appcast:  $APPCAST"
echo
echo "Next steps (publish — nothing above left the machine):"
echo "  1. Create the GitHub release and upload the archive:"
echo "       gh release create $TAG \"$STAGE/$ZIP_NAME\" --title \"Relay $SHORT_VERSION\" --notes \"...\""
echo "  2. Commit the updated appcast so SUFeedURL serves it:"
echo "       git add appcast.xml VERSION && git commit -m \"Release $SHORT_VERSION\" && git push"
echo
echo "  Existing installs will pick it up on their next daily check (or via"
echo "  'Check for Updates…' in the menu)."
