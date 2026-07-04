import Foundation

/// A local AF_UNIX query server: the resident app exposes its LIVE index over a
/// socket so `mvfind` (and, later, an MCP bridge) get real-time results instead of
/// loading a possibly-stale snapshot. One-shot, line-delimited JSON: connect →
/// one request line → one response line → close.
///
/// Security (Codex review): the socket lives inside a 0700 per-user directory,
/// is created under `umask(077)`, stale sockets are unlinked first, and every
/// connection's peer uid is checked with `getpeereid` — only the same user is
/// answered. It exposes READ-ONLY search; there is no mutating verb.
public final class QueryServer: @unchecked Sendable {
    public struct Config {
        public var maxRequestBytes = 64 << 10       // 64 KiB request cap
        public var maxResults = 10_000              // response result cap
        public var maxConcurrent = 4                // content:/tag: do file I/O — bound it
        public var connectionTimeout: TimeInterval = 15
        public init() {}
    }

    private let index: FileIndex
    private let engine: SearchEngine                 // dedicated engine: per-request options
    private let indexing: () -> Bool                 // app tells us if a crawl is in progress
    private let socketPath: String
    private let cfg: Config

    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "maverything.queryserver.accept")
    private let workSem: DispatchSemaphore

    public init(index: FileIndex, runStats: RunStats? = nil,
                socketPath: String, config: Config = Config(),
                indexing: @escaping () -> Bool = { false }) {
        self.index = index
        self.engine = SearchEngine(index: index)
        self.engine.runStats = runStats
        self.socketPath = socketPath
        self.cfg = config
        self.indexing = indexing
        self.workSem = DispatchSemaphore(value: config.maxConcurrent)
    }

    // MARK: - lifecycle

    /// Bind + listen + start accepting. Returns false (logs, non-fatal) on failure.
    @discardableResult
    public func start() -> Bool {
        guard listenFD < 0 else { return true }
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)                              // enforce even if the dir pre-existed
        unlink(socketPath)                             // clear a stale socket from a crash

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
            }
        }
        let prevMask = umask(0o077)                    // socket file: owner-only
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        umask(prevMask)
        guard bound == 0 else { close(fd); return false }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); unlink(socketPath); return false }
        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    // MARK: - accept loop

    private func acceptLoop() {
        while running {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 {
                if running && (errno == EINTR || errno == ECONNABORTED) { continue }
                break                                  // listener closed → exit
            }
            // getpeereid: only answer the SAME user (defense in depth beyond 0600).
            var euid: uid_t = 0, egid: gid_t = 0
            if getpeereid(cfd, &euid, &egid) != 0 || euid != getuid() {
                close(cfd); continue
            }
            workSem.wait()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { self?.workSem.signal() }
                self?.handle(cfd)
            }
        }
    }

    // MARK: - one request → one response

    private func handle(_ cfd: Int32) {
        defer { close(cfd) }
        var tv = timeval(tv_sec: Int(cfg.connectionTimeout), tv_usec: 0)
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // read up to a newline or the byte cap
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count <= cfg.maxRequestBytes {
            let n = read(cfd, &buf, buf.count)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl]); break
            }
            data.append(contentsOf: buf[0..<n])
        }
        let response: Data
        if data.count > cfg.maxRequestBytes {
            response = errorLine(code: "request_too_large", msg: "request exceeds \(cfg.maxRequestBytes) bytes")
        } else if let req = try? JSONDecoder().decode(Request.self, from: data) {
            response = runQuery(req)
        } else {
            response = errorLine(code: "bad_request", msg: "malformed JSON request")
        }
        var out = response
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = write(cfd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }

    // MARK: - protocol

    struct Request: Codable {
        var v: Int?
        var requestId: String?
        var q: String
        var mode: String?          // exact|fuzzy|wildcard|regex
        var scope: String?         // name|path
        var sort: String?          // name|path|size|date|created|relevance|runcount
        var asc: Bool?
        var limit: Int?
        var countOnly: Bool?
        var scopeRoot: String?
        var foldersFirst: Bool?
        var hideHidden: Bool?
        var useFolderSizes: Bool?
        var wholeNameWildcards: Bool?
        var fields: [String]?      // ["path"] (default) or ["path","name","size","mtime","isDir"]
    }

    private func runQuery(_ req: Request) -> Data {
        let mode: MatchMode = {
            switch (req.mode ?? "exact").lowercased() {
            case "fuzzy": return .fuzzy
            case "wildcard", "glob": return .wildcard
            case "regex": return .regex
            default: return .exact
            }
        }()
        let scope: SearchScope = (req.scope ?? "name").lowercased() == "path" ? .fullPath : .nameOnly
        let sort: SortKey = {
            switch (req.sort ?? "name").lowercased() {
            case "path": return .path
            case "size": return .size
            case "date", "dm", "datemodified": return .dateModified
            case "created", "datecreated": return .dateCreated
            case "relevance", "rel": return .relevance
            case "runcount", "run", "frecency": return .runCount
            default: return .name
            }
        }()
        // "best-first" sorts default descending unless the caller says otherwise.
        let defaultAsc = !(sort == .relevance || sort == .runCount || sort == .size
                           || sort == .dateModified || sort == .dateCreated)
        let asc = req.asc ?? defaultAsc
        let limit = min(max(1, req.limit ?? 200), cfg.maxResults)

        // per-request engine options (dedicated engine — never mutates the app's).
        engine.foldersFirst = req.foldersFirst ?? false
        engine.hideHidden = req.hideHidden ?? false
        engine.useFolderSizes = req.useFolderSizes ?? false
        engine.wholeNameWildcards = req.wholeNameWildcards ?? true

        // resolve a folder-scope root path → id, if given
        var rootId: Int32? = nil
        if let rp = req.scopeRoot, !rp.isEmpty {
            let nfc = rp.precomposedStringWithCanonicalMapping
            rootId = index.resolveIds(forPaths: [nfc])[nfc]
        }

        let now = Date().timeIntervalSince1970
        let countOnly = req.countOnly ?? false
        let res = engine.search(req.q, mode: mode, scope: scope, sortKey: sort, ascending: asc,
                                limit: countOnly ? 5_000_000 : limit, now: now, scopeRoot: rootId)

        var resp = Response(v: 1, requestId: req.requestId, ok: true, error: nil,
                            total: res.total, truncated: res.truncated,
                            queryMillis: res.queryMillis, indexCount: index.safeCount(),
                            indexing: indexing(), paths: nil, results: nil)
        if countOnly { return encode(resp) }

        let wantStruct = (req.fields ?? ["path"]).contains { $0 != "path" }
        if wantStruct {
            resp.results = res.ids.prefix(limit).map { id in
                let r = index.row(Int(id))
                return Row(path: r.path, name: r.name, size: r.size, mtime: r.mtime, isDir: r.isDir)
            }
        } else {
            resp.paths = res.ids.prefix(limit).map { index.path(Int($0)) }
        }
        return encode(resp)
    }

    struct Row: Codable { var path: String; var name: String; var size: Int64; var mtime: Int64; var isDir: Bool }
    struct ErrObj: Codable { var code: String; var msg: String }
    struct Response: Codable {
        var v: Int
        var requestId: String?
        var ok: Bool
        var error: ErrObj?
        var total: Int
        var truncated: Bool
        var queryMillis: Double
        var indexCount: Int
        var indexing: Bool
        var paths: [String]?
        var results: [Row]?
    }

    private func encode(_ r: Response) -> Data {
        (try? JSONEncoder().encode(r)) ?? Data("{\"v\":1,\"ok\":false}".utf8)
    }
    private func errorLine(code: String, msg: String) -> Data {
        let r = Response(v: 1, requestId: nil, ok: false, error: ErrObj(code: code, msg: msg),
                         total: 0, truncated: false, queryMillis: 0, indexCount: index.safeCount(),
                         indexing: indexing(), paths: nil, results: nil)
        return encode(r)
    }

    /// The default socket path under the app's Application Support dir.
    public static func defaultSocketPath() -> String {
        Snapshot.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("query.sock").path
    }
}
