import Darwin
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
    usage: mvfind <query…> [--fuzzy|--wildcard] [--path] [--sort name|size|date|relevance|runcount]
                           [--limit N] [--count] [-0] [--live|--snapshot] [--json]
      query supports: terms (AND), "phrases", -not, ext:swift, size:>1mb, dm:today, path:foo, name:foo
      by default queries the running app's LIVE index over a socket, falling back to the
      saved snapshot; --live forces the socket, --snapshot forces the file, --json emits raw

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
var forceLive = false        // --live: require the running app's socket
var forceSnapshot = false    // --snapshot: skip the socket, read the saved index
var jsonOut = false          // --json: emit the server's raw JSON
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
    case "--live": forceLive = true
    case "--snapshot": forceSnapshot = true
    case "--json": jsonOut = true
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

let bench = ProcessInfo.processInfo.environment["MVFIND_BENCH"].flatMap(Int.init).map { $0 > 0 } ?? false

// --- try the resident app's LIVE index over the socket first (real-time, never
//     stale). --snapshot forces the file; bench measures the LOCAL engine so it skips. ---
func modeStr(_ m: MatchMode) -> String {
    switch m { case .exact: "exact"; case .fuzzy: "fuzzy"; case .wildcard: "wildcard"; case .regex: "regex" }
}
func sortStr(_ s: SortKey) -> String {
    switch s { case .name: "name"; case .path: "path"; case .size: "size"; case .dateModified: "date"
               case .dateCreated: "created"; case .relevance: "relevance"; case .runCount: "runcount" }
}

/// One-shot socket round-trip to the app. Returns the parsed response, or nil if the
/// app isn't reachable within ~300 ms.
let qsDebug = ProcessInfo.processInfo.environment["MV_QS_DEBUG"] == "1"
func qslog(_ s: String) { if qsDebug { FileHandle.standardError.write(Data("mvfind[qs]: \(s)\n".utf8)) } }
func socketQuery() -> [String: Any]? {
    let path = QueryServer.defaultSocketPath()
    qslog("path=\(path)")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { qslog("socket() failed errno=\(errno)"); return nil }
    defer { close(fd) }
    // A local unix-socket connect is instant (success or ECONNREFUSED) so app presence
    // is detected immediately — the timeout only bounds the QUERY read, which on the
    // app's FIRST query builds a cold 1.9M sort order (~1s). Keep it generous; a slow
    // response just falls back to the snapshot.
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pb = Array(path.utf8)
    if pb.count >= MemoryLayout.size(ofValue: addr.sun_path) { return nil }
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: UInt8.self, capacity: pb.count) { d in
            for (i, b) in pb.enumerated() { d[i] = b }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let conn = withUnsafePointer(to: &addr) { ap in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if conn != 0 { qslog("connect() failed errno=\(errno) (\(String(cString: strerror(errno))))"); return nil }
    qslog("connected")
    var req: [String: Any] = ["v": 1, "q": query, "mode": modeStr(mode),
                              "scope": scope == .fullPath ? "path" : "name",
                              "sort": sortStr(sort), "limit": limit, "countOnly": countOnly]
    if jsonOut { req["fields"] = ["path", "name", "size", "mtime", "isDir"] }
    guard var line = try? JSONSerialization.data(withJSONObject: req) else { qslog("encode failed"); return nil }
    line.append(0x0A)
    let wrote = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    qslog("wrote=\(wrote) of \(line.count) errno=\(errno)")
    if wrote <= 0 { return nil }
    var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { qslog("read n=\(n) errno=\(errno) (\(String(cString: strerror(errno)))) total=\(out.count)"); break }
        out.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
    }
    qslog("read \(out.count) bytes: \(String(decoding: out.prefix(80), as: UTF8.self))")
    return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
}

if !forceSnapshot && !bench {
    if let r = socketQuery(), (r["ok"] as? Bool) == true {
        let indexing = (r["indexing"] as? Bool) ?? false
        if jsonOut {
            let s = String(decoding: (try? JSONSerialization.data(withJSONObject: r,
                            options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            print(s)
        } else if countOnly {
            print(r["total"] as? Int ?? 0)
        } else {
            let out = FileHandle.standardOutput
            for p in (r["paths"] as? [String]) ?? [] { out.write(Data((p + (nul ? "\0" : "\n")).utf8)) }
        }
        let src = indexing ? "live(indexing)" : "live"
        FileHandle.standardError.write(Data(String(
            format: "— %d match%@ in %.1f ms via %@\n", r["total"] as? Int ?? 0,
            (r["total"] as? Int ?? 0) == 1 ? "" : "es", r["queryMillis"] as? Double ?? 0, src).utf8))
        exit(0)
    }
    if forceLive {
        FileHandle.standardError.write(Data("mvfind: --live requested but the app isn't running (no socket)\n".utf8))
        exit(1)
    }
}

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
// Share the app's run-history so `--sort runcount` / relevance frecency work from the CLI.
engine.runStats = RunStats(url: Snapshot.defaultURL().deletingLastPathComponent()
    .appendingPathComponent("runstats.json"))
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
