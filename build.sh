#!/bin/bash
# Build Maverything.app — compiles the SPM package and assembles a runnable,
# (self-)signed .app bundle. Usage:
#   ./build.sh           # build + assemble
#   ./build.sh run       # build + assemble + launch
#   MAVERYTHING_SIGN_ID="Maverything Dev Cert" ./build.sh   # stable cert (sticky FDA)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="Maverything.app"
SIGN_ID="${MAVERYTHING_SIGN_ID:--}"   # default: ad-hoc

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Maverything"
[ -x "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Maverything"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ codesign (identity: $SIGN_ID)"
# When using the dedicated dev cert, unlock its keychain and sign against it so
# TCC grants (FDA/Accessibility) persist across rebuilds.
KCARG=()
SIGNKC="$HOME/Library/Keychains/maverything-signing.keychain-db"
if [ "$SIGN_ID" != "-" ] && [ -f "$SIGNKC" ]; then
    security unlock-keychain -p mav "$SIGNKC" 2>/dev/null || true
    # Sign by SHA-1 hash so a same-named cert lingering in the login keychain
    # doesn't make the identity ambiguous.
    H=$(security find-certificate -c "$SIGN_ID" -Z "$SIGNKC" 2>/dev/null | awk '/SHA-1 hash:/{print $NF}')
    [ -n "$H" ] && SIGN_ID="$H"
    KCARG=(--keychain "$SIGNKC")
fi
codesign --force --options runtime \
    --entitlements Resources/Maverything.entitlements \
    --sign "$SIGN_ID" "${KCARG[@]}" \
    "$APP" 2>&1 | sed 's/^/   /' || {
        echo "   (runtime-hardened sign failed; retrying without hardened runtime)"
        codesign --force --entitlements Resources/Maverything.entitlements \
            --sign "$SIGN_ID" "${KCARG[@]}" "$APP"
    }

echo "✓ built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/   /' || true

if [ "${1:-}" = "run" ]; then
    echo "▸ launching"
    open "$APP"
fi
