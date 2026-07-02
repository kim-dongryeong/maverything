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
let fm = FileManager.default
try? fm.removeItem(atPath: root)

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

let oldTime = now - 200 * 86_400   // ~200 days ago
write("report.txt", bytes: 200, mtime: now)
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
write("src/a/b/c/d/leaf.txt", bytes: 5)                // deep nesting
write(".hidden/.secret.txt", bytes: 5)                 // hidden

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

// scope
check("path: 'path:data' finds data.json via path", has("data", "data.json", scope: .fullPath))
check("name: plain term ignores parent dir name", !has("data", "leaf.txt"))

// unicode (ASCII-fold leaves non-ASCII intact; substring still works)
check("unicode: '한글' finds 한글파일.txt", has("한글", "한글파일.txt"))

// relevance sort sanity (fuzzy: exact-ish beats scattered)
let rel = engine.search("app", mode: .fuzzy, sortKey: .relevance, limit: 10, now: now).ids.map { index.name(Int($0)) }
check("relevance: 'app' ranks app.swift/AppModel.swift on top",
      rel.prefix(2).contains("app.swift") || rel.prefix(2).contains("AppModel.swift"), rel.prefix(3).joined(separator: ","))

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

// ---- snapshot round-trip ----
let blob = index.snapshotData(lastEventId: 777, savedAt: 1.0)
let idx2 = FileIndex()
let meta = idx2.loadSnapshot(blob); idx2.buildLiveIndexes()
let e2 = SearchEngine(index: idx2)
check("snapshot: lastEventId preserved", meta?.lastEventId == 777)
check("snapshot: 'png' count survives round-trip",
      e2.search("png", limit: 10_000, now: now).total == engine.search("png", limit: 10_000, now: now).total)

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
exit(failed == 0 ? 0 : 1)
