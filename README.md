# Maverything

**Mac + Everything** — an instant, system-wide, real-time file search app for macOS,
modeled after [voidtools Everything](https://www.voidtools.com/) on Windows.

Type anything and see matches across **every file on your Mac instantly** — including
hidden files, system files, and other apps' data that Spotlight ignores. Pure Swift,
native AppKit/SwiftUI, no external dependencies.

## How it maps Everything's design onto macOS

Everything is fast on Windows because of three things: it reads the NTFS **MFT** in
bulk, tracks changes via the **USN journal**, and keeps a flat **in-RAM** index it
brute-force scans. macOS has no userspace MFT, so:

| Everything (NTFS) | Maverything (APFS) |
|---|---|
| Raw `$MFT` bulk read | **`getattrlistbulk(2)`** parallel tree walk (~120k entries/s/core) |
| `$UsnJrnl` + USN cursor | **FSEvents** on `/` (file-level) + persisted event id for resume |
| Flat RAM list (name+size+mtime+parent) | **Struct-of-arrays in RAM**; paths rebuilt by walking parents |
| Multi-threaded `strstr` | **multi-core `memmem`** over a packed UTF-8 blob, scanned in sort order |
| `Everything.db` (serialized RAM) | **mmap-style binary snapshot** + FSEvents replay on launch |

### Measured on this machine (Apple Silicon M4, APFS)
- Cold whole-disk crawl: **3.28 M files in ~26 s** (`/` + Data + DMG volumes)
- Warm relaunch from snapshot: **~1 s** for 3.28 M files
- Search latency: **~0.1–3 ms** per keystroke (sort order precomputed once)
- Memory / snapshot: ~216 MB for 3.28 M files

## Architecture

```
Sources/
  MaverythingCore/            # pure engine, no UI
    FileIndex.swift           # struct-of-arrays + path reconstruction + live deltas
    FileEnumerator.swift      # getattrlistbulk parallel crawler (+ fsid/firmlink guard)
    SearchEngine.swift        # multi-core memmem scan in cached sort order, top-K
    Watcher.swift             # FSEvents stream + Reconciler (dirty-dir diff)
    Snapshot.swift            # binary save/load of the whole index
    Volumes.swift             # getmntinfo volume discovery + cloud exclusions
    Permissions.swift         # Full Disk Access probe + deep-link
  Maverything/                # the app
    MaverythingApp.swift      # @main, Window + MenuBarExtra, global ⌥Space hotkey
    ContentView.swift         # search bar + status bar + ⌃U scope toggle + gear menu
    ResultsTableView.swift    # AppKit NSTableView (handles millions of rows)
    OnboardingView.swift      # Full Disk Access flow
    HotKey.swift              # Carbon RegisterEventHotKey wrapper
  mvtest/                     # headless engine test/benchmark harness
prototype/                    # standalone getattrlistbulk speed/offset experiments
```

Key correctness details:
- **System vs Data volume**: crawls `/` and `/System/Volumes/Data` separately with an
  `ATTR_CMN_FSID` guard (read via `getattrlist`, *not* `statfs`, so it matches the
  per-entry fsid) — no firmlink double-counting, no missing System files.
- **Cloud storage** (`~/Library/CloudStorage`, iCloud) is excluded by default (slow
  online File Providers); toggle it on in the gear menu.
- **Live updates**: FSEvents marks parent dirs dirty → re-list with getattrlistbulk →
  diff against the index → add/remove(tombstone)/update; new subtrees recurse.
  Bursts are coalesced; `MustScanSubDirs`/dropped events trigger a full re-crawl.
- **Thread safety**: the search scan and live deltas serialize on the index lock so a
  concurrent change never tears a read.

## Build & run

```bash
./build.sh run          # build (release), assemble Maverything.app, ad-hoc sign, launch
```

Requires Xcode 16+ / Swift 6 toolchain. The app is **not sandboxed** (whole-disk
indexing is incompatible with App Sandbox).

### Full Disk Access
To index *every* file (system, hidden, other apps' data) the app needs **Full Disk
Access**. On first launch it shows an onboarding sheet → **Open Settings** → enable
**Maverything** under Privacy & Security ▸ Full Disk Access → **I've granted access**.
Without it, results are limited to what your account can already read.

### Keep the FDA grant across rebuilds (recommended for development)
Ad-hoc signing changes the code hash every build, so macOS forgets the FDA grant.
Create a stable self-signed cert **once** (you run this; it modifies your login keychain):

```bash
./make-cert.sh
MAVERYTHING_SIGN_ID="Maverything Dev Cert" ./build.sh run
```

## Usage
- **⌥Space** — summon / dismiss the window from anywhere
- Type to search; results update instantly
- **⌃U** — toggle matching the full **path** vs just the **name** (Everything parity)
- Click a column header to sort (Name / Path / Size / Date Modified)
- Right-click — Open · Reveal in Finder · Copy Path; double-click to open
- Menu bar icon — Show / Reindex / Quit; gear menu — include cloud storage, reindex

## Roadmap / not yet done
- NEON-SIMD matcher + fzf-style fuzzy mode (currently libc `memmem`, exact substring)
- Incremental sort-order maintenance (currently rebuilt on change)
- Other users' home folders (needs a privileged helper; current scope = your user + system)
- Developer ID signing + notarization for distribution
