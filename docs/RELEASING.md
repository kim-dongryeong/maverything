# Releasing Maverything

Short checklist for cutting a release.

1. **Bump the version** in `Resources/Info.plist`:
   - `CFBundleShortVersionString` (marketing version, e.g. `0.2`)
   - `CFBundleVersion` (monotonic build number)

   ```bash
   /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.2' Resources/Info.plist
   /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' Resources/Info.plist
   ```

2. **Build the DMG** (universal build + package):

   ```bash
   ./make-dmg.sh          # → dist/Maverything-<ver>.dmg
   ```

   Sanity-check: mount the DMG, launch the app from it once.

3. **(Future) Notarize** — requires an Apple Developer account and a
   Developer ID Application signing identity. The exact commands are staged in
   `make-dmg.sh` behind `MV_NOTARIZE=1`:

   ```bash
   MV_NOTARIZE=1 APPLE_ID=… TEAM_ID=… APP_PASSWORD=… ./make-dmg.sh
   ```

   Until then, release notes should mention the right-click → Open /
   `xattr -dr com.apple.quarantine` first-launch step.

4. **Create the GitHub release**: tag `v<ver>`, attach
   `dist/Maverything-<ver>.dmg`, paste highlights from the changelog.

   ```bash
   gh release create "v<ver>" dist/Maverything-<ver>.dmg --title "Maverything <ver>" --notes "…"
   ```

5. **Update the Homebrew cask draft** `packaging/homebrew/maverything.rb`:
   bump `version`, set `sha256` from
   `shasum -a 256 dist/Maverything-<ver>.dmg`, verify the `url` matches the
   uploaded asset name.
