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

# Stamp the exact git commit into the BUNDLE's Info.plist (the source Resources/Info.plist
# stays untouched, so the repo never goes dirty from a build). The About panel + Settings
# footer read MVGitCommit so you can tell precisely which commit a running build came from.
# A `-dirty` suffix flags a build made with uncommitted changes. Runs BEFORE codesign so the
# stamped plist is sealed.
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && GIT_SHA="${GIT_SHA}-dirty"
/usr/libexec/PlistBuddy -c "Add :MVGitCommit string $GIT_SHA" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :MVGitCommit $GIT_SHA" "$APP/Contents/Info.plist"
echo "▸ git commit stamp: MVGitCommit=$GIT_SHA"

# ── Sparkle.framework ────────────────────────────────────────────────────────
# The binary links @rpath/Sparkle.framework (SPM binary artifact). A raw
# `swift build` run finds it next to the binary via @loader_path, but the .app
# bundle does NOT — shipping without bundling it makes the installed app die at
# launch with dyld "Library missing" (the v0.1 DMG bug). Bundle the framework
# and point an rpath at Contents/Frameworks like a normal Mac app.
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
    echo "▸ bundling Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    # -R preserves the framework's internal symlink structure (Versions/Current …);
    # a plain cp -r would materialize duplicates and break codesign's bundle layout.
    cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/Maverything" 2>/dev/null || true
else
    echo "  (warning: Sparkle artifact not found at $SPARKLE_SRC — app will not launch as a bundle)"
fi

echo "▸ codesign (identity: $SIGN_ID)"
# When using the dedicated dev cert, unlock its keychain and sign against it so
# TCC grants (FDA/Accessibility) persist across rebuilds.
KCARG=()
SIGNKC="$HOME/Library/Keychains/maverything-signing.keychain-db"
if [ "$SIGN_ID" != "-" ] && [ -f "$SIGNKC" ]; then
    security unlock-keychain -p mav "$SIGNKC" 2>/dev/null || true
    # Sign by SHA-1 hash so a same-named cert lingering in the login keychain
    # doesn't make the identity ambiguous.
    H=$( (security find-certificate -c "$SIGN_ID" -Z "$SIGNKC" 2>/dev/null || true) | awk '/SHA-1 hash:/{print $NF}')
    if [ -n "$H" ]; then
        SIGN_ID="$H"
        KCARG=(--keychain "$SIGNKC")
    fi
fi
sign() {   # sign <path> [extra codesign args…]
    local target="$1"; shift
    if [ ${#KCARG[@]} -eq 0 ]; then
        codesign --force --options runtime --sign "$SIGN_ID" "$@" "$target"
    else
        codesign --force --options runtime --sign "$SIGN_ID" "${KCARG[@]}" "$@" "$target"
    fi
}

# Sparkle.framework nests its own executables (XPC services, Autoupdate, Updater.app);
# per Sparkle's signing guidance, sign those innermost-first, then the framework —
# all BEFORE the outer bundle seal.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
    echo "▸ codesign Sparkle.framework (nested-first)"
    for xpc in "$SPK/Versions/B/XPCServices/"*.xpc; do
        [ -e "$xpc" ] && sign "$xpc" --preserve-metadata=entitlements
    done
    [ -e "$SPK/Versions/B/Autoupdate" ]   && sign "$SPK/Versions/B/Autoupdate"
    [ -e "$SPK/Versions/B/Updater.app" ]  && sign "$SPK/Versions/B/Updater.app"
    sign "$SPK"
fi

# Nested helper executables (Contents/Helpers/*) are auxiliary Mach-O and must be
# signed BEFORE the outer bundle — codesign refuses to seal a bundle that contains
# an unsigned nested code object.
for helper in "$APP/Contents/Helpers/"*; do
    [ -f "$helper" ] || continue
    echo "▸ codesign helper: $helper"
    if [ ${#KCARG[@]} -eq 0 ]; then
        codesign --force --options runtime --sign "$SIGN_ID" "$helper"
    else
        codesign --force --options runtime --sign "$SIGN_ID" "${KCARG[@]}" "$helper"
    fi
done
echo "▸ codesign app: $APP"
if [ ${#KCARG[@]} -eq 0 ]; then
    codesign --force --options runtime \
        --entitlements Resources/Maverything.entitlements \
        --sign "$SIGN_ID" \
        "$APP"
else
    codesign --force --options runtime \
        --entitlements Resources/Maverything.entitlements \
        --sign "$SIGN_ID" "${KCARG[@]}" \
        "$APP"
fi

echo "✓ built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/   /' || true

if [ "${1:-}" = "run" ]; then
    echo "▸ launching"
    open "$APP"
fi
