import Darwin
import Foundation
import MaverythingCore

// mv-mcp — a Model Context Protocol server exposing Maverything's instant, system-wide
// file search. MCP is an OPEN, vendor-neutral standard, so this works with ANY MCP
// client — Claude Desktop, Cline, Continue, Zed, Cursor, custom agents — not just one.
// It's a thin bridge: each `search` tool call goes to the running app's LIVE index over
// the Unix socket, and falls back to the saved snapshot when the app is closed — so an
// agent gets real-time results, never a stale index. Newline-delimited JSON-RPC 2.0 over
// stdio.
//
// Register (any MCP client; Claude Desktop config path shown):
//   ~/Library/Application Support/Claude/claude_desktop_config.json
//   { "mcpServers": { "maverything": { "command": "/usr/local/bin/mv-mcp" } } }

let protocolVersion = "2024-11-05"
let serverName = "maverything"
let serverVersion = "0.1"

// MARK: - snapshot fallback (loaded lazily, once, if the app socket is unreachable)

var fallbackIndex: FileIndex?
var fallbackEngine: SearchEngine?
func ensureFallback() -> SearchEngine? {
    if let e = fallbackEngine { return e }
    let idx = FileIndex()
    guard let data = try? Data(contentsOf: Snapshot.defaultURL()), idx.loadSnapshot(data) != nil else {
        return nil   // no snapshot yet → the app has never run
    }
    idx.buildLiveIndexes()
    let eng = SearchEngine(index: idx)
    eng.runStats = RunStats(url: Snapshot.defaultURL().deletingLastPathComponent()
        .appendingPathComponent("runstats.json"))
    fallbackIndex = idx; fallbackEngine = eng
    return eng
}

// MARK: - the socket-first search (same protocol the app's QueryServer speaks)

func socketSearch(_ req: [String: Any]) -> [String: Any]? {
    let path = QueryServer.defaultSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
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
    if conn != 0 { return nil }
    guard var line = try? JSONSerialization.data(withJSONObject: req) else { return nil }
    line.append(0x0A)
    let sent = line.withUnsafeBytes { (raw) -> Bool in
        var off = 0
        while off < raw.count {
            let w = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
            if w <= 0 { return false }
            off += w
        }
        return true
    }
    if !sent { return nil }
    var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
    }
    return (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
}

/// Run a search: live socket first, snapshot fallback. Returns (results, source, indexing).
func runSearch(query: String, mode: String, sort: String, scope: String,
               limit: Int, countOnly: Bool) -> (rows: [[String: Any]], total: Int, source: String, indexing: Bool)? {
    var req: [String: Any] = ["v": 1, "q": query, "mode": mode, "scope": scope, "sort": sort,
                              "limit": limit, "countOnly": countOnly]
    req["fields"] = ["path", "name", "size", "mtime", "isDir"]
    if let r = socketSearch(req), (r["ok"] as? Bool) == true {
        let rows = (r["results"] as? [[String: Any]]) ?? []
        return (rows, r["total"] as? Int ?? rows.count,
                (r["indexing"] as? Bool) == true ? "live(indexing)" : "live", (r["indexing"] as? Bool) ?? false)
    }
    // fallback: local snapshot engine
    guard let eng = ensureFallback(), let idx = fallbackIndex else { return nil }
    let m: MatchMode = { switch mode { case "fuzzy": .fuzzy; case "wildcard": .wildcard
                                       case "regex": .regex; default: .exact } }()
    let sk: SortKey = { switch sort { case "size": .size; case "date": .dateModified
                                      case "created": .dateCreated; case "path": .path
                                      case "relevance": .relevance; case "runcount": .runCount; default: .name } }()
    let sc: SearchScope = scope == "path" ? .fullPath : .nameOnly
    let asc = !(sk == .relevance || sk == .runCount || sk == .size || sk == .dateModified || sk == .dateCreated)
    let res = eng.search(query, mode: m, scope: sc, sortKey: sk, ascending: asc,
                         limit: countOnly ? 5_000_000 : limit, now: Date().timeIntervalSince1970)
    if countOnly { return ([], res.total, "snapshot", false) }
    let rows: [[String: Any]] = res.ids.prefix(limit).map { id in
        let row = idx.row(Int(id))
        return ["path": row.path, "name": row.name, "size": row.size, "mtime": row.mtime, "isDir": row.isDir]
    }
    return (rows, res.total, "snapshot", false)
}

// MARK: - JSON-RPC plumbing (newline-delimited over stdio)

func send(_ obj: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}
func result(id: Any, _ value: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": value]) }
func error(id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

let searchToolSchema: [String: Any] = [
    "name": "search",
    "description": "Instantly search every file on this Mac by name (hidden and system files included) "
        + "using Maverything's live index. Supports Everything-style query syntax: space = AND, "
        + "ext:pdf,jpg, size:>10mb, dm:today (modified date), path:foo, folder:/file:, -exclude, "
        + "\"quoted phrases\", a|b (OR). Returns matching file paths with size/mtime.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query (Everything syntax)."],
            "mode": ["type": "string", "enum": ["exact", "fuzzy", "wildcard", "regex"],
                     "description": "Match mode. Default exact (substring; * and ? auto-glob)."],
            "sort": ["type": "string", "enum": ["name", "path", "size", "date", "created", "relevance", "runcount"],
                     "description": "Sort key. Default name. 'runcount' = most-opened first."],
            "scope": ["type": "string", "enum": ["name", "path"],
                      "description": "Match the file name (default) or the full path."],
            "limit": ["type": "integer", "description": "Max results (default 50, max 1000)."],
            "count_only": ["type": "boolean", "description": "Return only the total match count."],
        ],
        "required": ["query"],
    ],
]

// MARK: - request loop

while let raw = readLine(strippingNewline: true) {
    if raw.isEmpty { continue }
    guard let msg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    let id = msg["id"]   // nil for notifications

    switch method {
    case "initialize":
        result(id: id ?? NSNull(), [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": serverName, "version": serverVersion],
        ])
    case "notifications/initialized", "notifications/cancelled":
        continue   // notifications: no response
    case "tools/list":
        result(id: id ?? NSNull(), ["tools": [searchToolSchema]])
    case "ping":
        result(id: id ?? NSNull(), [:])
    case "tools/call":
        guard let params = msg["params"] as? [String: Any],
              let name = params["name"] as? String else {
            error(id: id ?? NSNull(), code: -32602, "invalid params"); continue
        }
        guard name == "search" else {
            error(id: id ?? NSNull(), code: -32601, "unknown tool: \(name)"); continue
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        guard let query = args["query"] as? String, !query.isEmpty else {
            error(id: id ?? NSNull(), code: -32602, "missing 'query'"); continue
        }
        let mode = (args["mode"] as? String) ?? "exact"
        let sort = (args["sort"] as? String) ?? "name"
        let scope = (args["scope"] as? String) ?? "name"
        let limit = min(max(1, (args["limit"] as? Int) ?? 50), 1000)
        let countOnly = (args["count_only"] as? Bool) ?? false

        guard let out = runSearch(query: query, mode: mode, sort: sort, scope: scope,
                                  limit: limit, countOnly: countOnly) else {
            result(id: id ?? NSNull(), [
                "content": [["type": "text",
                             "text": "Maverything has no index yet — open the Maverything app once so it can crawl your Mac."]],
                "isError": true,
            ])
            continue
        }
        var text: String
        if countOnly {
            text = "\(out.total) matches for \"\(query)\" (via \(out.source))."
        } else {
            let lines = out.rows.map { r -> String in
                let path = (r["path"] as? String) ?? ""
                let isDir = (r["isDir"] as? Bool) ?? false
                let size = (r["size"] as? Int64) ?? Int64((r["size"] as? Int) ?? 0)
                return isDir ? "\(path)/" : "\(path)  (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
            }
            let header = "\(out.total) match\(out.total == 1 ? "" : "es") for \"\(query)\" "
                + "(showing \(out.rows.count), via \(out.source)):"
            text = ([header] + lines).joined(separator: "\n")
        }
        // Return both a human-readable text block and the structured rows.
        result(id: id ?? NSNull(), [
            "content": [["type": "text", "text": text]],
            "structuredContent": ["total": out.total, "source": out.source,
                                  "indexing": out.indexing, "results": out.rows],
        ])
    default:
        if id != nil { error(id: id!, code: -32601, "method not found: \(method)") }
    }
}
