# ============================================================================
# Backed by the v1.0.1 GitHub release: Maverything-1.0.1.dmg is Developer ID
# signed, Apple-notarized, and stapled, so this cask installs cleanly (no
# --no-quarantine needed). Version, sha256, and url below all point at v1.0.1.
#
# Not yet submitted to the official homebrew/cask tap — usable from a personal
# tap today. On each release bump `version` + `sha256`
# (shasum -a 256 dist/Maverything-<version>.dmg); the url template follows.
# ============================================================================
cask "maverything" do
  version "1.0.1"
  sha256 "0ecb0cbc3a3a86bc50f55beb3fa361b7050c29ef1500db9da7ac43441124a39a"

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
  # - v1.0.1 is notarized, so it launches without a Gatekeeper prompt — no
  #   right-click -> Open and no --no-quarantine required.
end
