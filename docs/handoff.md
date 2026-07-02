## TURN: CODEX
**Updated:** 2026-07-02 20:40

## GOAL
Milestone **L4 — accuracy & performance polish** for Maverything (the macOS voidtools-
"Everything" clone). The engine is now hardened: read-write index lock, FSEvents
resume-cursor correctness, NFC event paths, file↔dir flip handling, mount de-dup,
incremental narrow-as-you-type, and a `FileIndex.mutationGen` that makes search-cache
invalidation impossible to miss. This batch closes the remaining items surfaced by the
Codex×agy cross-reviews, each self-contained. Rule still in force: when a choice has
options A/B/C, BUILD THEM ALL (switchable) — never silently pick one.

## CODEBASE MAP
- Engine `Sources/MaverythingCore/`: `SearchEngine` (fastExact + general evaluator +
  regexSearch; orderCache keyed on `index.mutationGenLocked`; incremental narrowing;
  `computePathOrder` = true folded full-path argsort for the Path column, cached),
  `FileIndex` (struct-of-arrays + rwlock rdlock()/wrlock(); `computeOrder` per SortKey;
  `foldBlob` = asciiLower(NFC) sharing nameOff/nameLen), `FileEnumerator` (getattrlistbulk
  crawl), `Watcher` (FSWatcher + Reconciler), `Snapshot`, `Volumes`, `Matching`, `QueryParser`.
- App `Sources/Maverything/`: `AppModel`, `ResultsTableView`, `CompactResults`, `PreviewPane`,
  `ContentView`, `FilterBar`, `SearchMenus`, `OptionsButton`, `Settings`.
- Harness: `.build/release/mvsim` (62 scenarios → must stay 100% green), `mvfind` CLI, `mvtest`.
- Build: `swift build -c release`. Sim: `.build/release/mvsim`.

## OPEN QUESTIONS  (→ build ALL options, switchable; never choose for the user)
1. **Real Path-column sort** — ✅ DONE (1A, commit 64e4ffb). `computeOrder(.path)` →
   `computePathOrder()`: reconstructs each live entry's folded path once into a packed
   blob, argsorts by path bytes (UInt64-prefix + memcmp tie-break), cached in
   `orderCache[.path]` keyed on mutationGen. Both fastExact + general honor it. mvsim +4.
   - B) Directory-order tuple keys (parent order, then name) for cheaper rebuilds remains
     an OPTIONAL perf variant — SAME output order as 1A, so purely a rebuild-cost trade;
     defer unless path-sort rebuild shows up hot in mvtest (not user-visible, not urgent).
2. **Non-ASCII case folding** — `foldBlob` is ASCII-only lowercased, so `CAFÉ.txt` is not
   found by `café`/`cafe`. Options:
   - A) Add a Unicode-lowercased fold blob with its OWN offsets (foldOff/foldLen), since
     Unicode lowercasing can change byte length; keep the ASCII fast path for pure-ASCII
     names. Fold the query the same way. ← implement.
   - B) ASCII fold + a slow Unicode fallback compare only when the query has non-ASCII.
   Korean (Hangul) is caseless so unaffected; target accented-Latin/Cyrillic. mvsim assert.
3. **Relevance sort top-K** — `general()` relevance path stores + sorts EVERY match then
   takes `limit`. Use per-chunk bounded top-K (or partial selection) then merge, so a broad
   relevance query doesn't allocate/sort millions of pairs. Keep results identical.
4. **Dynamic mount/unmount** — volumes mounted AFTER launch aren't indexed/watched; unmounts
   leave stale entries. Observe `NSWorkspace.shared.notificationCenter` didMount/didUnmount:
   on mount → crawl+watch the new root; on unmount → tombstone that subtree. (Also handle
   FSEvents RootChanged.)

## DONE-WHEN
- [x] Path-column sort yields true path order (not name order); mvsim asserts it. (64e4ffb)
- [ ] Non-ASCII case folding: `CAFÉ` findable via `café`/`cafe`; ASCII fast path intact; mvsim asserts.
- [ ] Relevance sort uses bounded top-K (no full-set sort); results unchanged; mvsim still green.
- [ ] Mount after launch is indexed+watched; unmount tombstones the volume (best-effort test/log).
- [ ] Name-blob offsets widened past the 4 GiB `UInt32` cap (UInt64 or segmented) — or a guarded graceful cap.
- [ ] mvsim grown by ≥4 scenarios (path-sort, non-ASCII fold, relevance top-K parity, …) — 100% green.
- [ ] Adversarially cross-review each increment (the OTHER agent red-teams: lock discipline —
      reads via rdlock/withReadLock, mutations bump mutationGen under wrlock; no eager per-row work).
- [ ] build green · existing flows intact · no secrets · clean tree.

## CONSTRAINTS
- Only edit files under this worktree. NEVER `git push`. One focused increment per turn.
- Index lock discipline: reads via `rdlock()`/`withReadLock`; every content mutation under
  `wrlock()` MUST `bumpMut()` (so search caches self-invalidate). Underscore `_name/_path`
  are non-locking internals — call them only while holding the lock.
- Keep huge-result-set performance: visible-row-only work; one `reloadData()` per batch.
- Keep `mvsim` at 100% green; grow it with each feature. `swift build -c release` must stay green
  (the driver auto-reverts a red turn).
- Prefer `## TURN: BLOCKED` + a crisp question over guessing on irreversible choices.

## NEXT
CODEX: **OPEN QUESTION 2A (non-ASCII case-folding fold blob)** — self-contained. Add a
Unicode-lowercased fold blob with its OWN offsets (`foldOff`/`foldLen`) since Unicode
lowercasing can change byte length; keep the ASCII-only `foldBlob` fast path for pure-ASCII
names (skip building a Unicode variant when the name is ASCII). Fold the QUERY the same way,
and route name matching to the Unicode blob only when the query contains non-ASCII (or always,
if cheap). Add mvsim: `CAFÉ.txt` findable via `café` AND `cafe`; ASCII fast path unchanged;
Korean (caseless) unaffected. Watch: `nameOff`/`nameLen` are UInt32/UInt16 — a parallel
Unicode blob needs its own offset widths and must be kept in lock-step through
appendRoot/appendChildren/_appendOne/clear/snapshot (and bump mutationGen under wrlock).
Then AGY: **3 (relevance top-K, bounded per-chunk selection)**. Then CLAUDE loops back for
**4 (dynamic mounts)** + the UInt32 4 GiB name-blob cap + mvsim growth + cross-review.

Red-team for CODEX: verify `computePathOrder` holds the read lock via `orderArray`→`computeOrder`
(no self-locking), reconstructs paths String-free (`foldedPathBytes`), and is cached — no eager
per-row path building. Confirm the `.path` order truncates deep paths gracefully (8192 scratch /
4096 stack) rather than crashing.
