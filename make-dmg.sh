#!/bin/bash
# make-dmg.sh — build a distributable DMG of Maverything.
#
#   ./make-dmg.sh                # ./build.sh (universal) + package dist/Maverything-<ver>.dmg
#   SKIP_BUILD=1 ./make-dmg.sh   # package the existing Maverything.app (no rebuild)
#
# The DMG contains Maverything.app plus an /Applications symlink (drag-to-install).
# Version comes from Resources/Info.plist (CFBundleShortVersionString).
set -euo pipefail
cd "$(dirname "$0")"

APP="Maverything.app"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "▸ ./build.sh (universal by default; MV_ARCH=native to override)"
    ./build.sh
else
    echo "▸ SKIP_BUILD=1 — packaging existing $APP"
fi
[ -d "$APP" ] || { echo "error: $APP not found — run ./build.sh first"; exit 1; }

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="dist/Maverything-$VER.dmg"

echo "▸ staging $APP + /Applications symlink"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/maverything-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ hdiutil create $DMG"
mkdir -p dist
hdiutil create -volname "Maverything $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    | sed 's/^/   /'

# ── Notarization ─────────────────────────────────────────────────────────────
# TODO(release): notarization requires a PAID Apple Developer account.
# Prerequisite: sign the app with a "Developer ID Application: <name> (<TEAM_ID>)"
# identity (MAVERYTHING_SIGN_ID env for build.sh) — self-signed/ad-hoc apps are
# rejected by the notary service. Once credentials exist, run with:
#
#   MV_NOTARIZE=1 APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX \
#   APP_PASSWORD=xxxx-xxxx-xxxx-xxxx ./make-dmg.sh
#
# (APP_PASSWORD is an app-specific password from appleid.apple.com, or use
#  `xcrun notarytool store-credentials` and swap the flags for --keychain-profile.)
if [ "${MV_NOTARIZE:-0}" = "1" ]; then
    : "${APPLE_ID:?MV_NOTARIZE=1 needs APPLE_ID (Apple ID email)}"
    : "${TEAM_ID:?MV_NOTARIZE=1 needs TEAM_ID (10-char Developer Team ID)}"
    : "${APP_PASSWORD:?MV_NOTARIZE=1 needs APP_PASSWORD (app-specific password)}"
    echo "▸ notarizing $DMG (this waits for Apple)"
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" \
        --wait
    echo "▸ stapling ticket"
    xcrun stapler staple "$DMG"
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "✓ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "▸ codesign -dv of the app inside:"
codesign -dv "$STAGE/$APP" 2>&1 | sed 's/^/   /'
