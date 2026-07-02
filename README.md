# Maverything

**Mac + Everything** — a **free** macOS clone of [voidtools Everything](https://www.voidtools.com/):
instant, system-wide, real-time file search.

Type anything and matches appear **as you type, in milliseconds, across every file on
your Mac** — including the hidden files, system files, and other apps' data that
Spotlight deliberately ignores. Pure Swift, native AppKit/SwiftUI, no external
dependencies, universal binary (Apple Silicon + Intel).

<!-- TODO: screenshots
![Search window](docs/img/screenshot-main.png)
![Compact bar](docs/img/screenshot-compact.png)
-->

## Why it's instant

Everything is fast on Windows because it bulk-reads the NTFS MFT, tracks changes via
the USN journal, and brute-force scans a flat in-RAM index. macOS has none of those,
so Maverything rebuilds the same design on APFS:

| Everything (NTFS) | Maverything (APFS) |
|---|---|
| Raw `$MFT` bulk read | `getattrlistbulk(2)` parallel tree walk (~120k entries/s/core) |
| `$UsnJrnl` + USN cursor | FSEvents on `/` + persisted event id for resume |
| Flat RAM list | Struct-of-arrays in RAM; paths rebuilt by walking parent links |
| Multi-threaded `strstr` | Multi-core `memmem` over a packed UTF-8 blob, scanned in cached sort order |
| `Everything.db` | LZFSE-compressed binary snapshot + FSEvents replay on launch |

Measured on an Apple Silicon M4 (16 GB, APFS): cold whole-disk crawl of ~3.3 M files
in ~26–40 s, warm relaunch from snapshot ~1 s, per-keystroke search ~0.1–3 ms
(broadest queries ~100 ms over 4 M files).

## Features

- **Search as you type** over every indexed file name — hidden and system files included.
- **4 match modes**: **Exact substring** (Everything's default — fastest), **Fuzzy**
  (fzf/Sublime-style with scoring), **Wildcard** (`*`/`?` glob), **Regex**.
- **Everything query syntax** (combine freely, e.g. `photo ext:jpg dm:week size:>1mb`):

  | Syntax | Meaning |
  |---|---|
  | `jpg\|png` | OR — either alternative matches (space is still AND) |
  | `ext:png,jpg` | one of these extensions |
  | `size:>10mb` | size `>` `<` `>=` `<=` (kb/mb/gb) |
  | `dm:today` | modified: today / week / month / `2026-01-31` |
  | `folder:` / `file:` | only folders / only files |
  | `path:src` | match against the full path |
  | `name:data` | match the name even in path mode |
  | `case:on` | case-sensitive query |
  | `ww:` | whole words only (`report` ≠ `reporting`) |
  | `dupe:` | only names that exist more than once (duplicate finder) |
  | `content:text` | search **inside** files (on-demand, slower — combine with `ext:`) |
  | `tag:red;blue` | Finder tags — `;` = OR, repeat `tag:` = AND |

  Plus `"quoted phrases"` and `-negation`.
- **Everything's toggle shortcuts**: `⌃U` Match Path · `⌃I` Match Case · `⌃B` Match
  Whole Word · `⌃R` Regex (and `⌘F` focus search, `⌥⌘R` reindex).
- **Type-filter chips** under the search field (Folders, Documents, Images, …) —
  one click ANDs a `folder:`/`ext:` clause with your query.
- **3 layouts** (`⌘1/2/3`): full **Table** grid · Spotlight-style **Compact bar** ·
  **Preview pane** (results + Quick Look/metadata).
- **Folder indexing** for locations the volume scan doesn't cover — above all
  **NAS/SMB network shares** (live updates on network volumes are best-effort).
- **User excludes** — excluded folders drop out of the index immediately.
- **Dynamic volumes** — external drives are indexed on mount and dropped on unmount,
  automatically.
- **Finder integration**: Quick Look (`Space`) · rename in place (`F2`, or `Enter` if
  you prefer) · Move to Trash (`⌘⌫`) · Finder **tags** · Get Info (`⌘I`) · drag files
  straight out of the results.
- **Saved searches** — name a query and recall it from the menu.
- **CSV export** of the current results (Name, Path, Size, Dates).
- **Global hotkey** — summon the window from anywhere; default `⌥Space`, rebindable
  to almost any combo (an event-tap mode grabs combos other apps also claim, like
  `⇧Space`).
- **Instant relaunch** — the whole index persists as an LZFSE-compressed snapshot and
  resumes from the saved FSEvents id, so restart takes ~1 s instead of a re-crawl.
- **Universal binary** — one app, native on arm64 and x86_64.
- Menu-bar icon, light/dark/system appearance, comfortable/compact row density.

## Install

### Build from source

Requires macOS 14 (Sonoma) or later and a Swift 6 toolchain (Xcode 16+).

```bash
git clone <this repo> && cd maverything
./build.sh          # release build + assemble Maverything.app (universal)
./build.sh run      # …and launch it
MV_ARCH=native ./build.sh   # faster single-arch dev build
```

### DMG

```bash
./make-dmg.sh       # builds and packages dist/Maverything-<version>.dmg
```

Until releases are signed with a Developer ID and notarized, Gatekeeper will warn on
a downloaded DMG: right-click the app → **Open** (once), or clear quarantine with
`xattr -dr com.apple.quarantine /Applications/Maverything.app`.

A draft Homebrew cask lives at `packaging/homebrew/maverything.rb` (not yet
submitted anywhere).

### First run: Full Disk Access

To index *every* file — system files, hidden dotfiles, other apps' containers — the
app needs **Full Disk Access**. Spotlight hides that part of the disk by design;
FDA is the supported way for a third-party tool to see it. On first launch
Maverything shows an onboarding sheet → **Open Settings** → enable Maverything under
**Privacy & Security ▸ Full Disk Access**. Without it the app still works, but
results are limited to what your account can already read. The app is **not
sandboxed** (whole-disk indexing is incompatible with App Sandbox) and never sends
anything anywhere: the index lives in
`~/Library/Application Support/Maverything/index.mvidx`.

Developer note: ad-hoc signing changes the code hash every rebuild, which makes
macOS forget the FDA grant. Run `./make-cert.sh` once to create a stable self-signed
cert so the grant sticks (`MAVERYTHING_SIGN_ID="Maverything Dev Cert" ./build.sh`).

## mvfind — the same search, in your terminal

`mvfind` loads the app's saved snapshot (instant, no crawl; falls back to a live
crawl if there is none) and searches it with the same engine and query syntax:

```bash
swift build -c release   # builds mvfind alongside the app
mvfind report ext:pdf size:>1mb
mvfind "*.swift" --wildcard --sort size --limit 20
mvfind config --path --count
# flags: [--fuzzy|--wildcard] [--path] [--sort name|size|date|relevance] [--limit N] [-0] [--count]
```

## Development

```
Sources/
  MaverythingCore/   # engine: enumerator, index, search, FSEvents watcher, snapshot
  Maverything/       # the app: SwiftUI shell + AppKit NSTableView results
  mvfind/            # CLI over the same core + snapshot
  mvtest/            # headless engine test/benchmark harness
  mvsim/             # simulation harness
```

`mvsim` builds a synthetic file tree and drives the engine through dozens of
realistic scenarios — every match mode, all query filters, sorting, live
add/delete/modify, volume mount/unmount, snapshot round-trip — asserting PASS/FAIL
and writing `SIMULATION-REPORT.md` with latency numbers:

```bash
swift run -c release mvsim
```

## How it compares

- **Spotlight** ranks a curated, content-oriented index and intentionally skips
  hidden/system files; Maverything exhaustively lists every file name, instantly.
- **Find Any File** searches the live file system on demand — admirably thorough
  with nothing to maintain, but each search takes seconds; Maverything answers per
  keystroke from RAM.
- **Cling** and **Cardinal** are polished Everything-inspired macOS apps worth a
  look; Maverything's angle is simple: free, whole-disk coverage including
  hidden/system files, deep Everything syntax/shortcut parity, and a CLI.

## License

TBD by the author. Until a license is added, all rights reserved.
