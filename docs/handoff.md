## TURN: CLAUDE
**Updated:** 2026-07-02 20:15

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
  regexSearch; orderCache keyed on `index.mutationGenLocked`; incremental narrowing),
  `FileIndex` (struct-of-arrays + rwlock rdlock()/wrlock(); `computeOrder` per SortKey;
  `foldBlob` = asciiLower(NFC) sharing nameOff/nameLen), `FileEnumerator` (getattrlistbulk
  crawl), `Watcher` (FSWatcher + Reconciler), `Snapshot`, `Volumes`, `Matching`, `QueryParser`.
- App `Sources/Maverything/`: `AppModel`, `ResultsTableView`, `CompactResults`, `PreviewPane`,
  `ContentView`, `FilterBar`, `SearchMenus`, `OptionsButton`, `Settings`.
- Harness: `.build/release/mvsim` (62 scenarios → must stay 100% green), `mvfind` CLI, `mvtest`.
- Build: `swift build -c release`. Sim: `.build/release/mvsim`.

## OPEN QUESTIONS  (→ build ALL options, switchable; never choose for the user)
1. **Real Path-column sort** — today `computeOrder(.path)` falls back to NAME order, so
   clicking the "Path" header sorts by name (wrong). Options:
   - A) Reconstruct each entry's folded path once, sort by it, cache in `orderCache[.path]`
     (simple, ~1s to build once, cached like other orders). ← safe floor, implement first.
   - B) Directory-order tuple keys (parent order, then name) for cheaper rebuilds.
   Assert correctness in mvsim (a nested fixture where path order ≠ name order).
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
- [ ] Path-column sort yields true path order (not name order); mvsim asserts it.
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
CLAUDE: start with **OPEN QUESTION 1A (real Path-column sort)** — self-contained, clear win.
Add `computeOrder(.path)` that sorts by reconstructed folded path (cache it), and an mvsim
scenario where path order ≠ name order. Then hand to CODEX for **2A (non-ASCII fold blob)**,
then AGY for **3 (relevance top-K)**. Loop back for **4 (dynamic mounts)** + mvsim growth +
cross-review.
