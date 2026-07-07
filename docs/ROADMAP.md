# Maverything Roadmap

This file tracks public product and engineering direction only. Release credentials, signing keys, and launch/community plans do not belong in this repository.

## Done for the First Public Test

- GPL-3.0 license
- native SwiftUI/AppKit app
- whole-volume indexing
- FSEvents live updates
- compressed snapshot reload
- table, compact, two-pane, and grid layouts
- Everything-style query syntax
- Finder actions and drag-out workflows
- dynamic volume indexing
- custom roots for network shares
- folder-size indexing
- run-count sort
- `mvfind` CLI
- `mv-mcp` MCP server
- agent skill draft
- GitHub Actions release build plus `mvsim`
- DMG packaging
- lightweight GitHub Releases update checker
- README screenshots and GIF

## Near-Term

- Developer ID signing and notarized DMG releases
- first-run install polish for downloaded builds
- Homebrew cask in a personal tap, then potential main cask submission after notarization
- clearer permission diagnostics for Full Disk Access and Accessibility
- visible Run Count / Date Run columns in the table
- CLI install affordance from Settings
- `mvfind --help` and shell-completion polish
- broader benchmark table across Apple Silicon and Intel Macs

## Search and Indexing

- unique-basename index for common-name narrowing
- boolean grouping operators like `< >`
- more Everything-compatible date and size aliases
- richer duplicate-finder modes
- optional content index for users who explicitly want persistent full-text search
- more efficient children map representation

## App Experience

- saved-search management UI
- richer preview-pane metadata
- better first-run demo state when the index is empty or Full Disk Access is missing
- settings import/export
- custom result columns
- keyboard shortcut editor for app-level commands

## Updates

The current updater is dependency-free: it checks GitHub Releases and opens the newest DMG.

Future work:

- signed Sparkle appcast
- in-app download progress
- automatic install flow after Developer ID signing and notarization are stable
- release-channel preference for stable vs prerelease builds

## Trust Boundary

Maverything asks for Full Disk Access, so the code, release process, and privacy story must stay easy to inspect:

- no telemetry
- no analytics SDK
- no background network calls except explicit update checks
- no secret material in git
- public source for the app, CLI, MCP server, tests, packaging, and docs
