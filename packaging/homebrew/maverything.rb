# ============================================================================
# Backed by the v1.0.0 GitHub release: Maverything-1.0.0.dmg is Developer ID
# signed, Apple-notarized, and stapled, so this cask installs cleanly (no
# --no-quarantine needed). Version, sha256, and url below all point at v1.0.0.
#
# Not yet submitted to the official homebrew/cask tap — usable from a personal
# tap today. On each release bump `version` + `sha256`
# (shasum -a 256 dist/Maverything-<version>.dmg); the url template follows.
# ============================================================================
cask "maverything" do
  version "1.0.0"
  sha256 "3d1e34b4a2aa60364868d7033cc3048e2ada328a114f5374c01875f63b62d255"

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

  # The saved index snapshot + app data. UserDefaults (kr.kdr.maverything) are
  # left alone by design; add "~/Library/Preferences/kr.kdr.maverything.plist"
  # here if a scorched-earth zap is preferred.
  zap trash: [
    "~/Library/Application Support/Maverything",
  ]

  # Caveat note:
  # - Developers who built from source may also have the make-cert.sh signing
  #   keychain at ~/Library/Keychains/maverything-signing.keychain-db and a
  #   "Maverything Dev Cert" identity; those are dev-machine artifacts, not
  #   installed by this cask, so zap deliberately does not touch them.
  # - v1.0.0 is notarized, so it launches without a Gatekeeper prompt — no
  #   right-click -> Open and no --no-quarantine required.
end
