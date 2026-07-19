import Foundation

public enum TermScope: Sendable, Equatable { case name, path }
// OI-5: Equatable so `(SizeOp, Int64)`/`(SizeOp, Int)` tuples compare with `elementsEqual(by: ==)`
// in SearchEngine's [23] narrow-refinement filter check. Additive, no payload — zero risk.
public enum SizeOp: Sendable, Equatable { case gt, lt, ge, le, eq }

public struct QueryTerm: Sendable {
    public var bytes: [UInt8]     // folded unless the query is case-sensitive
    public var negated: Bool
    public var scope: TermScope
    /// Everything-style AUTO-WILDCARD: an unquoted term containing * or ? is matched
    /// as an anchored glob even in Exact mode; a "quoted" term is always literal.
    public var isGlob: Bool = false
}

/// An Everything-style parsed query: AND-ed OR-groups of terms + structured
/// filters. Anything it doesn't recognize falls back to a plain substring term
/// (never errors).
public struct ParsedQuery: Sendable {
    /// AND-list of OR-groups: each inner array holds the alternatives of one token
    /// (`foo` → one group of one; `jpg|png` → one group of two). All alternatives
    /// in a group share the same negated flag and scope (`-a|b` negates the WHOLE
    /// group; `path:a|b` scopes the whole group).
    public var termGroups: [[QueryTerm]] = []
    public var exts: [[UInt8]] = []                 // folded, no leading dot (include)
    // `type:documents` (or a comma list `type:documents,images`) → OR of category bits.
    // Multiple type: tokens AND together. Backed by FileIndex.typeClass (O(1) bit test)
    // and equivalent by construction to the matching ext: clause.
    public var typeMasks: [UInt8] = []              // each must overlap (AND of tokens)
    public var notTypeMasks: [UInt8] = []           // `-type:` — must NOT overlap
    public var sizes: [(SizeOp, Int64)] = []
    public var dateFrom: Int64? = nil               // mtime ns >=
    public var dateTo: Int64? = nil                 // mtime ns <
    // negated filters (`-ext:txt`, `-size:>1mb`, `-dm:today`): candidate must NOT match these
    public var notExts: [[UInt8]] = []
    public var notSizes: [(SizeOp, Int64)] = []
    public var notDateRanges: [(Int64?, Int64?)] = []
    public var onlyDirs = false                     // `folder:` — match directories only
    public var onlyFiles = false                    // `file:`   — match non-directories only
    public var wholeWord = false                    // `ww:` — Everything's Match Whole Word
    public var dupesOnly = false                    // `dupe:` — names that occur more than once
    public var emptyDirsOnly = false                // `empty:` — empty folders only (implies onlyDirs)
    public var lenFilters: [(SizeOp, Int)] = []     // `len:` — name length in UTF-8 bytes
    public var prefixes: [[UInt8]] = []             // `startwith:` — name must begin with (folded)
    public var suffixes: [[UInt8]] = []             // `endwith:`  — name must end with (folded)
    public var notPrefixes: [[UInt8]] = []          // `-startwith:` — name must NOT begin with
    public var notSuffixes: [[UInt8]] = []          // `-endwith:`  — name must NOT end with
    public var contentNeedle: [UInt8]? = nil        // `content:` — on-demand file-content substring
    public var tagGroups: [[String]] = []           // `tag:a;b` = OR-group; multiple tag: = AND
    public var caseSensitive = false

    public var hasFilters: Bool {
        !exts.isEmpty || !typeMasks.isEmpty || !notTypeMasks.isEmpty
            || !sizes.isEmpty || dateFrom != nil || dateTo != nil
            || !notExts.isEmpty || !notSizes.isEmpty || !notDateRanges.isEmpty
            || onlyDirs || onlyFiles || wholeWord || dupesOnly
            || emptyDirsOnly || !lenFilters.isEmpty
            || !prefixes.isEmpty || !suffixes.isEmpty
            || !notPrefixes.isEmpty || !notSuffixes.isEmpty
            || contentNeedle != nil || !tagGroups.isEmpty
    }
    public var isEmpty: Bool { termGroups.isEmpty && !hasFilters }

    /// Fast-path eligibility: one positive name-scope term (a single group with a
    /// single alternative), no filters → the engine can use its tuned parallel
    /// memmem scan unchanged.
    public var simpleName: [UInt8]? {
        guard !hasFilters, termGroups.count == 1, let g = termGroups.first,
              g.count == 1, let t = g.first,
              !t.negated, t.scope == .name, !t.isGlob else { return nil }
        return t.bytes
    }

    /// Fast-path eligibility for PATH-scope search (`path:foo`, or a bare term in
    /// full-path mode ⌃U): one positive non-glob path term, no filters, case-insensitive.
    /// The engine answers these with a directory-prefix prepass instead of materializing
    /// every candidate's full path (see SearchEngine.fastPathScope).
    public var simplePath: [UInt8]? {
        guard !hasFilters, !caseSensitive, termGroups.count == 1, let g = termGroups.first,
              g.count == 1, let t = g.first,
              !t.negated, t.scope == .path, !t.isGlob else { return nil }
        return t.bytes
    }
}

public enum QueryParser {

    /// `defaultScope` is the global name/path toggle (⌃U). `now` is unix seconds
    /// for resolving relative dates (today/yesterday/week).
    public static func parse(_ raw: String, defaultScope: TermScope, now: TimeInterval) -> ParsedQuery {
        var q = ParsedQuery()
        let tokens = tokenize(raw)

        // pass 1: case sensitivity flag (unquoted tokens only)
        for t in tokens where !t.quoted && (t.text.lowercased() == "case:on" || t.text.lowercased() == "case:") {
            q.caseSensitive = true
        }

        var pendingNot = false   // Everything's `NOT` keyword: negates the NEXT token
        for tokEntry in tokens {
            var tok = tokEntry.text
            let quoted = tokEntry.quoted
            if tok.isEmpty { continue }
            // Everything treats a standalone (unquoted) `NOT`/`not` as negation of whatever
            // follows — `report NOT pdf` ≡ `report !pdf`, and it also composes with filters
            // (`NOT ext:pdf` ≡ `-ext:pdf`) and quoted phrases (`NOT "some name"`). A literal
            // search for the word is still possible with quotes ("not"). A trailing lone NOT
            // (mid-typing) is simply ignored.
            if !quoted, tok.lowercased() == "not" {
                pendingNot = true
                continue
            }
            var negated = pendingNot
            pendingNot = false
            if !quoted, tok.count > 1, let f = tok.first, f == "-" || f == "!" { negated = true; tok.removeFirst() }

            // A quoted token is a LITERAL phrase: no filter parsing, no OR-split,
            // no auto-wildcard — Everything's "…" escape (search a real * with "*").
            if quoted {
                let body = tok.precomposedStringWithCanonicalMapping
                if body.isEmpty { continue }
                let bytes = q.caseSensitive ? Array(body.utf8) : searchFoldedBytes(body)
                q.termGroups.append([QueryTerm(bytes: bytes, negated: negated, scope: defaultScope)])
                continue
            }

            if let colon = tok.firstIndex(of: ":"), colon != tok.startIndex {
                let key = String(tok[..<colon]).lowercased()
                let val = String(tok[tok.index(after: colon)...])
                if applyFilter(key: key, val: val, negated: negated, now: now, into: &q) { continue }
                // not a known filter → fall through as a plain term (keep the colon)
            }

            // The prefix is authoritative BOTH ways (name: forces name scope even in ⌃U path mode)
            let low = tok.lowercased()
            let scope: TermScope = low.hasPrefix("name:") ? .name : (low.hasPrefix("path:") ? .path : defaultScope)
            let body = stripScopePrefix(tok)
            if body.isEmpty { continue }
            // `|` splits the token into an OR-group (Everything's a|b). The leading -/!
            // and any name:/path: prefix apply to the WHOLE group; empty alternatives
            // are dropped. A plain token is simply a group of one (behavior unchanged).
            var group: [QueryTerm] = []
            for part in body.split(separator: "|") {
                let alt = String(part).precomposedStringWithCanonicalMapping  // NFC to match index
                if alt.isEmpty { continue }
                let bytes = q.caseSensitive ? Array(alt.utf8) : searchFoldedBytes(alt)
                // Everything-style auto-wildcard: * / ? in an unquoted term = glob term.
                let glob = alt.contains("*") || alt.contains("?")
                group.append(QueryTerm(bytes: bytes, negated: negated, scope: scope, isGlob: glob))
            }
            if !group.isEmpty { q.termGroups.append(group) }
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
        case "type", "kind":                       // media category: documents/images/audio/…
            let mask = FileTypeClass.maskForOperand(val)
            guard mask != 0 else { return false }   // unknown category → not a recognized filter (falls back to a plain term)
            if negated { q.notTypeMasks.append(mask) } else { q.typeMasks.append(mask) }
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
        case "ww", "wholeword":                // Everything's Match Whole Word
            if !negated { q.wholeWord = true }
            return true
        case "dupe", "dupes", "dup":           // Everything's duplicate finder (by name)
            if !negated { q.dupesOnly = true }
            return true
        case "empty":                          // Everything's empty: — folders with no live children
            if !negated { q.emptyDirsOnly = true; q.onlyDirs = true }
            return true
        case "len", "length":                  // name length in bytes: len:5 len:>20 len:<=3 len:3..8
            guard let filters = parseIntCompare(val) else { return false }
            if !negated { q.lenFilters.append(contentsOf: filters) }   // `-len:` is a no-op
            return true
        case "startwith", "startswith", "prefix":   // name must begin with (folded like terms)
            appendAffix(val, negated: negated, into: &q, prefix: true)
            return true
        case "endwith", "endswith", "suffix":       // name must end with (folded like terms)
            appendAffix(val, negated: negated, into: &q, prefix: false)
            return true
        case "content":                        // on-demand content search (Everything 1.4-style)
            if !negated, !val.isEmpty { q.contentNeedle = Array(val.utf8) }
            return true
        case "tag", "t":                       // Finder tags: `tag:red;blue` = OR, repeat = AND
            if !negated, !val.isEmpty {
                let group = val.split(separator: ";").map { $0.lowercased() }.filter { !$0.isEmpty }
                if !group.isEmpty { q.tagGroups.append(group) }
            }
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

    /// Append a name-scope term carried by a type filter (`folder:foo`, `-file:bar`)
    /// as a single-alternative group (type-filter values do not OR-split).
    private static func appendNameTerm(_ val: String, negated: Bool, into q: inout ParsedQuery) {
        let body = val.precomposedStringWithCanonicalMapping
        guard !body.isEmpty else { return }
        let bytes = q.caseSensitive ? Array(body.utf8) : searchFoldedBytes(body)
        q.termGroups.append([QueryTerm(bytes: bytes, negated: negated, scope: .name)])
    }

    /// `startwith:`/`endwith:` value → folded affix bytes (NFC + searchFoldedBytes
    /// unless case:on, mirroring plain terms). Empty values are ignored.
    private static func appendAffix(_ val: String, negated: Bool, into q: inout ParsedQuery, prefix: Bool) {
        let body = val.precomposedStringWithCanonicalMapping
        guard !body.isEmpty else { return }
        let bytes = q.caseSensitive ? Array(body.utf8) : searchFoldedBytes(body)
        switch (prefix, negated) {
        case (true, false):  q.prefixes.append(bytes)
        case (true, true):   q.notPrefixes.append(bytes)
        case (false, false): q.suffixes.append(bytes)
        case (false, true):  q.notSuffixes.append(bytes)
        }
    }

    /// Plain-integer comparison for `len:`: `5`, `>20`, `>=3`, `<10`, `<=8`, `=5`,
    /// and inclusive ranges `3..8` (→ ge+le). No unit suffixes (unlike parseSize).
    static func parseIntCompare(_ v: String) -> [(SizeOp, Int)]? {
        var s = v.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "..") {
            guard let a = Int(s[..<r.lowerBound]), let b = Int(s[r.upperBound...]) else { return nil }
            return [(.ge, a), (.le, b)]
        }
        var op: SizeOp = .eq
        if s.hasPrefix(">=") { op = .ge; s.removeFirst(2) }
        else if s.hasPrefix("<=") { op = .le; s.removeFirst(2) }
        else if s.hasPrefix(">") { op = .gt; s.removeFirst() }
        else if s.hasPrefix("<") { op = .lt; s.removeFirst() }
        else if s.hasPrefix("=") { op = .eq; s.removeFirst() }
        guard let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return [(op, n)]
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
        // `Int64(Double)` TRAPS on nan/inf and on any finite value outside Int64's range —
        // so `size:nan`, `size:inf`, `size:1e309`, `size:9e99`, even `size:1e5gb` would
        // crash the whole app (and, via QueryServer, a headless mvfind/MCP query could kill
        // the resident process). Clamp into range and reject non-finite instead of trapping.
        let bytes = num * Double(mult)
        guard bytes.isFinite else { return nil }
        let clamped = bytes.rounded()
        if clamped >= 9.223372036854776e18 { return (op, Int64.max) }   // ≥ Int64.max → saturate
        if clamped <= -9.223372036854776e18 { return (op, Int64.min) }
        return (op, Int64(clamped))
    }

    /// Returns (from, to) mtime-ns bounds (half-open [from, to)). Uses the LOCAL
    /// calendar consistently for both relative and explicit dates, and always sets
    /// an upper bound for relative windows so future-dated files don't leak in.
    static func parseDate(_ v: String, now: TimeInterval) -> (Int64?, Int64?)? {
        let s = v.lowercased()
        let cal = Calendar.current
        let day: TimeInterval = 86_400
        let startOfToday = cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        // Guard like parseSize: a 4-digit year (e.g. `dm:9999-01-01`) makes t·1e9 exceed
        // Int64's range, and `Int64(Double)` traps — clamp instead of crashing.
        func ns(_ t: TimeInterval) -> Int64 {
            let v = (t * 1e9).rounded()
            guard v.isFinite else { return 0 }
            if v >= 9.223372036854776e18 { return .max }
            if v <= -9.223372036854776e18 { return .min }
            return Int64(v)
        }
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

    /// Split on whitespace but keep "quoted phrases" together. The `quoted` flag
    /// marks tokens that contained quotes — those are LITERAL (no filter parsing,
    /// no OR-split, no auto-wildcard), exactly like Everything's "…" escape.
    static func tokenize(_ s: String) -> [(text: String, quoted: Bool)] {
        var out: [(String, Bool)] = []; var cur = ""; var inQuote = false; var sawQuote = false
        for ch in s {
            if ch == "\"" { inQuote.toggle(); sawQuote = true; continue }
            if ch == " " && !inQuote {
                if !cur.isEmpty { out.append((cur, sawQuote)); cur = ""; sawQuote = false }
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append((cur, sawQuote)) }
        return out
    }
}
