# ============================================================================
# DRAFT — NOT SUBMITTED. Do not `brew install` this yet.
#
# Prepared for a future GitHub release of Maverything. Before this cask works:
#   1. Publish a GitHub release with dist/Maverything-<version>.dmg attached
#      (built by ./make-dmg.sh).
#   2. Fill in `sha256` (shasum -a 256 dist/Maverything-<version>.dmg).
#   3. For homebrew/cask submission the app must be Developer ID-signed and
#      notarized (see the TODO block in make-dmg.sh); unsigned apps are only
#      acceptable in a personal tap with `--no-quarantine` caveats.
# ============================================================================
cask "maverything" do
  version "0.1"
  sha256 "PLACEHOLDER_SHA256_OF_DMG" # TODO: shasum -a 256 Maverything-#{version}.dmg

  url "https://github.com/kim-dongryeong/maverything/releases/download/v#{version}/Maverything-#{version}.dmg"
  name "Maverything"
  desc "Instant, system-wide, real-time file search (an Everything clone for macOS)"
  homepage "https://github.com/kim-dongryeong/maverything"

  depends_on macos: ">= :sonoma" # LSMinimumSystemVersion 14.0

  app "Maverything.app"

  # CLI + MCP tools bundled inside the app (build.sh copies them to Contents/Helpers);
  # symlink onto PATH so `mvfind` works in a terminal and `mv-mcp` works as an MCP server.
  binary "#{appdir}/Maverything.app/Contents/Helpers/mvfind"
  binary "#{appdir}/Maverything.app/Contents/Helpers/mv-mcp"

  # The saved index snapshot + app data. UserDefaults (com.maverything.app) are
  # left alone by design; add "~/Library/Preferences/com.maverything.app.plist"
  # here if a scorched-earth zap is preferred.
  zap trash: [
    "~/Library/Application Support/Maverything",
  ]

  # Caveat note (kept as a comment while this is a draft):
  # - Developers who built from source may also have the make-cert.sh signing
  #   keychain at ~/Library/Keychains/maverything-signing.keychain-db and a
  #   "Maverything Dev Cert" identity; those are dev-machine artifacts, not
  #   installed by this cask, so zap deliberately does not touch them.
  # - Until releases are notarized, first launch needs right-click -> Open
  #   (or install with `brew install --cask --no-quarantine maverything`).
end
