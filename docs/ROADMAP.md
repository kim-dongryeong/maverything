# Maverything — Roadmap

Everything in this repo (including this file) is part of the open-source project — see
"Open-source scope" at the bottom. Items are grouped by horizon, not priority.

## Near-term (pre-launch)

- **Apple Developer signing + notarization** — the one true gate to sharing the app
  (`make-dmg.sh` already has the `MV_NOTARIZE=1` hook; needs Apple Developer credentials).
- **Sparkle auto-update** — EdDSA-signed `appcast.xml` on GitHub Releases; "Check for
  Updates" menu + optional silent background updates.
- **GitHub launch** — LICENSE (GPL-3.0 recommended: blocks closed-source reuse, builds
  trust for a Full-Disk-Access app), README with demo GIF + benchmark table, Homebrew
  cask, Show HN / r/macapps.

## Mid-term (adopt from the 3-app audit)

- **MCP server** — a thin bridge over the existing `QueryServer` Unix socket (already
  built + hardened). "Give an AI instant search over every file on your Mac" — a launch
  hook none of Everything/Cling/Cardinal has. The socket protocol was designed for this
  (versioned JSON, structured `{path,name,size,mtime,isDir}` results, `indexing` flag).
- **Agent Skill** — a `SKILL.md` teaching an agent when/how to call `mvfind` / the MCP
  tools (query syntax, sort keys, live-vs-snapshot). Small once the MCP exists.
- **CLI install affordance** — Settings ▸ "Install command-line tool" (symlink `mvfind`
  into `/usr/local/bin`), `--help`/man page polish.
- **Unique-basename index** (Cardinal-inspired) — fold same-named files so a common
  basename's candidate set shrinks instantly; complements the incremental narrowing.
- **`< >` grouping operators** — Everything's parenthesized boolean grouping.

## Long-term (post-adoption — "once we're downloaded and somewhat known")

- **`.mvignore` (gitignore-format excludes)** — Cling-style: manage excludes as a
  gitignore-syntax file (`dir/**`, `!re-include`, anchoring) alongside the existing
  Everything-parity excludes (folder list / file globs / include-only). Deferred
  deliberately: the current three exclude mechanisms already cover the practical cases,
  and full gitignore semantics (last-match-wins, dir-only rules, `!` interaction) is a
  couple days of careful work best spent once real users ask for it. Kept as "Advanced"
  so the settings UI doesn't grow a fourth exclude system prematurely.
- **Run-count column** in the table (the sort key already exists; this adds a visible
  Everything-style "Run Count" / "Date Run" column).
- **childrenOf CSR** — pack the children map into compressed-sparse-row arrays (~25-30 MB
  saved at 1.9M).
- **Content full-text index** — optional, opt-in; today `content:` streams on demand
  (64 KiB windows) with no persistent index, matching Cardinal.

## Open-source scope

**Yes — all of it is public**, and that is the point. If the project goes GPL-3.0/MIT
and lives on GitHub, then the app, `mvfind`, the `QueryServer`, the **MCP server**, the
**Agent Skill**, the docs, the mvsim test suite, and this roadmap are all in the same
public repo. There is no private tier. The reasons this is the right call for the stated
goal (reach + reputation, not revenue):

- macOS free-utility fame *is* GitHub stars — the whole category (Rectangle, IINA, Stats,
  AltTab, Cling, Cardinal) is open source, and the distribution funnel (Show HN, brew,
  "best free alternative" lists) runs through the public repo.
- A Full-Disk-Access app is trusted only when its code is auditable ("look — zero network
  calls"). Closing any part (especially the MCP/socket layer that exposes the index)
  would re-raise exactly the trust question open-sourcing answers.
- The MCP server and Skill are *marketing surface*, not moat — being public is how people
  discover "the file-search app that plugs into my AI."

The only things that are never in the repo are **secrets/credentials** (signing certs,
notarization keys, EdDSA private key) — those live outside git regardless of license.
Roadmap items being public also doesn't cost us: competitors can read the plan, but an
actively-shipped roadmap is a strength (contributors, early adopters), and ideas aren't
the moat — execution + the live index architecture is.
