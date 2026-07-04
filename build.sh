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
# Architecture: "universal" (default — ONE app runs natively on Apple Silicon AND
# Intel Macs; no separate Intel build needed) or "native" for faster dev iteration:
#   MV_ARCH=native ./build.sh
ARCH="${MV_ARCH:-universal}"
# Default to the stable dev cert if it exists (so TCC grants persist), else ad-hoc.
DEFAULT_ID="-"
[ -f "$HOME/Library/Keychains/maverything-signing.keychain-db" ] && DEFAULT_ID="Maverything Dev Cert"
SIGN_ID="${MAVERYTHING_SIGN_ID:-$DEFAULT_ID}"

if [ "$ARCH" = "universal" ]; then
    echo "▸ swift build -c $CONFIG (universal: arm64 + x86_64)"
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BIN=".build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/Maverything"
else
    echo "▸ swift build -c $CONFIG (native)"
    swift build -c "$CONFIG"
    BIN=".build/$CONFIG/Maverything"
fi
[ -x "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }
echo "▸ slices: $(lipo -archs "$BIN" 2>/dev/null || echo native)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Maverything"
# Bundle the CLI + MCP helpers so a Homebrew cask can symlink them onto PATH.
if [ "$ARCH" = "universal" ]; then
    HELPDIR=".build/apple/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
else
    HELPDIR=".build/$CONFIG"
fi
for tool in mvfind mv-mcp; do
    [ -x "$HELPDIR/$tool" ] && cp "$HELPDIR/$tool" "$APP/Contents/Helpers/$tool" || \
        echo "  (note: $tool not built — run swift build -c $CONFIG)"
done
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
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
# Nested helper executables (Contents/Helpers/*) are auxiliary Mach-O and must be
# signed BEFORE the outer bundle — codesign refuses to seal a bundle that contains
# an unsigned nested code object.
for helper in "$APP/Contents/Helpers/"*; do
    [ -f "$helper" ] || continue
    codesign --force --options runtime --sign "$SIGN_ID" "${KCARG[@]}" "$helper" 2>&1 | sed 's/^/   /' || \
    codesign --force --sign "$SIGN_ID" "${KCARG[@]}" "$helper" 2>&1 | sed 's/^/   /' || true
done
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
