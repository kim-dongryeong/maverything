## TURN: CLAUDE
**Updated:** 2026-06-30 00:40

## GOAL
Milestone **L1 — Search power + matching-mode variants** for Maverything (a macOS
voidtools-Everything clone, pure Swift). Add Everything-style query syntax AND build
**multiple matching/ranking modes the user can switch between live** — so the human can
test each and pick favorites. This is the explicit instruction: when a choice has options
A/B/C, **build them all and make them switchable**, never pick one silently.

## CODEBASE MAP
- `Sources/MaverythingCore/SearchEngine.swift` — the search. Today: multi-core `memmem`
  exact substring over `index.foldBlob`, scanned in a cached argsort order (`orderArray`),
  top-K, name/size/date sort. `search(query, scope, sortKey, ascending, limit)`.
- `Sources/MaverythingCore/FileIndex.swift` — struct-of-arrays index (nameBlob/foldBlob,
  nameOff/nameLen, parent, size, mtime, objType, flags, hidden, deleted). `path(i)`, `name(i)`.
- `Sources/MaverythingCore/{FileEnumerator,Watcher,Snapshot,Volumes,Permissions}.swift`.
- `Sources/Maverything/` — app: `AppModel` (query pipeline, `scope`, `sortKey`), `ContentView`
  (search bar, ⌃U scope toggle, gear menu), `ResultsTableView` (NSTableView).
- `Sources/mvtest/main.swift` — headless engine harness (run: `swift build -c release && .build/release/mvtest /usr png`).
- Build: `swift build -c release`. Keep the index lock discipline: search runs inside
  `index.withReadLock`; use `_name`/`_path` (non-locking) when the lock is held.

## OPEN QUESTIONS  (→ build ALL options, switchable; do not choose for the user)
1. **Matching modes** — implement all three behind a `MatchMode` enum the UI switches live:
   - A) **Exact substring** (current behavior) — keep as the baseline.
   - B) **Fuzzy subsequence** (fzf/Sublime style): all needle chars in order, scored
     (consecutive + word-boundary + camelCase + path-depth bonuses), ranked by score.
   - C) **Wildcard/glob**: `*` and `?` honored; whole-name match semantics like Everything.
   Add a `MatchMode` segmented control (or gear submenu) in `ContentView`; wire through
   `AppModel` → `SearchEngine.search`. Default = Exact.
2. **Query syntax** (Everything-style; parse in a new `QueryParser`):
   - space = AND of terms; `"quoted phrase"`; leading `!`/`-` = NOT a term.
   - filters: `ext:swift`, `size:>1mb` / `size:<10k`, `dm:today` / `dm:>2026-01-01`,
     `path:foo` (match path), `name:foo` (match name), `case:` (case-sensitive this query).
   - Build it so unknown tokens fall back to a plain substring term (never error).
3. **Ranking when sortKey = .name** — offer a `.relevance` sort option too (match position /
   fuzzy score / shorter-path-first). Add `.relevance` to `SortKey` and the column/menu.

## DONE-WHEN
- [ ] `MatchMode` enum (exact/fuzzy/wildcard) implemented in the engine; all three work.
- [ ] `QueryParser` parses terms + filters (ext/size/dm/path/name/quotes/NOT) with substring fallback.
- [ ] `SortKey.relevance` added and selectable; results ranked sensibly per mode.
- [ ] UI: a live mode switcher + the new sort option; ⌃U path scope still works.
- [ ] `mvtest` extended with cases proving each mode + a few filters (printed PASS/FAIL).
- [ ] build green (`swift build -c release`) · existing search/sort/watch flows intact · no secrets · clean tree.

## CONSTRAINTS
- Only edit files under this repo/worktree. NEVER `git push`. One focused increment per turn.
- Do NOT regress current behavior (exact substring must stay the default and work).
- Respect the index lock discipline (search under `withReadLock`; `_name`/`_path` when locked).
- Avoid editing `Package.swift` unless you must add a target; if you do, keep it minimal.
- Prefer `## TURN: BLOCKED` + a crisp question over guessing on anything irreversible.

## NEXT
CLAUDE: design round — in worklog, sketch the `MatchMode` enum + `QueryParser` shape and
the engine dispatch, then land increment 1 (the `MatchMode` enum + a `FuzzyMatcher` that
compiles and is unit-exercised in `mvtest`). Hand to CODEX to add the wildcard mode +
QueryParser, then AGY to wire the UI switcher + relevance sort.
