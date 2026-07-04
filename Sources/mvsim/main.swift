import Darwin
import Foundation
import MaverythingCore

// Maverything simulation / use-case harness. Builds a synthetic file tree, then
// drives the engine through realistic scenarios (every match mode, filters, sort,
// scope, live add/delete/modify, snapshot) asserting PASS/FAIL, plus a latency
// pass. Writes SIMULATION-REPORT.md. Run: swift run -c release mvsim

let now = Date().timeIntervalSince1970
let root = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
            : NSTemporaryDirectory() + "mvsim-tree-\(getpid())")
let dynamicRoot = NSTemporaryDirectory() + "mvsim-dynamic-volume-\(getpid())"
let fm = FileManager.default
try? fm.removeItem(atPath: root)
try? fm.removeItem(atPath: dynamicRoot)

// ---- tree builders ----
func mkdir(_ p: String) { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
func write(_ rel: String, bytes: Int = 16, mtime: TimeInterval? = nil) {
    let p = root + "/" + rel
    mkdir((p as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: p, contents: Data(count: bytes))
    if let m = mtime {
        var tv = [timeval(tv_sec: Int(m), tv_usec: 0), timeval(tv_sec: Int(m), tv_usec: 0)]
        _ = utimes(p, &tv)
    }
}
func writeAbs(_ p: String, bytes: Int = 16, mtime: TimeInterval? = nil) {
    mkdir((p as NSString).deletingLastPathComponent)
    FileManager.default.createFile(atPath: p, contents: Data(count: bytes))
    if let m = mtime {
        var tv = [timeval(tv_sec: Int(m), tv_usec: 0), timeval(tv_sec: Int(m), tv_usec: 0)]
        _ = utimes(p, &tv)
    }
}

let oldTime = now - 200 * 86_400   // ~200 days ago
write("report.txt", bytes: 200, mtime: now)
write("reporting_x.txt", bytes: 4)                     // whole-word (ww:) negative case
write("star*name.txt", bytes: 4)
write("pkgtest.bundle/inner.bin", bytes: 3)              // package DIR — Finder treats as a file                       // literal * in a real filename
write("dupA/twin_name.txt", bytes: 6)                 // dupe: fixture (same name, two dirs)
write("dupB/twin_name.txt", bytes: 7)
write("Report.PNG", bytes: 300, mtime: oldTime)        // case-insensitivity
write("notes.md", bytes: 50)
write("README.md", bytes: 80)
write("app.swift", bytes: 120)
write("AppModel.swift", bytes: 400)                    // fuzzy "amdl"
write("QueryParser.swift", bytes: 400)
for i in 1...20 { write(String(format: "img/image_%03d.png", i), bytes: 100, mtime: i <= 3 ? now : oldTime) }
write("data/data.json", bytes: 1_048_576)              // exactly 1 MB
write("data/big.bin", bytes: 5 * 1_048_576, mtime: oldTime)
write("data/tiny.txt", bytes: 10)
write("intl/한글파일.txt", bytes: 30)                   // unicode
write("intl/café.md", bytes: 30)
write("intl/CAFÉ.txt", bytes: 30)
write("src/a/b/c/d/leaf.txt", bytes: 5)                // deep nesting
write(".hidden/.secret.txt", bytes: 5)                 // hidden
// path-column sort fixture (OQ1A): basename order and full-path order DISAGREE here —
// by name apple<zebra, but by path adir/…<zdir/…, so the two files swap order.
write("zdir/marker_apple.txt", bytes: 8)
write("adir/marker_zebra.txt", bytes: 8)
mkdir(root + "/emptydir")                              // empty: fixture (dir with no children)

// ---- index ----
let index = FileIndex()
let stats = FileEnumerator(index: index).crawl(roots: [root])
index.buildLiveIndexes()
let engine = SearchEngine(index: index)

// ---- assertion plumbing ----
struct Case { let name: String; let pass: Bool; let detail: String }
var cases: [Case] = []
func check(_ name: String, _ pass: Bool, _ detail: String = "") {
    cases.append(Case(name: name, pass: pass, detail: detail))
    print("\(pass ? "✓" : "✗ FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
}
func names(_ q: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly,
           sort: SortKey = .name) -> [String] {
    engine.search(q, mode: mode, scope: scope, sortKey: sort, limit: 10_000, now: now)
        .ids.map { index.name(Int($0)) }
}
func has(_ q: String, _ name: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly) -> Bool {
    names(q, mode: mode, scope: scope).contains(name)
}

print("=== Maverything simulation — \(index.count) entries from \(root) ===")
print(String(format: "crawl: %d items in %.3fs\n", stats.total, stats.seconds))

// ---- scenarios ----
// exact substring + case-insensitivity
check("exact: 'report' finds report.txt", has("report", "report.txt"))
check("exact: case-insensitive 'report' finds Report.PNG", has("report", "Report.PNG"))
check("exact: 'png' finds image_001.png", has("png", "image_001.png"))
check("exact: no-match returns empty", names("zzzznotexist").isEmpty)

// fuzzy
check("fuzzy: 'amdl' finds AppModel.swift", has("amdl", "AppModel.swift", mode: .fuzzy))
check("fuzzy: 'qps' finds QueryParser.swift", has("qps", "QueryParser.swift", mode: .fuzzy))
check("fuzzy: subseq only (no 'xyz')", !has("xqz", "AppModel.swift", mode: .fuzzy))

// wildcard (anchored whole name)
check("wildcard: '*.png' matches image_001.png", has("*.png", "image_001.png", mode: .wildcard))
check("wildcard: '*.png' excludes report.txt", !has("*.png", "report.txt", mode: .wildcard))
check("wildcard: 'report*' matches report.txt", has("report*", "report.txt", mode: .wildcard))
check("wildcard: '?eport.txt' matches report.txt", has("?eport.txt", "report.txt", mode: .wildcard))

// filters
check("filter: 'ext:png' → 20 images + Report.PNG = 21", names("ext:png").count == 21,
      "got \(names("ext:png").count)")
check("filter: 'ext:swift' includes AppModel.swift", has("ext:swift", "AppModel.swift"))
check("filter: 'size:>1mb' finds big.bin", has("size:>1mb", "big.bin"))
check("filter: 'size:>1mb' excludes tiny.txt", !has("size:>1mb", "tiny.txt"))
check("filter: 'size:<20' finds tiny.txt(10) and leaf.txt(5)",
      has("size:<20", "tiny.txt") && has("size:<20", "leaf.txt"))
check("filter: 'dm:today' finds report.txt(now)", has("dm:today", "report.txt"))
check("filter: 'dm:today' excludes big.bin(old)", !has("dm:today", "big.bin"))
check("filter: combined 'image ext:png dm:today' → only fresh images",
      names("image ext:png dm:today").count == 3, "got \(names("image ext:png dm:today").count)")

// multi-term AND + NOT + quotes
check("AND: 'app swift' finds AppModel.swift", has("app swift", "AppModel.swift"))
check("NOT: 'report -png' finds report.txt", has("report -png", "report.txt"))
check("NOT: 'report -png' excludes Report.PNG", !has("report -png", "Report.PNG"))
check("phrase: '\"image_0\"' matches images", has("\"image_0\"", "image_001.png"))

// OR (`|`) — a token splits into an OR-group; space is still AND
check("OR: 'report|notes' matches report.txt AND notes.md",
      has("report|notes", "report.txt") && has("report|notes", "notes.md"))
check("OR: dead alternative 'app|nonexistentzz' still finds app.swift",
      has("app|nonexistentzz", "app.swift"))
check("OR+filter: 'report|notes ext:md' → notes.md only",
      has("report|notes ext:md", "notes.md") && !has("report|notes ext:md", "report.txt"))
check("OR-negated: '-md|txt' excludes notes.md and report.txt, keeps image_001.png",
      !has("-md|txt", "notes.md") && !has("-md|txt", "report.txt") && has("-md|txt", "image_001.png"))
check("OR+AND: 'swift app|model' finds AppModel.swift",
      has("swift app|model", "AppModel.swift"))
check("OR: scope prefix applies to whole group — 'path:img|data' finds both via path",
      has("path:img|data", "image_001.png") && has("path:img|data", "data.json"))

// scope
check("path: 'path:data' finds data.json via path", has("data", "data.json", scope: .fullPath))
check("name: plain term ignores parent dir name", !has("data", "leaf.txt"))

// unicode (ASCII-fold leaves non-ASCII intact; substring still works)
check("unicode: '한글' finds 한글파일.txt", has("한글", "한글파일.txt"))
check("unicode-fold: 'café' finds CAFÉ.txt", has("café", "CAFÉ.txt"))
check("unicode-fold: 'cafe' finds CAFÉ.txt", has("cafe", "CAFÉ.txt"))
check("unicode-fold: uppercase accented query finds café.md", has("CAFÉ", "café.md"))
check("unicode-fold: path:cafe finds CAFÉ.txt via folded path", has("path:cafe", "CAFÉ.txt"))

// relevance sort sanity (fuzzy: exact-ish beats scattered)
let rel = engine.search("app", mode: .fuzzy, sortKey: .relevance, limit: 10, now: now).ids.map { index.name(Int($0)) }
check("relevance: 'app' ranks app.swift/AppModel.swift on top",
      rel.prefix(2).contains("app.swift") || rel.prefix(2).contains("AppModel.swift"), rel.prefix(3).joined(separator: ","))

// relevance top-K parity checks
let relFull = engine.search("app", mode: .fuzzy, sortKey: .relevance, limit: 1000, now: now).ids
let relLimit1 = engine.search("app", mode: .fuzzy, sortKey: .relevance, limit: 1, now: now).ids
check("relevance top-K: limit 1 matches first of full search",
      relLimit1.first == relFull.first)

let relAscending = engine.search("app", mode: .fuzzy, sortKey: .relevance, ascending: true, limit: 1000, now: now).ids
let relAscLimit2 = engine.search("app", mode: .fuzzy, sortKey: .relevance, ascending: true, limit: 2, now: now).ids
check("relevance top-K: ascending limit 2 matches prefix of ascending full",
      Array(relAscending.prefix(2)) == relAscLimit2)

let relDescFull = engine.search("app", mode: .fuzzy, sortKey: .relevance, ascending: false, limit: 1000, now: now).ids
let relDescLimit3 = engine.search("app", mode: .fuzzy, sortKey: .relevance, ascending: false, limit: 3, now: now).ids
check("relevance top-K: descending limit 3 matches prefix of descending full",
      Array(relDescFull.prefix(3)) == relDescLimit3)

let relAllLimitMatches = (1...min(5, relFull.count)).allSatisfy { lim in
    let limIds = engine.search("app", mode: .fuzzy, sortKey: .relevance, limit: lim, now: now).ids
    return limIds == Array(relFull.prefix(lim))
}
check("relevance top-K: any limit matches prefix of full search", relAllLimitMatches)

// path-column sort (OQ1A): the "Path" header must sort by true folded full path,
// NOT by basename. The fixture is built so the two orders provably disagree.
let byName = names("marker", sort: .name)
let byPath = names("marker", sort: .path)              // exact single-term → fastExact + orderArray(.path)
check("path-sort: name order is [apple, zebra]",
      byName == ["marker_apple.txt", "marker_zebra.txt"], byName.joined(separator: ","))
check("path-sort: path order is [zebra, apple] (adir < zdir)",
      byPath == ["marker_zebra.txt", "marker_apple.txt"], byPath.joined(separator: ","))
check("path-sort: path order differs from name order", byName != byPath)
let byPathGeneral = names("marker ext:txt", sort: .path)   // filter present → general evaluator path
check("path-sort: general evaluator honors path order too",
      byPathGeneral == ["marker_zebra.txt", "marker_apple.txt"], byPathGeneral.joined(separator: ","))

// negated filters (review #2)
check("NOT-filter: '-ext:png' excludes images", !has("image -ext:png", "image_001.png"))
check("NOT-filter: '-ext:png' keeps AppModel.swift", has("app -ext:png", "AppModel.swift"))
check("NOT-filter: '-size:>1mb' excludes big.bin", !has("-size:>1mb", "big.bin"))
check("NOT-filter: '-dm:today' excludes today's report.txt", !has("report -dm:today", "report.txt"))
// ext with leading dot (review #4)
check("ext '.png' (leading dot) still matches", has("ext:.png", "image_001.png"))
// name: forces name scope even conceptually (review #3) — name:data shouldn't match by path
check("name: term matches filename", has("name:data", "data.json"))

// type filters (folder: / file:) — power the quick type chips
check("folder: matches the 'data' directory", has("folder:data", "data"))
check("folder: excludes a plain file", !has("folder:", "report.txt"))
check("file: matches report.txt", has("file:report", "report.txt"))
check("file: excludes the 'data' directory", !has("file:", "data"))
check("-folder: (files only) excludes the 'data' directory", !has("-folder:", "data"))
// review#2: negated type filter with a value must not be always-empty or a positive term
let folderExclData = Set(engine.search("folder: -folder:data", limit: 10_000, now: now).ids.map { index.name(Int($0)) })
check("type: 'folder: -folder:data' → dirs excluding 'data' (not empty, keeps 'src')",
      !folderExclData.isEmpty && !folderExclData.contains("data") && folderExclData.contains("src"))
check("type: '-file:report' excludes report.txt but keeps data.json",
      !has("-file:report", "report.txt") && has("-file:report", "data.json"))

// Everything's Match Whole Word (ww: / wholeword:)
check("wholeword: 'ww: report' matches report.txt", has("ww: report", "report.txt"))
check("wholeword: 'ww: report' excludes reporting_x.txt", !has("ww: report", "reporting_x.txt"))
check("wholeword: plain 'report' still matches reporting_x.txt", has("report", "reporting_x.txt"))

// Everything-style AUTO-WILDCARD in Exact mode (+ "quoted" literal escape)
check("auto-glob: 'image_0*.png' works in Exact mode", has("image_0*.png", "image_001.png"))
check("auto-glob: anchored — 'report*' matches report.txt", has("report*", "report.txt"))
check("auto-glob: 'repo*' does NOT match notes.md", !has("repo*", "notes.md"))
check("quoted literal: '\"*\"' finds the file with a real star", has("\"*\"", "star*name.txt"))
check("quoted literal: quotes suppress filter parsing", has("\"star*name\"", "star*name.txt"))
check("plain substring still works alongside a glob term", has("image_0??.png ext:png", "image_001.png"))

// Everything 1.5-style folder sizes (sort & display by subtree totals)
index.buildFolderSizes()
if let imgDir = index.dirIndex(forPath: root + "/img") {
    check("folder size: img/ == sum of its 20 images (2000 B)",
          index.folderSizeIfReady(Int(imgDir)) == 20 * 100)
}
if let dataDir = index.dirIndex(forPath: root + "/data") {
    let ds = index.folderSizeIfReady(Int(dataDir)) ?? 0
    check("folder size: data/ >= big.bin + data.json (6 MB)", ds >= 6 * 1_048_576)
    let top = engine.search("", sortKey: .size, ascending: false, limit: 3, now: now).ids
    let names = top.map { index.name(Int($0)) }
    check("size sort (desc) ranks the fixture root dir first (largest total)",
          names.first == root)   // the crawl root's name IS its absolute path
}

// Everything's "Exclude files" patterns (crawl + reconcile)
write("junky.tmp", bytes: 2)
write("keepme.txt", bytes: 2)
let pats = FileEnumerator.parseFilePatterns("*.tmp; *.log")
let idxP = FileIndex()
_ = FileEnumerator(index: idxP).crawl(roots: [root], exclude: [], mountPoints: [], excludeFilePatterns: pats)
idxP.buildLiveIndexes()
let eP = SearchEngine(index: idxP)
check("exclude-files: *.tmp skipped at crawl", eP.search("junky", limit: 10, now: now).total == 0)
check("exclude-files: other files kept", eP.search("keepme", limit: 10, now: now).total == 1)
let recP = Reconciler(index: idxP, exclude: [], excludeFilePatterns: pats)
write("later.tmp", bytes: 2); write("later.txt", bytes: 2)
_ = recP.reconcile(eventPaths: [root]); eP.invalidate()
check("exclude-files: *.tmp skipped by reconcile too", eP.search("later", limit: 10, now: now).total == 1)
try? fm.removeItem(atPath: root + "/junky.tmp"); try? fm.removeItem(atPath: root + "/later.tmp")
try? fm.removeItem(atPath: root + "/later.txt")

// Everything's "Include only files" whitelist + live hide-hidden toggle
write("music_a.mp3", bytes: 2); write("music_b.flac", bytes: 2); write("notes_w.txt", bytes: 2)
let onlyPats = FileEnumerator.parseFilePatterns("*.mp3;*.flac")
let idxW = FileIndex()
_ = FileEnumerator(index: idxW).crawl(roots: [root], exclude: [], mountPoints: [], includeOnlyFiles: onlyPats)
idxW.buildLiveIndexes()
let eW = SearchEngine(index: idxW)
check("include-only: whitelisted files indexed",
      eW.search("music_a", limit: 5, now: now).total == 1 && eW.search("music_b", limit: 5, now: now).total == 1)
check("include-only: non-matching file skipped", eW.search("notes_w", limit: 5, now: now).total == 0)
check("include-only: folders still kept", eW.search("folder:dupA", limit: 5, now: now).total == 1)
let recW = Reconciler(index: idxW, exclude: [], includeOnlyFiles: onlyPats)
write("late_song.mp3", bytes: 2); write("late_note.txt", bytes: 2)
_ = recW.reconcile(eventPaths: [root]); eW.invalidate()
check("include-only: reconcile honors whitelist",
      eW.search("late_song", limit: 5, now: now).total == 1 && eW.search("late_note", limit: 5, now: now).total == 0)
for f in ["music_a.mp3","music_b.flac","notes_w.txt","late_song.mp3","late_note.txt"] {
    try? fm.removeItem(atPath: root + "/" + f)
}
// hideHidden: instant result-level filter (index keeps everything)
engine.hideHidden = true; engine.invalidate()
check("hide-hidden: dotfile filtered from results", engine.search(".secret", limit: 5, now: now).total == 0)
engine.hideHidden = false; engine.invalidate()
check("hide-hidden: off restores dotfiles", engine.search(".secret", limit: 5, now: now).total >= 1)

// Folders First must use the SAME Finder semantics: .bundle sinks to the files half
engine.foldersFirst = true; engine.invalidate()
let ffR = engine.search("pkgtest", limit: 50, now: now)
var sawRealDirEnd = -1, pkgPos = -1
for (i, id) in ffR.ids.enumerated() {
    let nm = index.name(Int(id))
    if nm == "pkgtest.bundle" { pkgPos = i }
    if index.isDir(Int(id)) && nm != "pkgtest.bundle" { sawRealDirEnd = max(sawRealDirEnd, i) }
}
check("folders-first: package sorts with FILES not folders",
      pkgPos >= 0 && (sawRealDirEnd == -1 || pkgPos > sawRealDirEnd))
engine.foldersFirst = false; engine.invalidate()

// Everything's "Match whole filename when using wildcards" toggle
check("wildcard-whole ON: 'port*' misses report.txt (anchored)", !has("port*", "report.txt"))
engine.wholeNameWildcards = false; engine.invalidate()
check("wildcard-whole OFF: 'port*' finds report.txt (match anywhere)", has("port*", "report.txt"))
check("wildcard-whole OFF: '?ata.json' finds data.json", has("?ata.json", "data.json"))
engine.wholeNameWildcards = true; engine.invalidate()
check("wildcard-whole restored: anchored again", !has("port*", "report.txt"))

// wildcard-whole toggle must be a NO-OP in fuzzy/regex modes (was corrupting them)
engine.wholeNameWildcards = false; engine.invalidate()
check("wildcard-whole OFF: regex anchors survive (^…$ not star-wrapped)",
      engine.search("^report\\.txt$", mode: .regex, limit: 10, now: now).total == 1)
check("wildcard-whole OFF: fuzzy unaffected by glob chars",
      engine.search("rprt", mode: .fuzzy, limit: 10_000, now: now).ids.contains { index.name(Int($0)) == "report.txt" })
engine.wholeNameWildcards = true; engine.invalidate()

// Finder semantics: package dirs (.bundle) are FILES for folder:/file: filters
check("package: 'file:' includes pkgtest.bundle", has("file:pkgtest", "pkgtest.bundle"))
check("package: 'folder:' excludes pkgtest.bundle", !has("folder:pkgtest", "pkgtest.bundle"))
check("package: plain dir still a folder ('folder:data')", has("folder:data", "data"))

// Everything 1.5-style "Folders first" (result-level stable partition)
engine.foldersFirst = true
let ffIds = engine.search("", sortKey: .name, ascending: true, limit: 100_000, now: now).ids
var seenFileFF = false; var ffOK = true
for id in ffIds {
    // Finder semantics: package dirs (.bundle) COUNT AS FILES in the partition
    let d = index.isDir(Int(id)) && !index.name(Int(id)).hasSuffix(".bundle")
    if !d { seenFileFF = true } else if seenFileFF { ffOK = false; break }
}
check("foldersFirst: no real directory appears after the first file", ffOK && seenFileFF)
engine.foldersFirst = false

// Everything's duplicate finder (dupe:)
check("dupe: finds twin_name.txt (exists twice)", has("dupe: twin", "twin_name.txt"))
check("dupe: excludes unique report.txt", !has("dupe: report", "report.txt"))
check("dupe: bare filter returns only duplicated names",
      engine.search("dupe:", limit: 100_000, now: now).ids
          .allSatisfy { index.name(Int($0)) == "twin_name.txt" }
      && engine.search("dupe:", limit: 100_000, now: now).total >= 2)

// Everything 1.4 filters: empty: (empty folders), len: (name length), startwith:/endwith:
check("empty: finds the empty fixture dir", has("empty:", "emptydir"))
check("empty: excludes a non-empty dir", !has("empty:", "img"))
check("empty: excludes plain files (implies folder:)", !has("empty: report", "report.txt"))
check("len: exact 8 finds notes.md, excludes report.txt (10)",
      has("len:8", "notes.md") && !has("len:8", "report.txt"))
check("len:>10 narrows 'report' to reporting_x.txt only",
      has("report len:>10", "reporting_x.txt") && !has("report len:>10", "report.txt"))
check("len: range 3..8 keeps notes.md, drops report.txt",
      has("len:3..8", "notes.md") && !has("len:3..8", "report.txt"))
check("len:<=3 finds the img dir", has("len:<=3", "img"))
check("startwith:rep finds report.txt AND folded Report.PNG",
      has("startwith:rep", "report.txt") && has("startwith:rep", "Report.PNG"))
check("startwith:app finds app.swift + AppModel.swift, not QueryParser.swift",
      has("startwith:app", "app.swift") && has("startwith:app", "AppModel.swift")
      && !has("startwith:app", "QueryParser.swift"))
check("endwith:.md finds notes.md + README.md, excludes report.txt",
      has("endwith:.md", "notes.md") && has("endwith:.md", "README.md")
      && !has("endwith:.md", "report.txt"))
check("-startwith:rep excludes report.txt, keeps notes.md",
      !has("-startwith:rep", "report.txt") && has("-startwith:rep", "notes.md"))
check("-endwith:.txt excludes report.txt, keeps notes.md",
      !has("-endwith:.txt", "report.txt") && has("-endwith:.txt", "notes.md"))
check("startwith: honors case:on ('Rep' → Report.PNG only)",
      has("case:on startwith:Rep", "Report.PNG") && !has("case:on startwith:Rep", "report.txt"))
check("alias: endswith:.png finds Report.PNG (folded)", has("endswith:.png", "Report.PNG"))

// incremental "narrow as you type": extending a query must equal a from-scratch full scan
_ = engine.search("re", limit: 100_000, now: now)                      // caches full set for "re"
let incNarrow = engine.search("rep", limit: 100_000, now: now).ids     // narrowed from "re"
_ = engine.search("zzznope", limit: 100_000, now: now)                 // breaks the prefix chain
let incFull = engine.search("rep", limit: 100_000, now: now).ids       // full parallel scan
check("incremental narrowing == full scan (same set)", Set(incNarrow) == Set(incFull))
check("incremental narrowing == full scan (same order)", incNarrow == incFull)

// folder scope ("Search in This Folder") — restrict to a subtree via parent walk
if let dataDir = index.dirIndex(forPath: root + "/data") {
    let inData = Set(engine.search("json", limit: 10_000, now: now, scopeRoot: dataDir).ids.map { index.name(Int($0)) })
    check("scope: 'json' under data/ finds data.json", inData.contains("data.json"))
}
if let srcDir = index.dirIndex(forPath: root + "/src") {
    let inSrc = Set(engine.search("json", limit: 10_000, now: now, scopeRoot: srcDir).ids.map { index.name(Int($0)) })
    check("scope: 'json' under src/ excludes data.json", !inSrc.contains("data.json"))
    let underSrc = Set(engine.search("", limit: 100_000, now: now, scopeRoot: srcDir).ids.map { index.name(Int($0)) })
    check("scope: empty query lists src subtree (leaf.txt in, report.txt out)",
          underSrc.contains("leaf.txt") && !underSrc.contains("report.txt"))
}

// regex mode
check("regex: '^report\\.' matches report.txt", has("^report\\.", "report.txt", mode: .regex))
check("regex: '\\.png$' matches image_001.png", has("\\.png$", "image_001.png", mode: .regex))
check("regex: '\\.png$' excludes notes.md", !has("\\.png$", "notes.md", mode: .regex))
check("regex: invalid pattern → no crash, empty", engine.search("[", mode: .regex, limit: 10, now: now).total == 0)

// empty query returns everything
check("empty query returns all \(index.count)", engine.search("", limit: 1_000_000, now: now).total == index.count)

// ---- live updates (reconciler) ----
let rec = Reconciler(index: index, exclude: [])
write("live_new.txt", bytes: 42, mtime: now)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("live: created file is found", has("live_new", "live_new.txt"))
// bloom regression (Codex review): reconcile-insert of an ASCII name must not trap on
// Int(noUnicodeFoldOffset), and a NON-ASCII name must OR its unicode fold into the mask
// so a diacritic-folded query still finds it via the live-append mask path.
write("café_live.txt", bytes: 8, mtime: now)
write("한글_live.txt", bytes: 8, mtime: now)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("live: reconcile-inserted diacritic name found by folded query (mask path)",
      has("cafe_live", "café_live.txt"))
check("live: reconcile-inserted Korean name found (mask path)", has("한글", "한글_live.txt"))
try? fm.removeItem(atPath: root + "/café_live.txt"); try? fm.removeItem(atPath: root + "/한글_live.txt")
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
try? fm.removeItem(atPath: root + "/live_new.txt")
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("live: deleted file is gone", !has("live_new", "live_new.txt"))
// modify size
FileManager.default.createFile(atPath: root + "/report.txt", contents: Data(count: 9999))
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
let reportId = engine.search("report.txt", limit: 20, now: now)
    .ids.map { Int($0) }.first { index.name($0) == "report.txt" }
check("live: modified size reflected", reportId.map { index.size[$0] == 9999 } ?? false,
      "size=\(reportId.map { String(index.size[$0]) } ?? "nil")")

// live: new subdirectory with contents recurses
write("newdir/nested_alpha.txt", bytes: 7)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("live: new subdir contents indexed", has("nested_alpha", "nested_alpha.txt"))

// review#1: file <-> dir type flip must re-index correctly (not corrupt the index)
write("flipme", bytes: 10)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("flip: 'flipme' starts as a file", has("flipme", "flipme"))
try? fm.removeItem(atPath: root + "/flipme")     // file -> dir with contents
mkdir(root + "/flipme")
write("flipme/inside_flip.txt", bytes: 5)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("flip: file->dir now indexes its contents", has("inside_flip", "inside_flip.txt"))
try? fm.removeItem(atPath: root + "/flipme")     // dir -> file again
write("flipme", bytes: 3)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("flip: dir->file drops the stale contents", !has("inside_flip", "inside_flip.txt"))

// codex+agy consensus: FSEvents may deliver decomposed (NFD) paths; reconcile must NFC-normalize
// them to resolve the NFC-keyed index (else Korean/accented dirs silently never reconcile).
mkdir(root + "/한글폴더")
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()          // dir indexed under NFC key
write("한글폴더/한글파일.txt", bytes: 5)
let nfdDir = (root + "/한글폴더").decomposedStringWithCanonicalMapping   // event arrives as NFD
_ = rec.reconcile(eventPaths: [nfdDir]); engine.invalidate()
check("nfc: NFD event path resolves the NFC-indexed Korean dir", has("한글파일", "한글파일.txt"))

// codex: search caches key off FileIndex.mutationGen, so a mutation self-heals the cache
// even WITHOUT an explicit engine.invalidate() (impossible-to-miss invalidation).
write("selfheal_x.txt", bytes: 11)
_ = rec.reconcile(eventPaths: [root])          // deliberately NO engine.invalidate()
check("mutationGen: new file found w/o explicit invalidate()", has("selfheal_x", "selfheal_x.txt"))
try? fm.removeItem(atPath: root + "/selfheal_x.txt")
_ = rec.reconcile(eventPaths: [root])          // again NO invalidate()
check("mutationGen: deleted file gone w/o explicit invalidate()", !has("selfheal_x", "selfheal_x.txt"))

// content: — on-demand file-content substring (Everything 1.4-style)
try? "The SECRET-token lives here, quietly.".write(toFile: root + "/contentful.txt", atomically: true, encoding: .utf8)
try? "nothing to see".write(toFile: root + "/boring.txt", atomically: true, encoding: .utf8)
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
check("content: finds by contents (case-insensitive)", has("content:secret-token", "contentful.txt"))
check("content: excludes non-matching files", !has("content:secret-token", "boring.txt"))
check("content: combined with ext filter", has("ext:txt content:quietly", "contentful.txt"))
check("content: no match returns empty", engine.search("content:zzznope_xyz", limit: 100, now: now).total == 0)

// tag: — Finder tag filter (xattr path; mdfind path needs >10k candidates, not simulated)
func setTag(_ path: String, _ tags: [String]) {
    let value = tags.map { "\($0)\n2" }
    if let d = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
        _ = d.withUnsafeBytes { setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0) }
    }
}
setTag(root + "/contentful.txt", ["Green"])
check("tag: finds tagged file", has("tag:green", "contentful.txt"))
check("tag: excludes untagged file", !has("tag:green", "boring.txt"))
check("tag: wrong tag finds nothing", !has("tag:purple", "contentful.txt"))


// dynamic mount lifecycle: a new crawl root can be appended after launch, then tombstoned
// as one subtree on unmount. Both operations must self-invalidate search caches.
mkdir(dynamicRoot)
writeAbs(dynamicRoot + "/mounted_alpha.txt", bytes: 13, mtime: now)
writeAbs(dynamicRoot + "/nested/mounted_beta.txt", bytes: 17, mtime: now)
let mountStats = FileEnumerator(index: index).crawl(roots: [dynamicRoot])
index.buildLiveIndexes()
check("dynamic mount: new root crawled after launch", mountStats.total >= 3 && has("mounted_alpha", "mounted_alpha.txt"))
check("dynamic mount: nested content indexed", has("mounted_beta", "mounted_beta.txt"))
let removedDynamic = index.markDeletedSubtree(displayPath: dynamicRoot)
check("dynamic unmount: tombstones whole mounted root",
      removedDynamic >= 3 && !has("mounted_alpha", "mounted_alpha.txt") && !has("mounted_beta", "mounted_beta.txt"),
      "removed=\(removedDynamic)")
check("dynamic unmount: root dir lookup removed", index.dirIndex(forPath: dynamicRoot) == nil)

// ---- snapshot round-trip ----
let blob = index.snapshotData(lastEventId: 777, savedAt: 1.0)                 // compressed (default)
let rawBlob = index.snapshotData(lastEventId: 777, savedAt: 1.0, compress: false)  // raw v5 for byte surgery
let idx2 = FileIndex()
let meta = idx2.loadSnapshot(blob); idx2.buildLiveIndexes()
let e2 = SearchEngine(index: idx2)
check("snapshot: lastEventId preserved", meta?.lastEventId == 777)
check("snapshot: 'png' count survives round-trip",
      e2.search("png", limit: 10_000, now: now).total == engine.search("png", limit: 10_000, now: now).total)
check("snapshot: Unicode fold survives round-trip",
      e2.search("cafe", limit: 10_000, now: now).ids.map { idx2.name(Int($0)) }.contains("CAFÉ.txt"))

// ---- v4 → v5 backward-compat (nameOff widened UInt32 → UInt64) ----
// Synthesize a legacy v4 blob (4-byte nameOff) from the current v5 blob by
// flipping the version byte and narrowing the nameOff array, then confirm the
// migration read path in loadSnapshot reconstructs identical results.
let v4blob: Data = {
    var b = [UInt8](rawBlob)
    func rdU64(_ at: Int) -> Int { (0..<8).reduce(0) { $0 | (Int(b[at+$1]) << (8*$1)) } }
    let count = rdU64(24), blobLen = rdU64(32), uBlobLen = rdU64(40)
    b[4] = 4; b[5] = 0; b[6] = 0; b[7] = 0                  // version 5 → 4 (little-endian UInt32)
    let nameOffStart = 48 + blobLen*2 + uBlobLen
    var out = Array(b[0..<nameOffStart])
    for i in 0..<count {                                     // UInt64 LE → UInt32 LE (low 4 bytes)
        let base = nameOffStart + i*8
        out.append(contentsOf: b[base..<base+4])
    }
    out.append(contentsOf: b[(nameOffStart + count*8)...])
    return Data(out)
}()
let idx4 = FileIndex()
let meta4 = idx4.loadSnapshot(v4blob); idx4.buildLiveIndexes()
let e4 = SearchEngine(index: idx4)
check("snapshot v4→v5: legacy version accepted", meta4?.lastEventId == 777)
check("snapshot v4→v5: 'png' count matches",
      meta4 != nil && e4.search("png", limit: 10_000, now: now).total == engine.search("png", limit: 10_000, now: now).total)
check("snapshot v4→v5: Unicode fold survives migration",
      e4.search("cafe", limit: 10_000, now: now).ids.map { idx4.name(Int($0)) }.contains("CAFÉ.txt"))
check("snapshot v4→v5: path-scope search intact after migration",
      e4.search("png", limit: 10_000, now: now).total > 0
      && e4.search("png", limit: 10_000, now: now).total == e2.search("png", limit: 10_000, now: now).total)

let shortV4 = Data(v4blob.dropLast())
let shortV4Idx = FileIndex()
check("snapshot v4→v5: truncated legacy blob rejects",
      shortV4Idx.loadSnapshot(shortV4) == nil && shortV4Idx.count == 0)

let corruptV4: Data = {
    var b = [UInt8](v4blob)
    func rdU64(_ at: Int) -> Int { (0..<8).reduce(0) { $0 | (Int(b[at+$1]) << (8*$1)) } }
    let count = rdU64(24), blobLen = rdU64(32), uBlobLen = rdU64(40)
    if count > 0 {
        let nameOffStart = 48 + blobLen*2 + uBlobLen
        b[nameOffStart] = 0xff; b[nameOffStart + 1] = 0xff
        b[nameOffStart + 2] = 0xff; b[nameOffStart + 3] = 0xff
    }
    return Data(b)
}()
let corruptV4Idx = FileIndex()
_ = corruptV4Idx.appendRoot(path: "/sentinel")
let corruptBefore = corruptV4Idx.count
check("snapshot v4→v5: corrupt offsets reject without replacing index",
      corruptV4Idx.loadSnapshot(corruptV4) == nil
      && corruptV4Idx.count == corruptBefore
      && corruptV4Idx.name(0) == "/sentinel")

// v5-NATIVE rejection (regression guards for the Int-conversion trap fixed in f4ab553):
// (a) truncated v5 must reject via the expected-length math, index untouched
let shortV5 = Data(rawBlob.dropLast())
let shortV5Idx = FileIndex()
check("snapshot v5: truncated blob rejects without touching index",
      shortV5Idx.loadSnapshot(shortV5) == nil && shortV5Idx.count == 0)
// (b) corrupt v5 with a huge 8-byte nameOff (>= 2^63) must reject, NOT trap on Int()
let corruptV5: Data = {
    var b = [UInt8](rawBlob)
    func rdU64(_ at: Int) -> Int { (0..<8).reduce(0) { $0 | (Int(b[at+$1]) << (8*$1)) } }
    let blobLen = rdU64(32), uBlobLen = rdU64(40)
    let nameOffStart = 48 + blobLen*2 + uBlobLen
    for j in 0..<8 { b[nameOffStart + j] = 0xff }            // nameOff[0] = UInt64.max
    return Data(b)
}()
let corruptV5Idx = FileIndex()
_ = corruptV5Idx.appendRoot(path: "/sentinel5")
check("snapshot v5: 2^63+ nameOff rejects without trap or index replacement",
      corruptV5Idx.loadSnapshot(corruptV5) == nil
      && corruptV5Idx.count == 1
      && corruptV5Idx.name(0) == "/sentinel5")

// ---- RunHistory frecency (Run Count sort + relevance boost) ----
do {
    let rroot = root + "/runAB"
    mkdir(rroot)
    for p in ["alpha_report.txt", "beta_report.txt", "gamma_report.txt",
              "delta_report.txt", "sub/nested_report.txt"] { write("runAB/" + p, bytes: 4) }
    let rIdx = FileIndex()
    _ = FileEnumerator(index: rIdx).crawl(roots: [rroot])
    rIdx.buildLiveIndexes()
    let rStats = RunStats(url: nil, cap: 4)     // in-memory (no persistence in tests)
    let rEng = SearchEngine(index: rIdx)
    rEng.runStats = rStats
    let rnow = now
    // idFor: paths resolve to current ids (grouped by parent, verified lookup)
    let dPath = rroot + "/delta_report.txt"
    let nestedPath = rroot + "/sub/nested_report.txt"
    let resolved = rIdx.resolveIds(forPaths: [dPath, nestedPath, rroot + "/nonexistent.txt"])
    check("runstats: resolveIds maps real paths to ids, drops missing",
          resolved[dPath] != nil && resolved[nestedPath] != nil
          && resolved.count == 2 && rIdx.name(Int(resolved[dPath]!)) == "delta_report.txt")

    // record opens: delta most, then gamma; runCount sort floats them to the front
    for _ in 0..<5 { rStats.record(path: dPath, now: rnow) }
    for _ in 0..<2 { rStats.record(path: rroot + "/gamma_report.txt", now: rnow) }
    rEng.invalidate()
    let rc = rEng.search("report", sortKey: .runCount, ascending: false, limit: 10, now: rnow)
                 .ids.map { rIdx.name(Int($0)) }
    check("runcount: most-run file is first", rc.first == "delta_report.txt", rc.joined(separator: ","))
    check("runcount: second-most-run is second", rc.count > 1 && rc[1] == "gamma_report.txt", rc.joined(separator: ","))
    check("runcount: untracked files keep name order after tracked",
          Array(rc.suffix(3)) == ["alpha_report.txt", "beta_report.txt", "nested_report.txt"],
          rc.joined(separator: ","))
    // runCount must not DROP or DUPLICATE any match vs a plain name search
    let plainSet = Set(rEng.search("report", sortKey: .name, limit: 10, now: rnow).ids)
    let rcSet = Set(rEng.search("report", sortKey: .runCount, limit: 10, now: rnow).ids)
    check("runcount: same result set as name sort (no drops/dupes)", plainSet == rcSet)

    // relevance boost: a heavily-run file outranks an equal-name-score peer
    let relIds = rEng.search("report", mode: .fuzzy, sortKey: .relevance, ascending: false, limit: 10, now: rnow)
                    .ids.map { rIdx.name(Int($0)) }
    check("relevance: frecency boost lifts the most-run file toward the top",
          relIds.prefix(2).contains("delta_report.txt"), relIds.joined(separator: ","))

    // frecency decay: an old open is worth less than a fresh one
    let sOld = RunStats.frecency(count: 10, lastRun: rnow - 60 * 86_400, now: rnow)
    let sNew = RunStats.frecency(count: 3, lastRun: rnow, now: rnow)
    check("frecency: recent few can outrank stale many (decay works)", sNew > sOld,
          "old=\(String(format: "%.2f", sOld)) new=\(String(format: "%.2f", sNew))")

    // cap prunes lowest-frecency entries
    let capped = RunStats(url: nil, cap: 2)
    capped.record(path: "/a.txt", now: rnow); capped.record(path: "/a.txt", now: rnow)   // score 2
    capped.record(path: "/b.txt", now: rnow)                                             // score 1
    capped.record(path: "/c.txt", now: rnow)                                             // score 1 → evicts a loser
    check("runstats: cap prunes to size, keeps highest frecency", capped.trackedCount == 2
          && capped.count(forPath: "/a.txt") == 2)

    // clear wipes history
    rStats.clear(); rEng.invalidate()
    let afterClear = rEng.search("report", sortKey: .runCount, ascending: false, limit: 10, now: rnow)
                        .ids.map { rIdx.name(Int($0)) }
    check("runstats: clear resets to plain name order",
          afterClear == ["alpha_report.txt", "beta_report.txt", "delta_report.txt",
                         "gamma_report.txt", "nested_report.txt"], afterClear.joined(separator: ","))
}

// ---- character bloom prefilter: A/B equivalence (gate ON must equal brute scan) ----
// The gate is a NECESSARY-condition prefilter; if it ever drops a real match that's a
// false negative. Build a controlled tree, then assert the gated engine returns EXACTLY
// the same result set as the same engine with masks forced all-bits (full scan).
do {
    let broot = root + "/bloomAB"
    mkdir(broot)
    for (p, _) in [("Report_Final.txt", 0), ("café_menu.txt", 0), ("한글파일.txt", 0),
                   ("photo_2024.jpg", 0), ("photo_2025.png", 0), ("MixedCase.SWIFT", 0),
                   ("data.json", 0), ("draft report.md", 0), ("twin.txt", 0),
                   ("sub/twin.txt", 0), ("sub/RESUME.pdf", 0), ("émigré.doc", 0),
                   ("naïve_test.txt", 0), ("UPPER.TXT", 0), ("mix3d_battery.app", 0)] {
        write("bloomAB/" + p, bytes: 4)
    }
    let bIdx = FileIndex()
    _ = FileEnumerator(index: bIdx).crawl(roots: [broot])
    bIdx.buildLiveIndexes()
    let bEng = SearchEngine(index: bIdx)
    // Battery spans every gate-relevant shape: exact/fuzzy/wildcard/regex, case:on,
    // diacritics (café/cafe), Korean NFC, OR-groups, negation, path scope, affixes.
    let battery: [(String, MatchMode, SearchScope)] = [
        ("report", .exact, .nameOnly), ("REPORT", .exact, .nameOnly),
        ("cafe", .exact, .nameOnly), ("café", .exact, .nameOnly),
        ("emigre", .exact, .nameOnly), ("naive", .exact, .nameOnly),
        ("한글", .exact, .nameOnly), ("파일", .exact, .nameOnly),
        ("rpt", .fuzzy, .nameOnly), ("phto", .fuzzy, .nameOnly), ("mixcase", .fuzzy, .nameOnly),
        ("rprt", .fuzzy, .nameOnly), ("3dbat", .fuzzy, .nameOnly),
        ("photo_202?.*", .exact, .nameOnly), ("*.txt", .exact, .nameOnly),
        ("re*rt", .exact, .nameOnly), ("*café*", .exact, .nameOnly),
        ("jpg|png", .exact, .nameOnly), ("report|resume", .exact, .nameOnly),
        ("report -final", .exact, .nameOnly), ("twin -sub", .exact, .nameOnly),
        ("case:on Report", .exact, .nameOnly), ("case:on report", .exact, .nameOnly),
        ("case:on SWIFT", .exact, .nameOnly), ("case:on UPPER", .exact, .nameOnly),
        ("sub", .exact, .fullPath), ("bloomAB/sub", .exact, .fullPath),
        ("path:sub twin", .exact, .nameOnly), ("startwith:photo", .exact, .nameOnly),
        ("endwith:.txt", .exact, .nameOnly), ("^report.*", .regex, .nameOnly),
        ("[cé]af", .regex, .nameOnly), ("ext:jpg", .exact, .nameOnly),
        ("twin", .exact, .nameOnly), ("data json", .exact, .nameOnly),
    ]
    func idset(_ q: String, _ m: MatchMode, _ s: SearchScope) -> Set<Int32> {
        Set(bEng.search(q, mode: m, scope: s, limit: 10_000, now: now).ids)
    }
    var gated: [Set<Int32>] = []
    for (q, m, s) in battery { gated.append(idset(q, m, s)) }
    bIdx._debugSetAllMasksAllBits()      // gate OFF → full brute scan = ground truth
    bEng.invalidate()
    var mismatches: [String] = []
    for (i, (q, m, s)) in battery.enumerated() {
        let brute = idset(q, m, s)
        if brute != gated[i] { mismatches.append("\(q) [\(m)]: gate=\(gated[i].count) brute=\(brute.count)") }
    }
    check("bloom A/B: gated results == brute scan across all query shapes (no false negatives)",
          mismatches.isEmpty, mismatches.joined(separator: "; "))
    // restore authoritative masks (in case later code reuses bIdx)
    bIdx.buildLiveIndexes(); bEng.invalidate()

    // masks must actually PRUNE something (else the gate is a silent no-op)
    let needleM = FileIndex.maskOf(Array("zzqx".utf8))
    var pruned = 0
    for i in 0..<bIdx.count where (bIdx.nameMask[i] & needleM) != needleM { pruned += 1 }
    check("bloom: mask rejects non-matching candidates (gate is live, not a no-op)", pruned > 0,
          "pruned \(pruned)/\(bIdx.count) for needle 'zzqx'")
}

// ---- latency pass (small tree; real-scale perf is in mvtest on /usr) ----
let qs = ["a", "re", "png", "swift", "image_0", " amdl", "*.md", "ext:png", "size:>1mb"]
var times: [Double] = []
for _ in 0..<200 { for q in qs {
    let r = engine.search(q, mode: q.contains("*") ? .wildcard : .exact, limit: 1000, now: now)
    times.append(r.queryMillis)
}}
times.sort()
let p50 = times[times.count/2], p95 = times[Int(Double(times.count)*0.95)]
let avg = times.reduce(0,+)/Double(times.count)

// ---- report ----
let passed = cases.filter { $0.pass }.count
let failed = cases.count - passed
print("\n=== \(passed)/\(cases.count) passed, \(failed) failed ===")

var md = "# Maverything — Simulation Report\n\n"
md += "- generated over a synthetic tree of **\(index.count)** entries\n"
md += "- result: **\(passed)/\(cases.count) scenarios passed**" + (failed == 0 ? " ✅" : " — \(failed) FAILED ❌") + "\n"
md += String(format: "- query latency on the synthetic set: avg %.3f ms · p50 %.3f ms · p95 %.3f ms\n", avg, p50, p95)
md += "- (real-scale latency is measured by `mvtest` on /usr or the whole disk)\n\n"
md += "| scenario | result |\n|---|---|\n"
for c in cases { md += "| \(c.name)\(c.detail.isEmpty ? "" : " (\(c.detail))") | \(c.pass ? "✅" : "❌ FAIL") |\n" }
let reportPath = (CommandLine.arguments.count > 1 ? root : FileManager.default.currentDirectoryPath) + "/SIMULATION-REPORT.md"
try? md.write(toFile: reportPath, atomically: true, encoding: .utf8)
print("report -> \(reportPath)")

try? fm.removeItem(atPath: root)
try? fm.removeItem(atPath: dynamicRoot)
exit(failed == 0 ? 0 : 1)
