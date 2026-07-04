import Foundation
import MaverythingCore

// mvfind — terminal companion to the Maverything app. Loads the app's saved index
// snapshot (instant, no crawl) and searches it, so you get the same system-wide
// instant search from the command line. Falls back to a live crawl if there's no
// snapshot yet.
//
//   mvfind <query…> [--fuzzy|--wildcard] [--path] [--sort name|size|date|relevance]
//                   [--limit N] [-0] [--count]
//   mvfind "*.swift" --wildcard --sort size --limit 20
//   mvfind report ext:pdf size:>1mb

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mvfind <query…> [--fuzzy|--wildcard] [--path] [--sort name|size|date|relevance]
                           [--limit N] [--count] [-0]
      query supports: terms (AND), "phrases", -not, ext:swift, size:>1mb, dm:today, path:foo, name:foo

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var mode: MatchMode = .exact
var scope: SearchScope = .nameOnly
var sort: SortKey = .name
var limit = 200
var nul = false
var countOnly = false
var terms: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--fuzzy": mode = .fuzzy
    case "--wildcard", "--glob": mode = .wildcard
    case "--path": scope = .fullPath
    case "--count": countOnly = true
    case "-0", "--print0": nul = true
    case "--limit": i += 1; limit = i < args.count ? (Int(args[i]) ?? limit) : limit
    case "--sort":
        i += 1
        switch (i < args.count ? args[i] : "") {
        case "size": sort = .size
        case "date", "dm": sort = .dateModified
        case "relevance", "rel": sort = .relevance
        case "runcount", "run", "frecency": sort = .runCount
        case "path": sort = .path
        default: sort = .name
        }
    case "-h", "--help": usage()
    default: terms.append(a)
    }
    i += 1
}
if terms.isEmpty && !countOnly { usage() }
let query = terms.joined(separator: " ")

// Load the app's snapshot for instant results; otherwise crawl live.
let index = FileIndex()
let snapURL = Snapshot.defaultURL()
var source = "snapshot"
if let data = try? Data(contentsOf: snapURL), index.loadSnapshot(data) != nil {
    index.buildLiveIndexes()
} else {
    source = "live-crawl"
    FileHandle.standardError.write(Data("mvfind: no snapshot — crawling (run the app once for instant results)…\n".utf8))
    FileEnumerator(index: index).crawl(roots: Volumes.localCrawlRoots(),
                                       restrictToVolume: false, exclude: Volumes.defaultExclusions(),
                                       mountPoints: Volumes.allMountPoints())
    index.buildLiveIndexes()
}

let engine = SearchEngine(index: index)
let now = Date().timeIntervalSince1970
// MVFIND_BENCH=N: run the query N times in-process and report each engine ms —
// isolates WARM engine latency from snapshot load + first-query sort-order build
// (the honest number to compare against a resident app queried over IPC).
if let benchN = ProcessInfo.processInfo.environment["MVFIND_BENCH"].flatMap(Int.init), benchN > 0 {
    // MVFIND_NOBLOOM=1: disable the character-bloom prefilter to measure its speedup.
    if ProcessInfo.processInfo.environment["MVFIND_NOBLOOM"] == "1" {
        index._debugSetAllMasksAllBits()
        FileHandle.standardError.write(Data("bench: bloom prefilter DISABLED\n".utf8))
    }
    for i in 1...benchN {
        let b = engine.search(query, mode: mode, scope: scope, sortKey: sort,
                              ascending: sort != .relevance && sort != .runCount, limit: limit, now: now)
        FileHandle.standardError.write(Data(String(
            format: "bench[%d]: %d matches in %.2f ms\n", i, b.total, b.queryMillis).utf8))
    }
    exit(0)
}
let r = engine.search(query, mode: mode, scope: scope, sortKey: sort,
                      ascending: sort != .relevance && sort != .runCount, limit: countOnly ? 5_000_000 : limit, now: now)

if countOnly {
    print(r.total)
    exit(0)
}

let out = FileHandle.standardOutput
for id in r.ids {
    let line = index.path(Int(id)) + (nul ? "\0" : "\n")
    out.write(Data(line.utf8))
}
FileHandle.standardError.write(Data(String(
    format: "— %d match%@ (%@) in %.1f ms via %@%@\n",
    r.total, r.total == 1 ? "" : "es", "\(index.count) indexed", r.queryMillis, source,
    r.truncated ? ", showing \(r.ids.count)" : "").utf8))
