## TURN: CLAUDE
**Updated:** 2026-06-30 01:00

## GOAL
Milestone **L2 — UI layout variants + result polish** for Maverything. The engine now
has 3 matching modes (exact/fuzzy/wildcard), an Everything-style query parser
(ext/size/dm/path/name/NOT/quotes), and a relevance sort — all landed on main and
validated by `mvsim` (34/34). This milestone is **all about the UI**: build **multiple
window layouts the human can switch between live and pick a favorite** (the explicit rule:
when there are options A/B/C, build them ALL, switchable — never choose for the user).

## CODEBASE MAP
- `Sources/Maverything/MaverythingApp.swift` — `@main`; SwiftUI `Window` + `MenuBarExtra`;
  `AppDelegate` owns the global ⌥Space hotkey + `WindowConfigurator` (floating panel look).
- `Sources/Maverything/ContentView.swift` — search bar (mode picker, gear menu), status bar.
- `Sources/Maverything/ResultsTableView.swift` — AppKit `NSTableView` grid (Name/Path/Size/Date),
  sortable, context menu (Open/Reveal/Copy Path), double-click open.
- `Sources/Maverything/AppModel.swift` — `@Published` query/matchMode/scope/sortKey/results;
  `resultsStore.ids`, `resultsVersion`. Resolve a row via `model.name/path/directory(id)`.
- Engine (do not need to change): `Sources/MaverythingCore/*` — `SearchEngine.search(query,
  mode:scope:sortKey:ascending:limit:now:)`, `MatchMode`, `SortKey` (incl `.relevance`).
- Build: `swift build -c release`. Run the app: `./build.sh run`.

## OPEN QUESTIONS  (→ build ALL options, switchable; do not choose for the user)
1. **Window layouts** — implement all three behind a `Layout` enum the user switches live
   (gear menu + ⌘1/⌘2/⌘3). Persist the choice in `UserDefaults`.
   - A) **Compact "Spotlight bar"**: a narrow centered bar; results appear in a slim dropdown
     list (name + path, ~8–12 rows) below the field. Esc hides. Alfred/Spotlight feel.
   - B) **Full window table** (current `ResultsTableView`) — keep as a layout option.
   - C) **Two-pane + preview**: results table on the left, a detail pane on the right showing
     the selected file's QuickLook thumbnail (`QLThumbnailGenerator`) + metadata (full path,
     size, dates, kind). Selection-driven.
2. **Row polish (applies to table layouts)** — add a file **icon** (`NSWorkspace.shared.icon(forFile:)`,
   cached) and a **Kind** column (UTType/`localizedDescription`), lazily resolved for visible rows only.
3. **Theme** — offer at least 2 appearances (e.g. System, and a dark "pro" high-contrast),
   switchable in the gear menu. (If quick, add a compact/comfortable row-density toggle too.)

## DONE-WHEN
- [ ] `Layout` enum with all three layouts (A compact bar, B table, C two-pane preview); live switch + ⌘1/2/3; persisted.
- [ ] Two-pane preview shows QuickLook thumbnail + metadata for the selected row.
- [ ] File icons + Kind column in the table layouts (lazy, visible-rows-only, cached).
- [ ] At least two switchable themes/appearances.
- [ ] Each layout keeps search-as-you-type, ⌃U scope, mode switch, and column sort working.
- [ ] Adversarially review the engine changes on main (run `mvsim`; add ≥4 new scenarios — e.g.
      wildcard `?`, `size:` ranges, `dm:` ranges, NFC Korean) and confirm still 100% green.
- [ ] build green (`swift build -c release`) · existing flows intact · no secrets · clean tree.

## CONSTRAINTS
- Only edit files under this repo/worktree. NEVER `git push`. One focused increment per turn.
- Prefer NEW files for new layouts (e.g. `CompactLayout.swift`, `PreviewPane.swift`) to keep
  diffs reviewable. Don't regress the working table layout (it is layout B).
- Keep the huge-result-set performance: visible-row-only work; no eager per-row icon/thumbnail
  for all rows; `reloadData()` once per result batch.
- Respect index lock discipline if you touch the engine. Prefer `## TURN: BLOCKED` + a crisp
  question over guessing on irreversible choices.

## NEXT
CLAUDE: design round — sketch the `Layout` enum + how `ContentView` swaps subviews and persists
the choice; then land increment 1 (the `Layout` enum, gear-menu switcher, ⌘1/2/3, and layout B
wired through it with no behavior change). Hand to CODEX for the compact Spotlight-bar layout (A),
then AGY for the two-pane QuickLook preview (C) + icons/Kind column. Loop back for themes + the
mvsim cross-review.
