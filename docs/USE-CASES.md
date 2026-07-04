# Maverything — Use Cases & Verification Map

Real user scenarios for the three Cling-inspired features (character bloom prefilter,
Run Count / frecency, live socket + `mvfind`), each mapped to the **automated check**
that guards it. "mvsim: `<name>`" is a scenario in `Sources/mvsim/main.swift` (run
`swift run -c release mvsim`); "CLI" is a real `mvfind` command you can run yourself
while the app is open.

---

## 1. Character bloom prefilter — fast fuzzy & first-keystroke search

The engine keeps a per-file bloom of which characters a name contains, and rejects a
candidate before the byte scan when it can't possibly match. Biggest win: fuzzy mode
and the cold first query.

| # | Scenario | What the user does | Verified by |
|---|----------|--------------------|-------------|
| 1.1 | Fuzzy find is instant | Switch to Fuzzy, type `xcode` over 1.9M files | measured 26.9 ms → **1.5 ms** (`MVFIND_BENCH`); mvsim: `bloom: mask rejects non-matching candidates` |
| 1.2 | No result is ever lost | Any query in any mode returns exactly what a full scan would | mvsim: `bloom A/B: gated results == brute scan across all query shapes` (35 shapes incl. exact/fuzzy/wildcard/regex, case:on, café/한글, OR, negation, path, affix) |
| 1.3 | Diacritics still match | Search `cafe` finds `café_menu.txt` | mvsim: `bloom A/B` (café row) + `live: reconcile-inserted diacritic name found` |
| 1.4 | Case-sensitive search is correct | `case:on Report` finds `Report`, not `report` | mvsim: `bloom A/B` (case:on rows) |
| 1.5 | Newly-created files are searchable immediately | Save a file; it's findable before any reindex | mvsim: `live: reconcile-inserted … found (mask path)` |

CLI: `MVFIND_BENCH=5 mvfind 'report' --fuzzy` (bloom on) vs `MVFIND_BENCH=5 MVFIND_NOBLOOM=1 mvfind 'report' --fuzzy` (off) — same match count, ~6× slower off.

---

## 2. Run Count / frecency — "the file I open every day is on top"

Every time you open a result its run count + last-open time are recorded; sort by Run
Count (⌃7) floats the most-run to the top, and Relevance gets a frecency boost.

| # | Scenario | What the user does | Verified by |
|---|----------|--------------------|-------------|
| 2.1 | Daily file ranks first | Open `budget.xlsx` often → sort by Run Count | mvsim: `runcount: most-run file is first`, `second-most-run is second` |
| 2.2 | Never-opened files still show, in name order | The tail below your tracked files stays a→z | mvsim: `runcount: untracked files keep name order after tracked` |
| 2.3 | A most-run file that sorts last isn't dropped | Hide hidden + small window + run-count sort | mvsim: `runcount: alphabetically-last most-run file survives a small limit`, `… survives limit + hideHidden together` |
| 2.4 | Run Count never adds/drops results | Same set as a name sort, just reordered | mvsim: `runcount: same result set as name sort (no drops/dupes)` |
| 2.5 | Best Match blends quality + habit | Sort by Relevance; a much-opened file lifts | mvsim: `relevance: frecency boost lifts the most-run file` |
| 2.6 | Recency matters, not just count | A file opened 3× today can outrank one opened 10× last month | mvsim: `frecency: recent few can outrank stale many (decay works)` |
| 2.7 | History is bounded | Thousands of opens don't grow unbounded | mvsim: `runstats: cap prunes to size, keeps highest frecency` |
| 2.8 | Clear history | Settings ▸ Clear Run History | mvsim: `runstats: clear resets to plain name order` |
| 2.9 | Survives reindex | Run counts persist though entry ids churn | mvsim: `runstats: resolveIds maps real paths to ids` (path-keyed) |

CLI: `mvfind 'report' --sort runcount` (reads the same `runstats.json` the app writes).

---

## 3. Live socket + `mvfind` — real-time search from the terminal / scripts / AI

The running app serves its live index over a Unix socket; `mvfind` queries it first
(real-time), falling back to the saved snapshot when the app is closed. Same socket is
the backend for a future MCP bridge.

| # | Scenario | What the user does | Verified by |
|---|----------|--------------------|-------------|
| 3.1 | Terminal search matches the app | `mvfind report ext:pdf` from a script | mvsim: `queryserver: valid query returns matching paths + meta` |
| 3.2 | Live, not stale | Create a file, `mvfind` finds it without the app resaving | app serves the live index (source label `live`); mvsim exercises the same engine |
| 3.3 | Count for scripting | `mvfind '*.log' --count` | mvsim: `queryserver: countOnly returns total without paths` |
| 3.4 | Structured output for tools/AI | `mvfind report --json` → `{path,name,size,mtime,isDir}` | mvsim: `queryserver: fields=[…] returns structured rows` |
| 3.5 | Works offline (app closed) | `mvfind` falls back to the snapshot | mvfind socket-first → snapshot; source label `snapshot` |
| 3.6 | A crashing/hanging client can't take down the app | Client hangs up mid-response | mvsim: `queryserver: client hang-up before read does NOT kill the server (SIGPIPE ignored)` |
| 3.7 | Only you can query | Another user's process is refused | `getpeereid` same-uid check; 0700 dir + 0600 socket |
| 3.8 | Bad input can't crash the server | Malformed JSON | mvsim: `queryserver: malformed request → ok:false with error` |
| 3.9 | Concurrent callers | Two tools query at once | mvsim: `queryserver: concurrent connections both answered` |
| 3.10 | Survives app restart | Relaunch leaves no stale-socket wreckage | mvsim: `queryserver: restart rebinds cleanly over a leftover socket file` |

CLI: `mvfind 'xcode' --live` (force socket), `mvfind 'xcode' --snapshot` (force file), `mvfind 'report' --json --live`.

---

## Running the checks

```bash
swift run -c release mvsim          # all 174 scenarios (this doc's "mvsim:" rows)
MVFIND_BENCH=5 mvfind 'swift' --fuzzy         # warm fuzzy latency (bloom on)
MVFIND_BENCH=5 MVFIND_NOBLOOM=1 mvfind 'swift' --fuzzy   # baseline (bloom off)
mvfind 'report' --sort runcount --live        # live run-count sort over the socket
```
