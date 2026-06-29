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
    public var exts: [[UInt8]] = []                 // folded, no leading dot
    public var sizes: [(SizeOp, Int64)] = []
    public var dateFrom: Int64? = nil               // mtime ns >=
    public var dateTo: Int64? = nil                 // mtime ns <
    public var caseSensitive = false

    public var hasFilters: Bool { !exts.isEmpty || !sizes.isEmpty || dateFrom != nil || dateTo != nil }
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
                if applyFilter(key: key, val: val, now: now, into: &q) { continue }
                // not a known filter → fall through as a plain term (keep the colon)
            }

            let scope: TermScope = (tok.lowercased().hasPrefix("path:")) ? .path : defaultScope
            let body = stripScopePrefix(tok)
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

    private static func applyFilter(key: String, val: String, now: TimeInterval, into q: inout ParsedQuery) -> Bool {
        switch key {
        case "name", "path":
            return false   // handled as scoped terms, not filters
        case "case":
            return true
        case "ext", "exts":
            for e in val.split(separator: ",") {
                q.exts.append(Array(e.lowercased().utf8))
            }
            return true
        case "size":
            if let (op, n) = parseSize(val) { q.sizes.append((op, n)); return true }
            return false
        case "dm", "modified", "date":
            return parseDate(val, now: now, into: &q)
        default:
            return false
        }
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

    static func parseDate(_ v: String, now: TimeInterval, into q: inout ParsedQuery) -> Bool {
        let s = v.lowercased()
        let day: TimeInterval = 86_400
        let startOfToday = (now - now.truncatingRemainder(dividingBy: day))
        func ns(_ t: TimeInterval) -> Int64 { Int64(t * 1e9) }
        switch s {
        case "today": q.dateFrom = ns(startOfToday); return true
        case "yesterday": q.dateFrom = ns(startOfToday - day); q.dateTo = ns(startOfToday); return true
        case "week", "thisweek": q.dateFrom = ns(startOfToday - 7*day); return true
        case "month": q.dateFrom = ns(startOfToday - 30*day); return true
        default: break
        }
        var op = "="; var datePart = s
        if s.hasPrefix(">") { op = ">"; datePart.removeFirst() }
        else if s.hasPrefix("<") { op = "<"; datePart.removeFirst() }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: datePart) else { return false }
        let t = d.timeIntervalSince1970
        switch op {
        case ">": q.dateFrom = ns(t)
        case "<": q.dateTo = ns(t)
        default:  q.dateFrom = ns(t); q.dateTo = ns(t + day)
        }
        return true
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
