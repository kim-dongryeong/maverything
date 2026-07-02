## TURN: CLAUDE
**Updated:** 2026-07-02 21:00

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
  `foldBlob` = asciiLower(NFC) sharing nameOff/nameLen; `unicodeFoldBlob` has independent
  UInt64/UInt32 offsets for non-ASCII case/diacritic-insensitive search), `FileEnumerator`
  (getattrlistbulk crawl), `Watcher` (FSWatcher + Reconciler), `Snapshot`, `Volumes`,
  `Matching`, `QueryParser`.
- App `Sources/Maverything/`: `AppModel`, `ResultsTableView`, `CompactResults`, `PreviewPane`,
  `ContentView`, `FilterBar`, `SearchMenus`, `OptionsButton`, `Settings`.
- Harness: `.build/release/mvsim` (75 scenarios → must stay 100% green), `mvfind` CLI, `mvtest`.
- Build: `swift build -c release`. Sim: `.build/release/mvsim`.

## OPEN QUESTIONS  (→ build ALL options, switchable; never choose for the user)
1. **Real Path-column sort** — ✅ DONE (1A, commit 64e4ffb). `computeOrder(.path)` →
   `computePathOrder()`: reconstructs each live entry's folded path once into a packed
   blob, argsorts by path bytes (UInt64-prefix + memcmp tie-break), cached in
   `orderCache[.path]` keyed on mutationGen. Both fastExact + general honor it. mvsim +4.
   - B) Directory-order tuple keys (parent order, then name) for cheaper rebuilds remains
     an OPTIONAL perf variant — SAME output order as 1A, so purely a rebuild-cost trade;
     defer unless path-sort rebuild shows up hot in mvtest (not user-visible, not urgent).
2. **Non-ASCII case folding** — ✅ DONE (2A, CODEX turn). Added `unicodeFoldBlob`
   with independent `unicodeFoldOff`/`unicodeFoldLen` for non-ASCII names; pure-ASCII
   names keep the existing ASCII `foldBlob` fast path and store a sentinel instead of
   duplicate Unicode bytes. Query terms use the same NFC + case/diacritic-insensitive
   fold, so `CAFÉ.txt` is found by `café` and `cafe`; path-scope search and snapshot
   v4 round-trip are covered. mvsim +5 (66→71).
3. **Relevance sort top-K** — ✅ DONE (AGY turn). Added per-chunk bounded top-K
   with dynamic sort/prune when the array exceeds `limit + max(512, limit)`. Combines
   and merges across workers, returning identical results with minimal allocation.
   mvsim +4 (71→75).
4. **Dynamic mount/unmount** — volumes mounted AFTER launch aren't indexed/watched; unmounts
   leave stale entries. Observe `NSWorkspace.shared.notificationCenter` didMount/didUnmount:
   on mount → crawl+watch the new root; on unmount → tombstone that subtree. (Also handle
   FSEvents RootChanged.)

## DONE-WHEN
- [x] Path-column sort yields true path order (not name order); mvsim asserts it. (64e4ffb)
- [x] Non-ASCII case folding: `CAFÉ` findable via `café`/`cafe`; ASCII fast path intact; mvsim asserts.
- [x] Relevance sort uses bounded top-K (no full-set sort); results unchanged; mvsim still green.
- [ ] Mount after launch is indexed+watched; unmount tombstones the volume (best-effort test/log).
- [ ] Name-blob offsets widened past the 4 GiB `UInt32` cap (UInt64 or segmented) — or a guarded graceful cap.
- [x] mvsim grown by ≥4 scenarios (path-sort, non-ASCII fold, relevance top-K parity, …) — 100% green.
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
CLAUDE: implement **OPEN QUESTION 4 (dynamic mounts)**: volumes mounted AFTER launch
aren't indexed/watched; unmounts leave stale entries. Observe `NSWorkspace.shared.notificationCenter` didMount/didUnmount:
on mount → crawl+watch the new root; on unmount → tombstone that subtree. Also handle
FSEvents RootChanged.
Then address the UInt32 4 GiB name-blob cap + remaining cross-reviews.

