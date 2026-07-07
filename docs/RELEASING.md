# Releasing Maverything

Maverything is GPL-3.0. The DMG bundles:

- `Maverything.app`
- `mvfind` at `Maverything.app/Contents/Helpers/mvfind`
- `mv-mcp` at `Maverything.app/Contents/Helpers/mv-mcp`

Never commit signing identities, notarization credentials, Sparkle keys, app-specific passwords, or `.env` files.

## Current Release State

The repo can already produce a distributable DMG:

```bash
./make-dmg.sh
```

If no Apple Developer ID certificate is installed, the app is signed with the local development identity or ad-hoc signing. That is fine for public testing, but macOS Gatekeeper will warn after download.

For a polished public release, install a **Developer ID Application** certificate and notarize the DMG.

Check local signing identities:

```bash
security find-identity -v -p codesigning
```

You want an identity like:

```text
Developer ID Application: <Name> (<TEAM_ID>)
```

## Version Bump

Update `Resources/Info.plist`:

```bash
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2' Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' Resources/Info.plist
```

Rules:

- `CFBundleShortVersionString`: human version, for example `0.1`, `0.2`, `1.0`
- `CFBundleVersion`: monotonic build number
- Git tag: `v<CFBundleShortVersionString>`

## Build and Package

Universal release build:

```bash
./make-dmg.sh
```

Output:

```text
dist/Maverything-<version>.dmg
```

Get checksum:

```bash
shasum -a 256 dist/Maverything-<version>.dmg
```

Sanity-check the DMG:

```bash
hdiutil attach dist/Maverything-<version>.dmg
open /Volumes/Maverything\ <version>/Maverything.app
hdiutil detach /Volumes/Maverything\ <version>
```

## Developer ID Signing

When the Developer ID certificate is installed:

```bash
MAVERYTHING_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)" ./build.sh
codesign --verify --deep --strict --verbose=2 Maverything.app
spctl --assess --type execute --verbose Maverything.app
```

Then package with the same identity:

```bash
MAVERYTHING_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)" ./make-dmg.sh
```

## Notarization

`make-dmg.sh` supports notarization through `MV_NOTARIZE=1`:

```bash
MV_NOTARIZE=1 \
APPLE_ID="you@example.com" \
TEAM_ID="XXXXXXXXXX" \
APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
MAVERYTHING_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)" \
./make-dmg.sh
```

After notarization, verify:

```bash
spctl --assess --type open --verbose dist/Maverything-<version>.dmg
xcrun stapler validate dist/Maverything-<version>.dmg
```

Prefer a keychain profile when cutting many releases:

```bash
xcrun notarytool store-credentials "maverything-notary" \
  --apple-id "you@example.com" \
  --team-id "XXXXXXXXXX" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Then adapt `make-dmg.sh` to use:

```bash
xcrun notarytool submit "$DMG" --keychain-profile "maverything-notary" --wait
```

## GitHub Release

Create the tag and release:

```bash
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
git tag "v$VER"
git push origin "v$VER"
gh release create "v$VER" "dist/Maverything-$VER.dmg" \
  --title "Maverything $VER" \
  --notes-file /tmp/maverything-release-notes.md
```

Release notes should include:

- top user-facing changes
- whether the DMG is notarized
- first-run Full Disk Access note
- checksum
- known limitations

## Update Checker

The in-app updater checks:

```text
https://api.github.com/repos/kim-dongryeong/maverything/releases/latest
```

It compares the latest release tag with `CFBundleShortVersionString` and opens the `.dmg` asset from that release.

For updates to work well:

- tag releases as `v0.1`, `v0.2`, etc.
- attach `Maverything-<version>.dmg`
- keep prerelease/draft status consistent with what users should see

## Homebrew Cask Draft

After the DMG is built and uploaded, update:

```text
packaging/homebrew/maverything.rb
```

Set:

- `version`
- `sha256`
- `url`
- `homepage`

The cask should not be submitted to the main Homebrew Cask repo until releases are Developer ID signed and notarized.
