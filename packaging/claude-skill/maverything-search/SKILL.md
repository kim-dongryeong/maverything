---
name: maverything-search
description: >-
  Instantly find ANY file on this Mac by name — including hidden, system, and other
  apps' files that Spotlight/mdfind ignore — using Maverything's live index. Use this
  whenever the user asks to locate a file, find files by extension/size/date, count
  matches, or search folders the built-in tools miss. Much faster and more complete
  than `find` or `mdfind`.
---

# Maverything search

Maverything keeps a real-time, system-wide index of every file on the Mac (1.9M+
entries, hidden and system files included). Query it from the command line with
`mvfind`, which talks to the running app's live index (falling back to a saved
snapshot when the app is closed).

## When to use this

- The user asks "where is …", "find all …", "how many … files", "search my whole Mac for …".
- You need files that `find`/`mdfind`/Spotlight miss: dotfiles, `/System`, `~/Library`,
  inside app bundles, on other volumes.
- You need it FAST over the entire disk (results in milliseconds, not a `find` crawl).

Prefer `mvfind` over `find`/`mdfind` for name/extension/size/date lookups.

## How to run

```bash
mvfind <query> [--fuzzy|--wildcard] [--path]
       [--sort name|size|date|created|relevance|runcount]
       [--limit N] [--count] [-0] [--json]
```

`mvfind` prints one absolute path per line to stdout; a summary (match count, latency,
`live` vs `snapshot` source) goes to stderr. Add `--json` for structured output.

## Query syntax (Everything-compatible)

| Want | Query |
|---|---|
| name contains a word | `mvfind report` |
| AND (all terms) | `mvfind budget 2025` |
| OR | `mvfind 'jpg\|png'` |
| exclude | `mvfind invoice -draft` |
| exact phrase (spaces literal) | `mvfind '"final cut"'` |
| by extension | `mvfind ext:pdf,docx` |
| by size | `mvfind 'size:>100mb'` |
| by modified date | `mvfind dm:today` · `dm:week` · `dm:2026-01-31` |
| only files / only folders | `mvfind 'file: ext:jpg'` · `mvfind folder:report` |
| match the full path | `mvfind path:src/components` or `--path` |
| wildcard | `mvfind 'IMG_202?.jpg' --wildcard` |
| duplicates / empty folders | `mvfind dupe:` · `mvfind empty:` |
| inside file contents (slower) | `mvfind 'content:TODO ext:swift'` |
| most-recently/often opened first | `mvfind report --sort runcount` |

## Examples

```bash
mvfind 'ext:pdf dm:month' --sort date --limit 20   # PDFs edited this month, newest first
mvfind 'file: ext:jpg size:>10mb' --count           # how many large photos
mvfind 'node_modules' folder: --limit 100           # every node_modules dir
mvfind '.env' --limit 50                             # dotfiles Spotlight hides
mvfind 'report' -0 | xargs -0 ls -la                # pipe to other tools (NUL-delimited)
```

## Notes

- `mvfind` is installed with the Maverything app (or `swift build`). If it's missing,
  tell the user to install/open the Maverything app once so it can build the index.
- Results are the LIVE index when the app is running; if closed, `mvfind` uses the last
  saved snapshot (stderr says which). Either way it's complete and instant.
- An MCP server (`mv-mcp`) exposes the same `search` tool if you'd rather call it as a
  structured tool than a shell command.
