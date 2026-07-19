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
write("intl/한글파일.txt", bytes: 30)                   // unicode (4 syllables)
write("intl/가.txt", bytes: 12)                         // SINGLE non-ASCII codepoint (3 bytes) — ? wildcard
write("intl/café.md", bytes: 30)
write("intl/CAFÉ.txt", bytes: 30)
write("annual_report_summary.txt", bytes: 20)          // longer "report" match — relevance ranking
write("src/a/b/c/d/leaf.txt", bytes: 5)                // deep nesting
write(".hidden/.secret.txt", bytes: 5)                 // hidden
// path-column sort fixture (OQ1A): basename order and full-path order DISAGREE here —
// by name apple<zebra, but by path adir/…<zdir/…, so the two files swap order.
write("zdir/marker_apple.txt", bytes: 8)
write("adir/marker_zebra.txt", bytes: 8)
mkdir(root + "/emptydir")                              // empty: fixture (dir with no children)
mkdir(root + "/thumbs.jpg")                            // DIRECTORY with an image extension (media-chip trap)
write("thumbs.jpg/picture.jpg", bytes: 5)           // a real image file inside it
// type: operator fixtures — one file per category, incl. a dual-category .dmg
// (archives AND apps) and mixed case (.PDF) to exercise the folded extraction.
write("kind/manual.pdf", bytes: 12)                   // documents
write("kind/SHOUT.PDF", bytes: 12)                    // documents, uppercase ext (fold path)
write("kind/photo.jpeg", bytes: 12)                   // images
write("kind/song.mp3", bytes: 12)                     // audio
write("kind/clip.mp4", bytes: 12)                     // video
write("kind/bundle.zip", bytes: 12)                   // archives
write("kind/installer.dmg", bytes: 12)                // archives + apps (dual bit)
write("kind/tool.exe", bytes: 12)                     // apps
write("kind/notes.noext", bytes: 12)                  // unknown ext → no category

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
// '?' = one CHARACTER, not one byte: a single '?' matches a 3-byte Korean syllable, and TWO
// '?' must NOT match a one-character name.
check("wildcard: '?.txt' matches single-syllable 가.txt (? = one codepoint)",
      has("?.txt", "가.txt", mode: .wildcard))
check("wildcard: '??.txt' does NOT match one-char 가.txt", !has("??.txt", "가.txt", mode: .wildcard))
check("wildcard: '????.txt' matches 4-syllable 한글파일.txt",
      has("????.txt", "한글파일.txt", mode: .wildcard))

// exact single-term Relevance is RANKED, not alphabetical (regression: fastExact used to
// return name order for relevance, so 'report' surfaced Report.PNG/annual_report first).
// Relevance is a descending sort in the UI (best-first), so query ascending:false.
let relReport = engine.search("report", mode: .exact, sortKey: .relevance, ascending: false,
                              limit: 10_000, now: now).ids.map { index.name(Int($0)) }
check("relevance(exact): 'report' ranks short prefix report.txt FIRST",
      relReport.first == "report.txt", "got \(relReport.prefix(3))")
check("relevance(exact): report.txt outranks longer annual_report_summary.txt",
      (relReport.firstIndex(of: "report.txt") ?? 99) < (relReport.firstIndex(of: "annual_report_summary.txt") ?? 99))

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
// media-chip semantics: "ext:jpg" alone matches a DIRECTORY named *.jpg, but the chips
// carry file: so a folder with an image extension is excluded while real files stay.
check("ext:jpg alone matches a dir with image ext (the trap)", has("ext:jpg", "thumbs.jpg"))
check("file: ext:jpg EXCLUDES the *.jpg directory", !has("file: ext:jpg", "thumbs.jpg"))
check("file: ext:jpg still matches a real .jpg file", has("file: ext:jpg", "picture.jpg"))
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

// Incremental order-cache invalidation (name/path keyed on epoch+count, not mutationGen):
// a reconcile APPEND must appear in a WARM name order WITHOUT an explicit invalidate (count
// grew → the order recomputes), and the result must equal a from-scratch order.
do {
    let idxI = FileIndex()
    _ = FileEnumerator(index: idxI).crawl(roots: [root], exclude: [], mountPoints: [])
    idxI.buildLiveIndexes()
    let eI = SearchEngine(index: idxI)
    _ = eI.search("", sortKey: .name, limit: 100_000, now: now)     // WARM the name order cache
    let uniqueName = "mvsim_incremental_marker_kqx.dat"
    writeAbs(root + "/" + uniqueName, bytes: 3)
    let recI = Reconciler(index: idxI, exclude: [])
    _ = recI.reconcile(eventPaths: [root])                          // append — NO eI.invalidate()
    let after = eI.search("mvsim_incremental_marker", sortKey: .name, limit: 10, now: now)
                  .ids.map { idxI.name(Int($0)) }
    check("incremental: reconcile-append shows in WARM name order (no manual invalidate)",
          after.contains(uniqueName), "got \(after)")
    // full order equals a from-scratch engine over the same (mutated) index
    let warm = eI.search("", sortKey: .name, limit: 100_000, now: now).ids
    let fresh = SearchEngine(index: idxI).search("", sortKey: .name, limit: 100_000, now: now).ids
    check("incremental: warm name order == from-scratch order after append", warm == fresh)
    // DELETION with a WARM order that isn't rebuilt (epoch+count unchanged on delete): the
    // empty-query "show all" fast path must SKIP the tombstoned id and count total correctly
    // (Codex cross-review regression). Warm again, delete via reconcile, re-check empty query.
    _ = eI.search("", sortKey: .name, limit: 100_000, now: now)   // ensure order cached
    let liveBefore = eI.search("", sortKey: .name, limit: 100_000, now: now).total
    try? fm.removeItem(atPath: root + "/" + uniqueName)
    _ = recI.reconcile(eventPaths: [root])                        // tombstone — NO invalidate, count unchanged
    let emptyAfter = eI.search("", sortKey: .name, limit: 100_000, now: now)
    let namesAfter = emptyAfter.ids.map { idxI.name(Int($0)) }
    check("empty-query fast path skips a tombstoned id (deleted file not shown)",
          !namesAfter.contains(uniqueName))
    check("empty-query total excludes tombstones (== live count)",
          emptyAfter.total == liveBefore - 1 && emptyAfter.ids.count == emptyAfter.total,
          "total=\(emptyAfter.total) liveBefore=\(liveBefore) shown=\(emptyAfter.ids.count)")
}

// ---- [13] incremental order maintenance ----
// Ground-truth oracle: a fresh SearchEngine over the SAME mutated index computes each order
// cold (computeOrder) — compared element-wise to the warm engine's order via the empty-query
// path (strips tombstones on both sides). Deterministic seeded LCG only, no system RNG.
inc13Block: do {
    var lcg: UInt64 = 0x9E3779B97F4A7C15
    func rnd() -> UInt64 { lcg = lcg &* 6364136223846793005 &+ 1442695040888963407; return lcg >> 16 }
    func rndInt(_ m: Int) -> Int { Int(rnd() % UInt64(max(1, m))) }
    let incKeys: [(SortKey, Bool)] = [(.name, true), (.name, false), (.path, true),
                                      (.size, true), (.dateModified, true), (.dateCreated, true)]
    func freshTruth(_ idx: FileIndex, _ k: SortKey, _ asc: Bool) -> [Int32] {
        let f = SearchEngine(index: idx); f.useFolderSizes = false
        return f.search("", sortKey: k, ascending: asc, limit: 100_000, now: now).ids
    }
    // [B1] brute-force children oracle over the parallel arrays, LIVE children only (excludes
    // tombstones). applyDirDiff (stable since the CSR/overlay design landed — see FileIndex.swift)
    // builds each touched dir's childOverlay newList strictly from the current on-disk listing,
    // so a name that disappears is dropped from its parent's overlay in the SAME reconcile that
    // tombstones it — never left dangling for a live, already-diffed parent. Both real consumers
    // of childrenLocked (resolveIdsLocked, subtreeSize) already defensively re-filter
    // `!deleted[...]`, confirming "live children" (not "every id ever parented here") is the
    // actual contract; matching that here instead of asserting tombstones linger. [S2] compared
    // as a SET: CSR is ascending-id order, childOverlay is directory-listing order — exact array
    // equality would go red after any reconcile even though the product (set/map/sum readers) is
    // correct.
    func bruteChildren(_ idx: FileIndex, _ d: Int32) -> Set<Int32> {
        var s = Set<Int32>()
        for i in 0..<idx.count where idx.parentOf(i) == d && !idx.isDeleted(i) { s.insert(Int32(i)) }
        return s
    }
    // childrenLocked() itself is allowed to surface tombstones (a directly-diffed dir's
    // childOverlay never does, but the CSR fallback rebuilt by buildLiveIndexes() doesn't purge
    // rows already flagged deleted=true out of the raw parent[] array either) — both real
    // consumers (resolveIdsLocked, subtreeSize) already re-filter `!deleted[...]` themselves, so
    // that's the actual contract, not "every id ever parented here." Filter here too so the
    // live-only oracle above compares apples to apples regardless of which path answered.
    func liveDebugChildren(_ idx: FileIndex, _ d: Int32) -> Set<Int32> {
        Set(idx._debugChildren(of: d).filter { !idx.isDeleted(Int($0)) })
    }

    // (a) Equivalence property test — THE load-bearing test: across 5 seeds, 200 random
    // mutation batches each, every incremental-sort key must equal a from-scratch order.
    var lastSeedDir = ""
    var lastIdxA: FileIndex? = nil
    var lastEWarm: SearchEngine? = nil
    var lastRec: Reconciler? = nil
    for seed: UInt64 in [1, 2, 3, 4, 5] {
        let seedDir = root + "/inc13/seed\(seed)"; mkdir(seedDir)
        // small seed corpus
        for i in 0..<40 { writeAbs(seedDir + "/f\(i).dat", bytes: 4 + i) }
        for d in 0..<5 { mkdir(seedDir + "/d\(d)"); for i in 0..<10 { writeAbs(seedDir + "/d\(d)/g\(i).dat", bytes: 4 + i) } }

        let idxA = FileIndex()
        _ = FileEnumerator(index: idxA).crawl(roots: [seedDir], exclude: [], mountPoints: [])
        idxA.buildLiveIndexes()
        let eWarm = SearchEngine(index: idxA); eWarm.useFolderSizes = false
        let rec = Reconciler(index: idxA, exclude: [])
        var seedMismatches = 0
        lcg = seed &* 0xD1B54A32D192ED03 &+ 1
        var liveFiles: [String] = (0..<40).map { seedDir + "/f\($0).dat" }
        for d in 0..<5 { for i in 0..<10 { liveFiles.append(seedDir + "/d\(d)/g\(i).dat") } }
        var opCounter = 0
        for _ in 0..<200 {
            let op = rndInt(5)
            opCounter += 1
            switch op {
            case 0:                                             // create file
                let p = seedDir + "/new_\(seed)_\(opCounter).dat"
                writeAbs(p, bytes: 4 + rndInt(200)); liveFiles.append(p)
            case 1:                                             // create dir subtree
                let dp = seedDir + "/nd_\(seed)_\(opCounter)"
                mkdir(dp)
                let cp = dp + "/child.dat"; writeAbs(cp, bytes: 3); liveFiles.append(cp)
            case 2:                                             // delete
                if !liveFiles.isEmpty {
                    let idx2 = rndInt(liveFiles.count)
                    let p = liveFiles.remove(at: idx2)
                    try? fm.removeItem(atPath: p)
                }
            case 3:                                             // attr-touch (utimes + truncate)
                if !liveFiles.isEmpty {
                    let p = liveFiles[rndInt(liveFiles.count)]
                    var tv = [timeval(tv_sec: Int(now) + opCounter, tv_usec: 0),
                              timeval(tv_sec: Int(now) + opCounter, tv_usec: 0)]
                    _ = utimes(p, &tv)
                    FileManager.default.createFile(atPath: p, contents: Data(count: 1 + rndInt(500)))
                }
            default:                                            // rename (tombstone + new append)
                if !liveFiles.isEmpty {
                    let idx2 = rndInt(liveFiles.count)
                    let p = liveFiles.remove(at: idx2)
                    let np = p + "_r\(opCounter)"
                    try? fm.moveItem(atPath: p, toPath: np)
                    liveFiles.append(np)
                }
            }
            _ = rec.reconcile(eventPaths: [seedDir])            // NO manual invalidate
            for (k, asc) in incKeys {
                let warm  = eWarm.search("", sortKey: k, ascending: asc, limit: 100_000, now: now).ids
                let truth = freshTruth(idxA, k, asc)
                if warm != truth { seedMismatches += 1 }
                check("inc13 seed\(seed) op\(opCounter) \(k) asc=\(asc): warm == scratch",
                      warm == truth, "warm=\(warm.count) truth=\(truth.count)")
            }
            // [B1(A)] folder-size delta equivalence — after EVERY reconcile, the maintained
            // (incremental-or-full, whichever _folderSizes() picks) array must equal a from-scratch
            // bottom-up pass exactly. _debugFolderSizes() advances fsizeAppliedSeq to `total`, so
            // this collapses each pending window to one record — the multi-record-window paths are
            // covered separately below (S4) without an intervening peek.
            let fMaint = idxA._debugFolderSizes()
            let fTruth = idxA._debugFolderSizesScratch()
            check("fsize seed\(seed) op\(opCounter): delta == scratch", fMaint == fTruth, "n=\(fMaint.count)")
            // [B1(C)] CSR+overlay children == brute (as sets) — sampled every 10 ops over a handful
            // of live dirs to keep the 5×200-op loop cheap while still exercising the overlay path
            // after every kind of mutation the switch above produces.
            if opCounter % 10 == 0 {
                var checked = 0
                for i in 0..<idxA.count where checked < 6 {
                    if idxA.isDir(i) && !idxA.isDeleted(i) {
                        let d = Int32(i)
                        check("csr children seed\(seed) op\(opCounter) d=\(d) == brute",
                              liveDebugChildren(idxA, d) == bruteChildren(idxA, d))
                        checked += 1
                    }
                }
            }
        }
        if seed == 5 {
            // keep the last seed's live index/engine/dir around for tests (b)-(f); avoid
            // rebuilding a fresh corpus for each.
            lastSeedDir = seedDir; lastIdxA = idxA; lastEWarm = eWarm; lastRec = rec
        } else {
            try? fm.removeItem(atPath: seedDir)
        }
        _ = seedMismatches   // already asserted per-op above; kept for potential debug use
    }

    guard let idxA = lastIdxA, let eWarm = lastEWarm, let rec = lastRec else {
        check("inc13 setup: last-seed index available for (b)-(f)", false)
        break inc13Block
    }
    let seedDir = lastSeedDir

    // (b) attr-only ⇒ name-family O(1) no-op (the storm-kill contract).
    _ = eWarm.search("", sortKey: .name, limit: 100_000, now: now)   // warm .name
    eWarm._debugResetOrderStats()
    let existingPath = seedDir + "/f0.dat"
    var tv = [timeval(tv_sec: Int(now) + 9, tv_usec: 0), timeval(tv_sec: Int(now) + 9, tv_usec: 0)]
    if fm.fileExists(atPath: existingPath) {
        _ = utimes(existingPath, &tv)
    } else {
        // f0.dat may have been renamed/deleted during (a)'s random walk; touch whatever
        // survives so the attr-only invariant still exercises a real mtime change.
        if let any = try? fm.contentsOfDirectory(atPath: seedDir).first(where: { !$0.hasPrefix("inc13") }) {
            _ = utimes(seedDir + "/" + any, &tv)
        }
    }
    _ = rec.reconcile(eventPaths: [seedDir])
    _ = eWarm.search("", sortKey: .name, limit: 100_000, now: now)
    let sB = eWarm._debugOrderStats()
    check("inc13(b) attr-only ⇒ name noop, no rebuild", sB.noop == 1 && sB.full == 0 && sB.incr == 0,
          "full=\(sB.full) incr=\(sB.incr) noop=\(sB.noop)")

    // (c) small structural batch ⇒ incremental, not full.
    eWarm._debugResetOrderStats()
    writeAbs(seedDir + "/inc_c_marker.dat", bytes: 4)
    _ = rec.reconcile(eventPaths: [seedDir])
    let warmC = eWarm.search("", sortKey: .name, limit: 100_000, now: now).ids
    let sC = eWarm._debugOrderStats()
    check("inc13(c) small append ⇒ incremental apply", sC.incr == 1 && sC.full == 0,
          "full=\(sC.full) incr=\(sC.incr)")
    check("inc13(c) incremental result == scratch", warmC == freshTruth(idxA, .name, true))

    // (c2) [B1(A)/S4] multi-record window: TWO reconciles with NO _debugFolderSizes() peek
    // between them, so a single incremental refresh must replay a window spanning several kinds
    // of record for the SAME window: append (a new dir + files + a nested subtree), an attr
    // (size-changing) touch, a plain tombstone, AND an append∩tombstone (a file created in the
    // first reconcile, deleted in the second, both still inside the unpeeked window) — plus a
    // subtree delete producing many tombstones in one go.
    let mwDir = seedDir + "/mw_window"; mkdir(mwDir)
    for i in 0..<8 { writeAbs(mwDir + "/mw\(i).dat", bytes: 10 + i) }
    let mwSubDir = mwDir + "/sub"; mkdir(mwSubDir)
    for i in 0..<4 { writeAbs(mwSubDir + "/s\(i).dat", bytes: 5 + i) }
    _ = rec.reconcile(eventPaths: [seedDir])            // reconcile #1: append dir+files+subtree — NO peek yet
    var tvMW = [timeval(tv_sec: Int(now) + 5000, tv_usec: 0), timeval(tv_sec: Int(now) + 5000, tv_usec: 0)]
    FileManager.default.createFile(atPath: mwDir + "/mw0.dat", contents: Data(count: 999))  // attr(size) on mw0
    _ = utimes(mwDir + "/mw0.dat", &tvMW)
    try? fm.removeItem(atPath: mwDir + "/mw1.dat")      // plain tombstone of a mw0-window sibling
    try? fm.removeItem(atPath: mwSubDir)                // subtree delete: sub/ + its 4 files ⇒ 5 tombstones
    _ = rec.reconcile(eventPaths: [seedDir])            // reconcile #2 — STILL no _debugFolderSizes() peek
    // mw1.dat was appended in reconcile #1 and tombstoned in reconcile #2, both inside this ONE
    // pending window: exercises the append∩tombstone (+current −current == 0) composition case.
    check("fsize multi-window (append+attr+tombstone+subtree-delete, no peek) == scratch",
          idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())
    check("csr children after multi-window subtree-delete == brute",
          idxA.dirIndex(forPath: mwDir).map { liveDebugChildren(idxA, $0) == bruteChildren(idxA, $0) } ?? false)

    // (d) log overflow ⇒ full-rebuild fallback, still equal.
    idxA._debugSetChangeLogCap(4)                      // force tiny cap
    eWarm._debugResetOrderStats()
    for i in 0..<50 { writeAbs(seedDir + "/ovf_\(i).dat", bytes: 3) }
    _ = rec.reconcile(eventPaths: [seedDir])            // >cap records ⇒ chgBase jumps past appliedSeq
    let warmD = eWarm.search("", sortKey: .name, limit: 100_000, now: now).ids
    let sD = eWarm._debugOrderStats()
    check("inc13(d) overflow ⇒ full rebuild fallback", sD.full >= 1, "full=\(sD.full)")
    check("inc13(d) fallback result still == scratch", warmD == freshTruth(idxA, .name, true))
    check("fsize overflow ⇒ full-rebuild == scratch", idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())
    // [S4] one MORE reconcile after the overflow full-rebuild — runs an INCREMENTAL replay window
    // post-reset (fsizeAppliedSeq now sits at the post-overflow chgBase), catching any drift a
    // full-rebuild-only assertion would miss (chgPayload must still be in lockstep after the halving).
    writeAbs(seedDir + "/post_ovf_marker.dat", bytes: 3)
    _ = rec.reconcile(eventPaths: [seedDir])
    check("fsize incremental-after-overflow == scratch", idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())

    // bumpMutation forces a full rebuild (chgBase jumps past the emptied log, including chgPayload,
    // in lockstep) — a check right after it would PASS even if bumpMutation forgot to clear
    // chgPayload (the full-rebuild branch never reads it). ONE more reconcile forces the very next
    // refresh to be an INCREMENTAL window, which DOES read chgPayload — the only case that would
    // actually catch a missing `chgPayload.removeAll` in bumpMutation.
    check("fsize before bumpMutation == scratch (baseline)",
          idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())
    idxA.bumpMutation()
    check("fsize after bumpMutation == scratch", idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())
    writeAbs(seedDir + "/post_bump_marker.dat", bytes: 3)
    _ = rec.reconcile(eventPaths: [seedDir])
    check("fsize incremental-after-bumpMutation == scratch",
          idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())

    // (e) snapshot-load resets the log; scratch equality holds.
    let blob13 = idxA.snapshotData(lastEventId: 0, savedAt: Double(now))
    let idxL = FileIndex(); _ = idxL.loadSnapshot(blob13); idxL.buildLiveIndexes()
    let eL = SearchEngine(index: idxL); eL.useFolderSizes = false
    let aE = eL.search("", sortKey: .name, limit: 100_000, now: now).ids
    let bE = freshTruth(idxL, .name, true)
    check("inc13(e) after snapshot-load order == scratch (log reset)", aE == bE)
    check("fsize after snapshot-load == scratch", idxL._debugFolderSizes() == idxL._debugFolderSizesScratch())
    check("csr overlay empty right after snapshot-load buildLiveIndexes", idxL._debugOverlayCount == 0)
    for d in 0..<min(idxL.count, 200) where idxL.isDir(d) && !idxL.isDeleted(d) {
        check("csr children after snapshot-load d=\(d) == brute",
              liveDebugChildren(idxL, Int32(d)) == bruteChildren(idxL, Int32(d)))
    }

    // [B1(C)] subtreeSize walk-result oracle: compare against a brute recursive sum over
    // non-deleted, VDIR-excluded size[] for a handful of dirs (covers the childrenLocked
    // migration in subtreeSize independent of the fsize delta machinery).
    func bruteSubtreeSize(_ idx: FileIndex, _ d: Int32) -> Int64 {
        var total: Int64 = 0
        var stack: [Int32] = [d]
        while let cur = stack.popLast() {
            if idx.isDeleted(Int(cur)) { continue }         // mirrors subtreeSize's own deleted-guard on pop
            if !idx.isDir(Int(cur)) { total += idx.row(Int(cur)).size }
            stack.append(contentsOf: bruteChildren(idx, cur))
        }
        return total
    }
    var subtreeChecked = 0
    for d in 0..<idxA.count where subtreeChecked < 10 {
        if idxA.isDir(d) && !idxA.isDeleted(d) {
            let did = Int32(d)
            check("subtreeSize d=\(did) == brute recursive sum",
                  idxA.subtreeSize(of: did) == bruteSubtreeSize(idxA, did))
            subtreeChecked += 1
        }
    }

    // [B1(C)] re-run buildLiveIndexes while the overlay is non-empty (applyDirDiff has been
    // writing childOverlay entries throughout (a)-(d) above without an intervening rebuild):
    // children must still equal brute, AND the overlay must be fully absorbed (empty) afterward.
    check("csr overlay non-empty before a forced rebuild (precondition for this case)",
          idxA._debugOverlayCount > 0, "overlay=\(idxA._debugOverlayCount)")
    idxA.buildLiveIndexes()
    check("csr overlay empty after buildLiveIndexes rebuild", idxA._debugOverlayCount == 0)
    var rebuildChecked = 0
    for d in 0..<idxA.count where rebuildChecked < 20 {
        if idxA.isDir(d) && !idxA.isDeleted(d) {
            check("csr children after forced rebuild d=\(d) == brute",
                  liveDebugChildren(idxA, Int32(d)) == bruteChildren(idxA, Int32(d)))
            rebuildChecked += 1
        }
    }
    check("fsize after forced buildLiveIndexes rebuild == scratch",
          idxA._debugFolderSizes() == idxA._debugFolderSizesScratch())

    // (f) Bench (informational, NOT asserted).
    let cold = SearchEngine(index: idxA); cold.useFolderSizes = false
    let t0 = ContinuousClock().now
    _ = cold.search("", sortKey: .name, limit: 100_000, now: now)      // full computeOrder
    let t1 = ContinuousClock().now
    writeAbs(seedDir + "/bench_one.dat", bytes: 3); _ = rec.reconcile(eventPaths: [seedDir])
    let t2 = ContinuousClock().now
    _ = eWarm.search("", sortKey: .name, limit: 100_000, now: now)     // incremental (+1 id)
    let t3 = ContinuousClock().now
    print("inc13(f) full=\(t0.duration(to: t1)) incr(+1)=\(t2.duration(to: t3)) n=\(idxA.count)")

    try? fm.removeItem(atPath: seedDir)
}

// ---- [13] informational large-scale (~1M target, raw-syscall fixture for speed) incremental
// bench (print only, not asserted). FileManager.createFile is far too slow per-call at this
// scale, so this fixture writes each file via raw open/write/close.
func fastWrite(_ p: String, bytes: Int) {
    let fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    if bytes > 0 { let buf = [UInt8](repeating: 1, count: bytes); _ = buf.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes) } }
    close(fd)
}
do {
    let benchRoot = NSTemporaryDirectory() + "mvsim-inc13-bench-\(getpid())"
    try? fm.removeItem(atPath: benchRoot)
    mkdir(benchRoot)
    let dirs = 1000, perDir = 1000                      // target ~1,000,000 files
    for d in 0..<dirs {
        let dp = benchRoot + "/b\(d)"
        mkdir(dp)
        for i in 0..<perDir { fastWrite(dp + "/f\(i).dat", bytes: 1) }
    }
    let idxB = FileIndex()
    _ = FileEnumerator(index: idxB).crawl(roots: [benchRoot], exclude: [], mountPoints: [])
    let csr0 = ContinuousClock().now
    idxB.buildLiveIndexes()                                             // CSR (csrChildIds/csrChildOff) build
    let csr1 = ContinuousClock().now
    let eB = SearchEngine(index: idxB); eB.useFolderSizes = false
    let tb0 = ContinuousClock().now
    _ = eB.search("", sortKey: .name, limit: 1_000_000, now: now)      // cold full computeOrder over ~1M
    let tb1 = ContinuousClock().now

    // [B1(E)] folder-size bench: cold full pass, then a +1-file incremental refresh — both must
    // still equal the from-scratch oracle at this scale (cheap correctness net, not just a print).
    let fz0 = ContinuousClock().now
    let fsFull = idxB._debugFolderSizes()
    let fz1 = ContinuousClock().now
    check("fsize (1M) cold full == scratch", fsFull == idxB._debugFolderSizesScratch())

    let recB = Reconciler(index: idxB, exclude: [])
    fastWrite(benchRoot + "/b0/bench_incr_one.dat", bytes: 1)
    let tb2 = ContinuousClock().now
    _ = recB.reconcile(eventPaths: [benchRoot])
    _ = eB.search("", sortKey: .name, limit: 1_000_000, now: now)      // warm incremental (+1 id)
    let tb3 = ContinuousClock().now
    let fz2 = ContinuousClock().now
    let fsIncr = idxB._debugFolderSizes()                               // +1-record incremental window
    let fz3 = ContinuousClock().now
    check("fsize (1M) incremental(+1) == scratch", fsIncr == idxB._debugFolderSizesScratch())

    // [B1(E)] radix vs comparator name-order bench at 1M — the [OI-8] `< 2×` keep/revert gate.
    let radixB = eB._debugBenchNameOrders()
    let ratio = radixB.radixSeconds > 0 ? radixB.comparatorSeconds / radixB.radixSeconds : 0
    print("B1(bench) n=\(idxB.count) csrBuild=\(csr0.duration(to: csr1)) " +
          "fsizeFull=\(fz0.duration(to: fz1)) fsizeIncr(+1)=\(fz2.duration(to: fz3)) " +
          "nameFull=\(tb0.duration(to: tb1)) nameIncr(+1)=\(tb2.duration(to: tb3)) " +
          "radix=\(String(format: "%.4f", radixB.radixSeconds))s " +
          "comparator=\(String(format: "%.4f", radixB.comparatorSeconds))s " +
          "ratio=\(String(format: "%.2f", ratio))x (n=\(radixB.n))")
    print("inc13(bench) n=\(idxB.count) full=\(tb0.duration(to: tb1)) incr(+1)=\(tb2.duration(to: tb3))")
    try? fm.removeItem(atPath: benchRoot)
}

// ---- [13g] VERIFIER-ADDED: coalescing / multi-record-per-window incremental apply ----
// The (a) property test queries after EVERY op, so each incremental apply only ever replays a
// SINGLE op's records — it NEVER exercises the coalescing paths the spec §4 leans on
// (append-then-tombstone, attr-then-tombstone, multi-attr-on-one-id, append-then-attr all in
// ONE replay window). Here we accumulate several reconciles WITHOUT an intervening query so a
// single query's incremental apply must replay a window containing multiple records for the
// same id, then compare to a cold from-scratch oracle for every key.
inc13gBlock: do {
    func truth(_ idx: FileIndex, _ k: SortKey, _ asc: Bool) -> [Int32] {
        let f = SearchEngine(index: idx); f.useFolderSizes = false
        return f.search("", sortKey: k, ascending: asc, limit: 100_000, now: now).ids
    }
    let gKeys: [(SortKey, Bool)] = [(.name, true), (.path, true),
                                    (.size, true), (.dateModified, true), (.dateCreated, true)]
    let gDir = root + "/inc13g"; mkdir(gDir)
    for i in 0..<60 { writeAbs(gDir + "/base\(i).dat", bytes: 10 + i) }
    let idxG = FileIndex()
    _ = FileEnumerator(index: idxG).crawl(roots: [gDir], exclude: [], mountPoints: [])
    idxG.buildLiveIndexes()
    let eG = SearchEngine(index: idxG); eG.useFolderSizes = false
    let recG = Reconciler(index: idxG, exclude: [])
    // Warm every key so the next query grows incrementally from a base.
    for (k, asc) in gKeys { _ = eG.search("", sortKey: k, ascending: asc, limit: 100_000, now: now) }

    // Accumulate a batch of reconciles with NO query in between:
    //  - append-then-tombstone: create X, reconcile; delete X, reconcile.
    var tv1 = [timeval(tv_sec: Int(now) + 1000, tv_usec: 0), timeval(tv_sec: Int(now) + 1000, tv_usec: 0)]
    writeAbs(gDir + "/coalesce_X.dat", bytes: 7); _ = recG.reconcile(eventPaths: [gDir])
    try? fm.removeItem(atPath: gDir + "/coalesce_X.dat"); _ = recG.reconcile(eventPaths: [gDir])
    //  - attr-then-tombstone: touch base1, reconcile; delete base1, reconcile.
    _ = utimes(gDir + "/base1.dat", &tv1); _ = recG.reconcile(eventPaths: [gDir])
    try? fm.removeItem(atPath: gDir + "/base1.dat"); _ = recG.reconcile(eventPaths: [gDir])
    //  - multi-attr on one id: touch base2 twice with different mtime AND size, reconcile each.
    var tv2 = [timeval(tv_sec: Int(now) + 2000, tv_usec: 0), timeval(tv_sec: Int(now) + 2000, tv_usec: 0)]
    FileManager.default.createFile(atPath: gDir + "/base2.dat", contents: Data(count: 999))
    _ = utimes(gDir + "/base2.dat", &tv2); _ = recG.reconcile(eventPaths: [gDir])
    var tv3 = [timeval(tv_sec: Int(now) + 3000, tv_usec: 0), timeval(tv_sec: Int(now) + 3000, tv_usec: 0)]
    FileManager.default.createFile(atPath: gDir + "/base2.dat", contents: Data(count: 3))
    _ = utimes(gDir + "/base2.dat", &tv3); _ = recG.reconcile(eventPaths: [gDir])
    //  - append-then-attr: create W, reconcile; change W's size+mtime, reconcile.
    writeAbs(gDir + "/coalesce_W.dat", bytes: 5); _ = recG.reconcile(eventPaths: [gDir])
    var tv4 = [timeval(tv_sec: Int(now) + 4000, tv_usec: 0), timeval(tv_sec: Int(now) + 4000, tv_usec: 0)]
    FileManager.default.createFile(atPath: gDir + "/coalesce_W.dat", contents: Data(count: 777))
    _ = utimes(gDir + "/coalesce_W.dat", &tv4); _ = recG.reconcile(eventPaths: [gDir])
    //  - plain moves/creates to widen the window: create a couple more.
    for i in 0..<5 { writeAbs(gDir + "/extra\(i).dat", bytes: 20 + i * 7) }
    _ = recG.reconcile(eventPaths: [gDir])

    // ONE query per key now — each must replay the whole accumulated window (multiple records
    // per id) and still equal a cold from-scratch order.
    eG._debugResetOrderStats()
    for (k, asc) in gKeys {
        let warm  = eG.search("", sortKey: k, ascending: asc, limit: 100_000, now: now).ids
        let cold  = truth(idxG, k, asc)
        check("inc13g coalesce \(k) asc=\(asc): warm == scratch", warm == cold,
              "warm=\(warm.count) cold=\(cold.count)")
    }
    let sG = eG._debugOrderStats()
    // At least one key must have taken the incremental path (window well under the size guard),
    // otherwise the coalescing code was never actually exercised and the test is vacuous.
    check("inc13g coalescing exercised the incremental path (not all full-rebuild)",
          sG.incr >= 1, "full=\(sG.full) incr=\(sG.incr) noop=\(sG.noop)")

    // [B1(A)] fsize coalesce: the SAME accumulated window above (append-then-tombstone,
    // attr-then-tombstone, multi-attr-on-one-id, append-then-attr, all with no intervening
    // fsize peek) must still equal the from-scratch fold — the composition proof in SPEC-B1
    // §2 depends on exactly these coalesced cases.
    check("fsize coalesce == scratch", idxG._debugFolderSizes() == idxG._debugFolderSizesScratch())
    try? fm.removeItem(atPath: gDir)
}

// ---- [B1(D)] radix == comparator name-order oracle (SPEC-B1-FINAL §4/§6D; radix kept — gate
// measured >2x, see SearchEngine.useNameRadix) ----
radixOrderBlock: do {
    // (1) corpus — the main fixture tree already has a realistic name mix (unicode, case, dupes).
    let (rMain, cMain) = engine._debugNameOrders()
    check("radix == comparator (main fixture corpus)", rMain == cMain, "n=\(rMain.count)")

    // (2) adversarial index — names designed to stress every branch of the radix tie-break:
    // shared 8-byte prefixes forcing the per-key64-group tie-sort (digit varies past byte 8),
    // a length tie inside a shared 8-byte prefix, a unicode-folded pair that differs in key64
    // (accent present vs absent — genuinely different strings, no filesystem collision), and
    // duplicate folded names in different dirs to hit the id tie-break.
    let advDir = root + "/radixadv"; mkdir(advDir)
    for i in 1...9 { writeAbs(advDir + "/AAAAAAAA_\(i).dat", bytes: 1) }   // shared 8B prefix, digit past it
    writeAbs(advDir + "/AAAAAAAAA.dat", bytes: 1)                          // 9 A's — length tie-break vs below
    writeAbs(advDir + "/AAAAAAAA.dat", bytes: 1)                           // exactly 8 A's — shares full key64
    writeAbs(advDir + "/CAFÉ.txt", bytes: 1)                               // accented, uppercase
    writeAbs(advDir + "/cafe.txt", bytes: 1)                               // unaccented, lowercase — distinct string
    writeAbs(advDir + "/dupA/same_name.dat", bytes: 1)                     // same folded name, different ids —
    writeAbs(advDir + "/dupB/same_name.dat", bytes: 1)                     // (different dirs so no fs collision)

    let idxAdv = FileIndex()
    _ = FileEnumerator(index: idxAdv).crawl(roots: [advDir], exclude: [], mountPoints: [])
    idxAdv.buildLiveIndexes()
    let eAdv = SearchEngine(index: idxAdv)
    let (rAdv, cAdv) = eAdv._debugNameOrders()
    check("radix == comparator (adversarial: 8B-prefix ties, unicode fold, id ties)",
          rAdv == cAdv, "n=\(rAdv.count)")
    try? fm.removeItem(atPath: advDir)
}

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

// content: oversized files are skipped AND reported (contentSkippedLarge) — not silently absent
FileManager.default.createFile(atPath: root + "/huge_blob.bin", contents: Data(count: (64 << 20) + 4096))
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()
let hugeRes = engine.search("content:secret-token", limit: 100, now: now)
check("content: oversized file counted in contentSkippedLarge", hugeRes.contentSkippedLarge >= 1)
check("content: oversized zero file not a false match", !has("content:secret-token", "huge_blob.bin"))
check("content: normal query flags no incompleteness", !engine.search("content:secret-token", limit: 100, now: now).contentIncomplete)
try? FileManager.default.removeItem(atPath: root + "/huge_blob.bin")
_ = rec.reconcile(eventPaths: [root]); engine.invalidate()

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

// type: operator — the precomputed typeClass bitmap MUST select the exact same set as
// the equivalent ext: clause it replaces (this is the whole correctness contract). The
// ext lists are read from the single source of truth so the test can never drift.
for c in FileTypeClass.categories {
    let extClause = "ext:" + c.exts.joined(separator: ",")
    check("type:\(c.name) ≡ \(extClause)",
          Set(names("type:\(c.name)")) == Set(names(extClause)))
    check("-type:\(c.name) ≡ -\(extClause)",
          Set(names("-type:\(c.name)")) == Set(names("-" + extClause)))
}
// union (comma list) ≡ the merged ext clause
let docImg = FileTypeClass.categories[0].exts + FileTypeClass.categories[1].exts
check("type:documents,images ≡ merged ext clause",
      Set(names("type:documents,images")) == Set(names("ext:" + docImg.joined(separator: ","))))
// gate is LIVE, not a no-op: real hits and real misses
check("type:documents finds the .pdf", has("type:documents", "manual.pdf"))
check("type:documents finds uppercase .PDF (folded)", has("type:documents", "SHOUT.PDF"))
check("type:audio finds the .mp3", has("type:audio", "song.mp3"))
check("type:documents excludes the .mp3", !has("type:documents", "song.mp3"))
check("type:apps excludes the .zip", !has("type:apps", "bundle.zip"))
check("unknown ext has no category (type:documents excludes .noext)", !has("type:documents", "notes.noext"))
// dual-category: .dmg is BOTH archives and apps
check("type:archives finds the .dmg", has("type:archives", "installer.dmg"))
check("type:apps finds the .dmg", has("type:apps", "installer.dmg"))
// media-chip trap: a DIRECTORY named thumbs.jpg matches type:images (== ext:jpg) but the
// chip's `file:` prefix must drop it while keeping the real image file inside.
check("type:images matches the thumbs.jpg directory (== ext:jpg)", has("type:images", "thumbs.jpg"))
check("file: type:images drops the directory but keeps the file",
      !has("file: type:images", "thumbs.jpg") && has("file: type:images", "picture.jpg"))
// unknown category name falls through to a literal term (not a filter), so it finds nothing here
check("type:bogus is a literal term, not a filter", names("type:bogus").isEmpty)


// path: fast prepass (fastPathScope) MUST equal the general full-path evaluator, byte for
// byte, on every needle & fixture — the whole correctness contract of the #7 speedup.
// _debugForceGeneralPath flips the engine to the trusted ground-truth scan for comparison.
func pathAB(_ needle: String, _ mode: MatchMode = .exact) -> (fast: [String], slow: [String]) {
    engine._debugForceGeneralPath = true
    let slow = names("path:\(needle)", mode: mode)
    engine._debugForceGeneralPath = false
    let fast = names("path:\(needle)", mode: mode)
    return (fast, slow)
}
// also exercise full-path MODE (⌃U): a bare term, path scope via the search scope
func fullPathAB(_ needle: String) -> (fast: [String], slow: [String]) {
    engine._debugForceGeneralPath = true
    let slow = names(needle, scope: .fullPath)
    engine._debugForceGeneralPath = false
    let fast = names(needle, scope: .fullPath)
    return (fast, slow)
}
let pathNeedles = [
    "report", "src", "src/a", "src/a/b/c/d", "d/leaf",          // deep nesting + segment joins
    "img/image", "g/image_0", "intl", "intl/한글", "한글파일",   // boundary spans + unicode
    "café", "CAFÉ", "kind/manual", "thumbs.jpg", "thumbs.jpg/pic", // fold + media-trap dir
    "dupA/twin", "twin_name", "/", "a/b/c", ".hidden/.sec",      // separator, single-char, hidden
    "zdir/marker_apple", "mvsim-tree", "no_such_path_xyz",       // whole-index root, non-match
    "z", ".", "t", "é",                                          // single-char needles (tailCap==0 path)
]
for nd in pathNeedles {
    let r = pathAB(nd)
    check("path:\(nd) fast≡general (\(r.slow.count) hits)", Set(r.fast) == Set(r.slow))
    let fp = fullPathAB(nd)
    check("⌃U '\(nd)' fast≡general", Set(fp.fast) == Set(fp.slow))
}
// concrete behaviour (not just fast≡slow): real hits, boundary spans, non-matches
check("path:src/a/b/c/d finds the deep leaf", has("path:src/a/b/c/d", "leaf.txt"))
check("path:g/image_0 (boundary span across img/) finds images", has("path:g/image_0", "image_001.png"))
check("path:intl finds the unicode file", has("path:intl", "한글파일.txt"))
check("path:thumbs.jpg finds the file inside the media-trap dir", has("path:thumbs.jpg", "picture.jpg"))
check("path:no_such_path_xyz finds nothing", pathAB("no_such_path_xyz").fast.isEmpty)
check("path:report excludes a file in a different dir", !has("path:src/a", "report.txt"))

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

// ---- Unix-socket query server (mvfind/MCP backend) round-trip ----
do {
    let sockPath = root + "/qs.sock"
    let server = QueryServer(index: index, runStats: nil, socketPath: sockPath,
                             indexing: { false })
    let ok = server.start()
    check("queryserver: starts and binds the socket", ok && fm.fileExists(atPath: sockPath))

    // minimal blocking client: connect, send one JSON line, read one JSON line.
    func roundTrip(_ json: String, path: String = sockPath) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pb = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: pb.count) { d in
                for (i, b) in pb.enumerated() { d[i] = b }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let conn = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if conn != 0 { return nil }
        var line = json; line.append("\n")
        _ = line.utf8CString.withUnsafeBufferPointer { _ in }
        let sent = Array(line.utf8)
        _ = sent.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }
        return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
    }

    if let r = roundTrip("{\"v\":1,\"q\":\"report\",\"limit\":50}") {
        let paths = (r["paths"] as? [String]) ?? []
        check("queryserver: valid query returns matching paths + meta",
              (r["ok"] as? Bool) == true && (r["total"] as? Int ?? 0) > 0
              && paths.contains { ($0 as NSString).lastPathComponent == "report.txt" }
              && (r["indexCount"] as? Int ?? 0) == index.count)
    } else { check("queryserver: valid query returns matching paths + meta", false, "no response") }

    // countOnly returns total, no paths
    if let r = roundTrip("{\"v\":1,\"q\":\"report\",\"countOnly\":true}") {
        check("queryserver: countOnly returns total without paths",
              (r["ok"] as? Bool) == true && r["paths"] == nil && (r["total"] as? Int ?? 0) > 0)
    } else { check("queryserver: countOnly returns total without paths", false) }

    // structured fields
    if let r = roundTrip("{\"v\":1,\"q\":\"report\",\"limit\":5,\"fields\":[\"path\",\"size\",\"isDir\"]}"),
       let results = r["results"] as? [[String: Any]], let first = results.first {
        check("queryserver: fields=[…] returns structured rows",
              first["path"] != nil && first["name"] != nil && first["isDir"] != nil)
    } else { check("queryserver: fields=[…] returns structured rows", false) }

    // malformed JSON → explicit error, not a crash / silent stale
    if let r = roundTrip("{ this is not json ") {
        check("queryserver: malformed request → ok:false with error",
              (r["ok"] as? Bool) == false && r["error"] != nil)
    } else { check("queryserver: malformed request → ok:false with error", false) }

    // concurrency: two simultaneous connections both answered
    let g = DispatchGroup(); var a: [String: Any]? = nil; var b: [String: Any]? = nil
    g.enter(); DispatchQueue.global().async { a = roundTrip("{\"v\":1,\"q\":\"data\"}"); g.leave() }
    g.enter(); DispatchQueue.global().async { b = roundTrip("{\"v\":1,\"q\":\"src\"}"); g.leave() }
    g.wait()
    check("queryserver: concurrent connections both answered",
          (a?["ok"] as? Bool) == true && (b?["ok"] as? Bool) == true)

    // SIGPIPE regression: a client that sends a request then hangs up WITHOUT reading
    // must not kill the server (a write to the closed socket would raise SIGPIPE, whose
    // default action terminates the process — this killed the app when mvfind connected).
    func fireAndClose(_ json: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); if fd < 0 { return }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let pb = Array(sockPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: pb.count) { d in
                for (i, b) in pb.enumerated() { d[i] = b } } }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        if withUnsafePointer(to: &addr, { ap in ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, len) } }) == 0 {
            var l = json; l.append("\n")
            _ = Array(l.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)   // hang up immediately, before reading the response
    }
    for _ in 0..<5 { fireAndClose("{\"v\":1,\"q\":\"report\",\"limit\":100}") }
    usleep(50_000)   // let the server's writes hit the closed sockets
    check("queryserver: client hang-up before read does NOT kill the server (SIGPIPE ignored)",
          (roundTrip("{\"v\":1,\"q\":\"data\"}")?["ok"] as? Bool) == true)

    // CONCURRENT DIFFERING-OPTIONS (the engineLock CRITICAL fix, completeness review F3):
    // fire many folders-first=true / =false requests at once; every true response MUST
    // have all directories before any file. Under the pre-fix shared-property race a
    // true request could pick up a concurrent false and interleave dirs among files.
    func foldersFirstHonored(_ r: [String: Any]?) -> Bool {
        guard let rows = r?["results"] as? [[String: Any]] else { return true }   // nil = skip (connection saturation, not an ordering fact)
        var sawFile = false
        for row in rows {
            let isDir = (row["isDir"] as? Bool) ?? false
            if isDir && sawFile { return false }     // a dir AFTER a file → NOT folders-first
            if !isDir { sawFile = true }
        }
        return true
    }
    let ffReq = "{\"v\":1,\"q\":\"a\",\"foldersFirst\":true,\"fields\":[\"path\",\"isDir\"],\"limit\":200}"
    let plainReq = "{\"v\":1,\"q\":\"a\",\"foldersFirst\":false,\"fields\":[\"path\",\"isDir\"],\"limit\":200}"
    let cg = DispatchGroup()
    var ffOK = true; var ffChecked = 0
    let vlock = NSLock()
    for k in 0..<8 {   // < listen backlog (16); alternating options exercise the shared-property race
        cg.enter()
        DispatchQueue.global().async {
            let r = roundTrip(k % 2 == 0 ? ffReq : plainReq)
            if k % 2 == 0, r != nil {
                let ok = foldersFirstHonored(r)
                vlock.lock(); ffChecked += 1; if !ok { ffOK = false }; vlock.unlock()
            }
            cg.leave()
        }
    }
    cg.wait()
    check("queryserver: concurrent differing options don't cross-contaminate (foldersFirst honored)",
          ffOK && ffChecked > 0, "checked \(ffChecked)")

    // scopeRoot that can't resolve must NOT become a whole-disk search (Codex+red-team)
    if let r = roundTrip("{\"v\":1,\"q\":\"report\",\"scopeRoot\":\"/no/such/dir/xyz\"}") {
        check("queryserver: unresolvable scopeRoot returns empty (not whole-disk)",
              (r["ok"] as? Bool) == true && (r["total"] as? Int ?? -1) == 0)
    } else { check("queryserver: unresolvable scopeRoot returns empty (not whole-disk)", false) }
    // strict protocol: unknown enum / version → error, not a silent default
    if let r = roundTrip("{\"v\":1,\"q\":\"report\",\"mode\":\"bogus\"}") {
        check("queryserver: unknown mode → bad_request", (r["ok"] as? Bool) == false && r["error"] != nil)
    } else { check("queryserver: unknown mode → bad_request", false) }
    if let r = roundTrip("{\"v\":99,\"q\":\"report\"}") {
        check("queryserver: unsupported version → error", (r["ok"] as? Bool) == false)
    } else { check("queryserver: unsupported version → error", false) }
    // useFolderSizes cache-key: two requests with different flags must not reuse a stale
    // size order (the reviewers' single-threaded bug — verified via the engine directly)
    do {
        let e = SearchEngine(index: index)
        // full order (not top-5) so a difference anywhere in the folder ranking shows.
        e.useFolderSizes = true;  let a = e.search("", sortKey: .size, limit: 1_000_000, now: now).ids
        e.useFolderSizes = false; let b = e.search("", sortKey: .size, limit: 1_000_000, now: now).ids
        e.useFolderSizes = true;  let a2 = e.search("", sortKey: .size, limit: 1_000_000, now: now).ids
        // Pre-fix (cache ignores useFolderSizes) b would equal a and this a!=b fails.
        check("size sort: useFolderSizes actually changes the order (cache key is live)", a != b)
        check("size sort: returning to useFolderSizes reproduces the same order (no stale reuse)", a == a2)
    }

    server.stop()
    check("queryserver: connect fails after stop (listener closed)", roundTrip("{\"v\":1,\"q\":\"x\"}") == nil)
    // a fresh server unlink-before-binds, so restart works even with the old file present
    let server2 = QueryServer(index: index, runStats: nil, socketPath: sockPath, indexing: { false })
    check("queryserver: restart rebinds cleanly over a leftover socket file", server2.start())
    if let r = roundTrip("{\"v\":1,\"q\":\"report\"}") {
        check("queryserver: restarted server answers", (r["ok"] as? Bool) == true)
    } else { check("queryserver: restarted server answers", false) }
    server2.stop()
}

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

    // REGRESSION (both reviewers, highest-impact): a most-run file that sorts
    // alphabetically LAST must survive a small display limit AND hideHidden — the old
    // code capped to `limit` in name order BEFORE the run-count reorder, dropping it.
    // Reconcile a real new file into the index (also exercises the _appendOne mask path).
    let zPath = rroot + "/zzz_report.txt"
    write("runAB/zzz_report.txt", bytes: 4)
    _ = Reconciler(index: rIdx, exclude: []).reconcile(eventPaths: [rroot])
    for _ in 0..<9 { rStats.record(path: zPath, now: rnow) }          // most-run of all
    rEng.invalidate()
    let topHot = rEng.search("report", sortKey: .runCount, ascending: false, limit: 2, now: rnow)
                    .ids.map { rIdx.name(Int($0)) }
    check("runcount: alphabetically-last most-run file survives a small limit (no pre-cap drop)",
          topHot.first == "zzz_report.txt", topHot.joined(separator: ","))
    rEng.hideHidden = true
    let topHotHidden = rEng.search("report", sortKey: .runCount, ascending: false, limit: 2, now: rnow)
                          .ids.map { rIdx.name(Int($0)) }
    check("runcount: survives limit + hideHidden together (cap applied once, at the end)",
          topHotHidden.first == "zzz_report.txt", topHotHidden.joined(separator: ","))
    rEng.hideHidden = false

    // REINDEX SURVIVAL (buildLiveIndexes gen-bump fix, completeness review F4): a full
    // re-crawl churns entry ids; run history is path-keyed and re-resolves. If
    // buildLiveIndexes didn't bump the gen, a frecency map resolved while childrenOf was
    // empty (during the crawl) would be cached stale and run-count would silently break.
    // Resolve frecency BEFORE the rebuild completes to exercise exactly that window.
    rIdx.clear()
    _ = FileEnumerator(index: rIdx).crawl(roots: [rroot])
    _ = rEng.search("report", sortKey: .runCount, ascending: false, limit: 5, now: rnow)  // resolve pre-buildLiveIndexes
    rIdx.buildLiveIndexes()
    rEng.invalidate()
    let afterReindex = rEng.search("report", sortKey: .runCount, ascending: false, limit: 5, now: rnow)
                          .ids.map { rIdx.name(Int($0)) }
    check("runcount: run history survives a full reindex (path-keyed, gen-bump re-resolve)",
          afterReindex.first == "zzz_report.txt", afterReindex.joined(separator: ","))
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
