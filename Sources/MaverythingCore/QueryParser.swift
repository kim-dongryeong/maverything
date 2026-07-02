import Foundation

public enum TermScope: Sendable { case name, path }
public enum SizeOp: Sendable { case gt, lt, ge, le, eq }

public struct QueryTerm: Sendable {
    public var bytes: [UInt8]     // folded unless the query is case-sensitive
    public var negated: Bool
    public var scope: TermScope
}

/// An Everything-style parsed query: AND-ed terms + structured filters. Anything
/// it doesn't recognize falls back to a plain substring term (never errors).
public struct ParsedQuery: Sendable {
    public var terms: [QueryTerm] = []
    public var exts: [[UInt8]] = []                 // folded, no leading dot (include)
    public var sizes: [(SizeOp, Int64)] = []
    public var dateFrom: Int64? = nil               // mtime ns >=
    public var dateTo: Int64? = nil                 // mtime ns <
    // negated filters (`-ext:txt`, `-size:>1mb`, `-dm:today`): candidate must NOT match these
    public var notExts: [[UInt8]] = []
    public var notSizes: [(SizeOp, Int64)] = []
    public var notDateRanges: [(Int64?, Int64?)] = []
    public var onlyDirs = false                     // `folder:` — match directories only
    public var onlyFiles = false                    // `file:`   — match non-directories only
    public var caseSensitive = false

    public var hasFilters: Bool {
        !exts.isEmpty || !sizes.isEmpty || dateFrom != nil || dateTo != nil
            || !notExts.isEmpty || !notSizes.isEmpty || !notDateRanges.isEmpty
            || onlyDirs || onlyFiles
    }
    public var isEmpty: Bool { terms.isEmpty && !hasFilters }

    /// Fast-path eligibility: one positive name-scope term, no filters → the
    /// engine can use its tuned parallel memmem scan unchanged.
    public var simpleName: [UInt8]? {
        guard !hasFilters, terms.count == 1, let t = terms.first,
              !t.negated, t.scope == .name else { return nil }
        return t.bytes
    }
}

public enum QueryParser {

    /// `defaultScope` is the global name/path toggle (⌃U). `now` is unix seconds
    /// for resolving relative dates (today/yesterday/week).
    public static func parse(_ raw: String, defaultScope: TermScope, now: TimeInterval) -> ParsedQuery {
        var q = ParsedQuery()
        let tokens = tokenize(raw)

        // pass 1: case sensitivity flag
        for t in tokens where t.lowercased() == "case:on" || t.lowercased() == "case:" { q.caseSensitive = true }

        for tokRaw in tokens {
            var tok = tokRaw
            if tok.isEmpty { continue }
            var negated = false
            if tok.count > 1, let f = tok.first, f == "-" || f == "!" { negated = true; tok.removeFirst() }

            if let colon = tok.firstIndex(of: ":"), colon != tok.startIndex {
                let key = String(tok[..<colon]).lowercased()
                let val = String(tok[tok.index(after: colon)...])
                if applyFilter(key: key, val: val, negated: negated, now: now, into: &q) { continue }
                // not a known filter → fall through as a plain term (keep the colon)
            }

            // The prefix is authoritative BOTH ways (name: forces name scope even in ⌃U path mode)
            let low = tok.lowercased()
            let scope: TermScope = low.hasPrefix("name:") ? .name : (low.hasPrefix("path:") ? .path : defaultScope)
            let body = stripScopePrefix(tok).precomposedStringWithCanonicalMapping  // NFC to match index
            if body.isEmpty { continue }
            let bytes = q.caseSensitive ? Array(body.utf8) : Array(body.utf8).map(asciiLower)
            q.terms.append(QueryTerm(bytes: bytes, negated: negated, scope: scope))
        }
        return q
    }

    private static func stripScopePrefix(_ s: String) -> String {
        for p in ["name:", "path:"] where s.lowercased().hasPrefix(p) { return String(s.dropFirst(p.count)) }
        return s
    }

    private static func applyFilter(key: String, val: String, negated: Bool,
                                    now: TimeInterval, into q: inout ParsedQuery) -> Bool {
        switch key {
        case "name", "path":
            return false   // handled as scoped terms, not filters
        case "case":
            return true
        case "ext", "exts":
            for e in val.split(separator: ",") {
                // strip one leading '.', fold with the SAME ASCII fold as the name blob
                var s = String(e); if s.hasPrefix(".") { s.removeFirst() }
                let bytes = Array(s.utf8).map(asciiLower)
                if negated { q.notExts.append(bytes) } else { q.exts.append(bytes) }
            }
            return true
        case "size":
            guard let (op, n) = parseSize(val) else { return false }
            if negated { q.notSizes.append((op, n)) } else { q.sizes.append((op, n)) }
            return true
        case "dm", "modified", "date":
            guard let (from, to) = parseDate(val, now: now) else { return false }
            if negated { q.notDateRanges.append((from, to)) }
            else { if let f = from { q.dateFrom = f }; if let t = to { q.dateTo = t } }
            return true
        case "folder", "folders", "dir":       // restrict to directories (Everything's folder:)
            applyTypeFilter(dir: true, val: val, negated: negated, into: &q)
            return true
        case "file", "files":                  // restrict to non-directories
            applyTypeFilter(dir: false, val: val, negated: negated, into: &q)
            return true
        default:
            return false
        }
    }

    /// `folder:`/`file:` handling. Without a value it's a pure type restriction (and
    /// its negation flips to the other type). With a value the type restriction stays
    /// positive and the value becomes a name term whose sign follows `negated` — so
    /// `-folder:cache` means "directories, name NOT containing cache", never the
    /// contradictory onlyDirs+onlyFiles (which would match nothing).
    private static func applyTypeFilter(dir: Bool, val: String, negated: Bool, into q: inout ParsedQuery) {
        if val.isEmpty {
            if negated { if dir { q.onlyFiles = true } else { q.onlyDirs = true } }
            else       { if dir { q.onlyDirs  = true } else { q.onlyFiles = true } }
        } else if negated {
            // `-folder:cache` = "not named cache" — don't impose a type restriction (its true
            // negation isn't an AND-of-terms); the value just becomes an excluded name term.
            appendNameTerm(val, negated: true, into: &q)
        } else {
            if dir { q.onlyDirs = true } else { q.onlyFiles = true }
            appendNameTerm(val, negated: false, into: &q)
        }
    }

    /// Append a name-scope term carried by a type filter (`folder:foo`, `-file:bar`).
    private static func appendNameTerm(_ val: String, negated: Bool, into q: inout ParsedQuery) {
        let body = val.precomposedStringWithCanonicalMapping
        guard !body.isEmpty else { return }
        let bytes = q.caseSensitive ? Array(body.utf8) : Array(body.utf8).map(asciiLower)
        q.terms.append(QueryTerm(bytes: bytes, negated: negated, scope: .name))
    }

    static func parseSize(_ v: String) -> (SizeOp, Int64)? {
        var s = v.lowercased(); var op: SizeOp = .eq
        if s.hasPrefix(">=") { op = .ge; s.removeFirst(2) }
        else if s.hasPrefix("<=") { op = .le; s.removeFirst(2) }
        else if s.hasPrefix(">") { op = .gt; s.removeFirst() }
        else if s.hasPrefix("<") { op = .lt; s.removeFirst() }
        var mult: Int64 = 1
        for (suf, m) in [("gb", 1<<30), ("g", 1<<30), ("mb", 1<<20), ("m", 1<<20),
                         ("kb", 1<<10), ("k", 1<<10), ("b", 1)] as [(String, Int64)] {
            if s.hasSuffix(suf) { mult = m; s.removeLast(suf.count); break }
        }
        guard let num = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (op, Int64(num * Double(mult)))
    }

    /// Returns (from, to) mtime-ns bounds (half-open [from, to)). Uses the LOCAL
    /// calendar consistently for both relative and explicit dates, and always sets
    /// an upper bound for relative windows so future-dated files don't leak in.
    static func parseDate(_ v: String, now: TimeInterval) -> (Int64?, Int64?)? {
        let s = v.lowercased()
        let cal = Calendar.current
        let day: TimeInterval = 86_400
        let startOfToday = cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        func ns(_ t: TimeInterval) -> Int64 { Int64(t * 1e9) }
        switch s {
        case "today":            return (ns(startOfToday), ns(startOfToday + day))
        case "yesterday":        return (ns(startOfToday - day), ns(startOfToday))
        case "week", "thisweek": return (ns(startOfToday - 7 * day), ns(startOfToday + day))
        case "month":            return (ns(startOfToday - 30 * day), ns(startOfToday + day))
        default: break
        }
        var op = "="; var datePart = s
        if s.hasPrefix(">") { op = ">"; datePart.removeFirst() }
        else if s.hasPrefix("<") { op = "<"; datePart.removeFirst() }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"   // timeZone defaults to local, matching startOfDay above
        guard let d = fmt.date(from: datePart) else { return nil }
        let t = d.timeIntervalSince1970
        switch op {
        case ">": return (ns(t + day), nil)     // strictly after that day
        case "<": return (nil, ns(t))
        default:  return (ns(t), ns(t + day))    // that whole day
        }
    }

    /// Split on whitespace but keep "quoted phrases" together.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []; var cur = ""; var inQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
