## TURN: CLAUDE
**Updated:** 2026-06-30 01:30

## GOAL
Milestone **L3 — power features + performance + hardening** for Maverything. The app now
has: 3 match modes (exact/fuzzy/wildcard), Everything-style query syntax, relevance sort,
3 switchable layouts (table / compact bar / two-pane QuickLook preview), themes + density,
icons + Kind column. Engine validated by `mvsim` (34/34) and the `mvfind` CLI. This batch
adds the remaining power + speed, cross-reviews what landed, and grows the sim suite.
Rule still in force: when a choice has options A/B/C, build them ALL, switchable.

## CODEBASE MAP
- Engine: `Sources/MaverythingCore/` — `SearchEngine` (fast exact path + general evaluator;
  `orderArray` cache invalidated by `invalidate()`), `Matching.swift` (`MatchMode`),
  `QueryParser.swift`, `FileIndex` (SoA + live deltas + NFC), `Watcher`, `Snapshot`, `Volumes`.
- App: `ContentView` (search bar, gear menu, `layoutBody` switch, `shortcuts`),
  `ResultsTableView` (table), `CompactResults` (bar), `PreviewPane` (QuickLook), `UILayout.swift`
  (UILayout/Appearance/RowDensity), `AppModel` (state + query pipeline + watcher + snapshot).
- Harness: `mvsim` (scenarios → SIMULATION-REPORT.md), `mvtest` (perf on /usr), `mvfind` (CLI).
- Build: `swift build -c release`. Run app: `./build.sh run`. Sim: `.build/release/mvsim`.

## OPEN QUESTIONS  (→ build ALL options, switchable; never choose for the user)
1. **More match modes** — add to `MatchMode` (keep exact/fuzzy/wildcard):
   - D) **Regex** (`NSRegularExpression`, case-insensitive by default) — match name (or path).
     Compile once; only run on candidates surviving cheap filters; guard pathological patterns.
   - (optional) **Word/prefix-boundary** boosted exact (rank whole-word/prefix hits higher).
2. **Performance (the #1 user goal is "instant")** — pick the wins and implement what's safe:
   - Prewarm ALL sort orders (name/size/date) in the background after index-ready (not just name).
   - Reduce the per-keystroke first-build cost on ~4M: faster name argsort (e.g. radix on the
     first 4–8 bytes then memcmp tiebreak), or incremental order maintenance so a live FS delta
     doesn't force a full re-sort. Measure with `mvtest` before/after; quote numbers.
   - Don't rebuild the order when the search field is empty or the window is hidden.
3. **Keyboard UX across layouts** — ↑/↓ move selection, ⏎ opens, ⌘⏎ reveals, in the compact bar
   and two-pane (table already handles arrows). Esc clears then hides (already in ContentView).

## DONE-WHEN
- [ ] Regex match mode implemented + selectable; safe on big sets (filter-first, guarded).
- [ ] All sort orders prewarmed off the main thread; empty-query/hidden-window skips rebuilds.
- [ ] A measured name-sort or incremental-order improvement (mvtest numbers in the worklog).
- [ ] Keyboard nav (↑/↓/⏎/⌘⏎) works in compact + two-pane layouts.
- [ ] `mvsim` grown by ≥6 scenarios (regex, wildcard `?`, size ranges, dm ranges, NFC Korean,
      snapshot resume, NOT+filters combo) — still 100% green.
- [ ] Adversarially review the L2 UI + engine commits on main (red-team: lock discipline in any
      engine edit, no eager per-row work in layouts, no regressions) — note findings in worklog.
- [ ] build green · existing flows intact · no secrets · clean tree.

## CONSTRAINTS
- Only edit files under this repo/worktree. NEVER `git push`. One focused increment per turn.
- Respect index lock discipline (search under `withReadLock`; `_name`/`_path` when locked).
- Keep huge-result-set performance: visible-row-only work; `reloadData()` once per batch.
- Prefer `## TURN: BLOCKED` + a crisp question over guessing on irreversible choices.

## NEXT
CLAUDE: design round — decide the perf approach (prewarm-all + skip-when-idle is the safe
floor; radix name-sort is the stretch) and land increment 1 (prewarm all orders in background +
skip rebuild on empty/hidden). Hand to CODEX for the Regex match mode, then AGY for keyboard nav
across layouts. Loop back for the perf stretch + the mvsim growth + the L2 cross-review.
