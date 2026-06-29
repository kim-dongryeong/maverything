import Foundation
import MaverythingCore

// Headless harness: crawl a root, verify path reconstruction, run timed searches.
//   swift run -c release mvtest [rootPath] [query1] [query2] ...

let args = CommandLine.arguments
let root = args.count > 1 ? args[1] : NSHomeDirectory()
let queries = args.count > 2 ? Array(args[2...]) : ["png", "swift", ".plist", "system"]

print("=== Maverything self-test ===")
print("root: \(root)\n")

let index = FileIndex()
let enumerator = FileEnumerator(index: index)
// restrictToVolume skips cross-volume mounts (e.g. Google Drive / network shares)
// that live under the root — these are slow virtual filesystems we don't want.
let stats = enumerator.crawl(roots: [root], restrictToVolume: true)

print(String(format: "indexed %d items (%d files, %d dirs, %d open-errors) in %.2fs  →  %.0f entries/sec",
             stats.total, stats.files, stats.dirs, stats.openErrors, stats.seconds,
             Double(stats.total) / max(stats.seconds, 0.0001)))
print("index.count = \(index.count)\n")

// Verify path reconstruction against the real filesystem for a sample of entries.
var checked = 0, ok = 0
var i = 1
let step = max(1, index.count / 500)
while i < index.count {
    let p = index.path(i)
    var st = stat()
    if lstat(p, &st) == 0 { ok += 1 }
    checked += 1
    i += step
}
print("path reconstruction: \(ok)/\(checked) sampled paths exist on disk\(ok == checked ? "  ✓" : "  ✗ MISMATCH")\n")

let engine = SearchEngine(index: index)
for q in queries {
    let r = engine.search(q, sortKey: .name, ascending: true, limit: 50)
    print(String(format: "query %-12@  →  %7d matches in %6.2f ms", q as NSString, r.total, r.queryMillis))
    for id in r.ids.prefix(3) {
        print("        \(index.path(Int(id)))")
    }
}

// Snapshot round-trip
print("\n=== snapshot round-trip ===")
let blob = index.snapshotData(lastEventId: 12345, savedAt: 1.0)
print("serialized: \(blob.count / 1024) KB for \(index.count) entries")
let idx2 = FileIndex()
if let meta = idx2.loadSnapshot(blob) {
    idx2.buildLiveIndexes()
    let e2 = SearchEngine(index: idx2)
    let before = engine.search("png", limit: 100000).total
    let after = e2.search("png", limit: 100000).total
    print("loaded \(idx2.count) entries, lastEventId=\(meta.lastEventId)")
    print("'png' matches  before=\(before)  after-reload=\(after)  \(before == after ? "✓" : "✗ MISMATCH")")
    // path integrity after reload
    var ok2 = 0, ck2 = 0, i2 = 1
    let st2 = max(1, idx2.count / 300)
    while i2 < idx2.count { var st = stat(); if lstat(idx2.path(i2), &st) == 0 { ok2 += 1 }; ck2 += 1; i2 += st2 }
    print("reloaded path integrity: \(ok2)/\(ck2) exist  \(ok2 == ck2 ? "✓" : "✗")")
} else {
    print("✗ loadSnapshot failed")
}

// Sort timing
for key in [("name", SortKey.name), ("size", .size), ("date", .dateModified)] {
    let c = ContinuousClock()
    let s = c.now
    let r = engine.search("", sortKey: key.1, ascending: false, limit: 20)
    let ms = Double(s.duration(to: c.now).components.attoseconds) / 1e15
    print(String(format: "\nsort by %-5@ (first build) top result: %@  [%.1f ms]", key.0 as NSString,
                 r.ids.first.map { index.path(Int($0)) } ?? "—" as String, ms))
}
