import Darwin
import Foundation

public enum SortKey: Int, Sendable { case name, path, size, dateModified, dateCreated, relevance }
public enum SearchScope: Int, Sendable { case nameOnly, fullPath }

public struct SearchResults: Sendable {
    public var ids: [Int32]      // entry indices, in requested order
    public var total: Int        // total matches (may exceed ids.count if truncated)
    public var truncated: Bool
    public var queryMillis: Double
}

/// Multi-core search over the packed name blob (the Everything model). A simple
/// exact-substring name query uses the tuned parallel `memmem` scan in precomputed
/// sort order (no per-keystroke sort). Fuzzy / wildcard / filtered / multi-term /
/// path queries go through a general evaluator; `.relevance` ranks by match score.
public final class SearchEngine: @unchecked Sendable {
    private let index: FileIndex
    private let workerCount: Int

    private var orderCache: [SortKey: [Int32]] = [:]
    private var cacheGen: Int = -1
    public internal(set) var generation: Int = 0
    private let cacheLock = NSLock()

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    public func invalidate() { cacheLock.lock(); generation &+= 1; cacheLock.unlock() }

    public func search(_ query: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly,
                       sortKey: SortKey = .name, ascending: Bool = true,
                       limit: Int = 100_000, now: TimeInterval = 0) -> SearchResults {
        index.withReadLock {
            _search(query, mode: mode, scope: scope, sortKey: sortKey,
                    ascending: ascending, limit: limit, now: now)
        }
    }

    private func _search(_ query: String, mode: MatchMode, scope: SearchScope,
                         sortKey: SortKey, ascending: Bool, limit: Int, now: TimeInterval) -> SearchResults {
        let clock = ContinuousClock()
        let start = clock.now
        // Regex mode treats the whole query as one pattern (no term-splitting).
        if mode == .regex, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return regexSearch(pattern: query, scope: scope, sortKey: sortKey,
                               ascending: ascending, limit: limit, start: start, clock: clock)
        }

        let parsed = QueryParser.parse(query, defaultScope: scope == .fullPath ? .path : .name, now: now)

        // empty query → return the chosen order directly
        if parsed.isEmpty {
            let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
            let n = order.count
            var out = [Int32](); out.reserveCapacity(min(limit, n))
            if ascending { for k in 0..<min(limit, n) { out.append(order[k]) } }
            else { for k in 0..<min(limit, n) { out.append(order[n - 1 - k]) } }
            return SearchResults(ids: out, total: n, truncated: n > limit,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }

        // fast path: a single positive exact name term, no filters
        if mode == .exact, let needle = parsed.simpleName, !parsed.caseSensitive {
            return fastExact(needle: needle, sortKey: sortKey, ascending: ascending,
                             limit: limit, start: start, clock: clock)
        }

        return general(parsed: parsed, mode: mode, sortKey: sortKey, ascending: ascending,
                       limit: limit, start: start, clock: clock)
    }

    // MARK: - fast exact substring path (unchanged tuned scan)

    private func fastExact(needle: [UInt8], sortKey: SortKey, ascending: Bool,
                           limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
        let n = order.count
        let nChunks = max(1, min(workerCount, n / 16_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)

        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.deleted.withUnsafeBufferPointer { delB in
        order.withUnsafeBufferPointer { ordB in
        needle.withUnsafeBufferPointer { nd in
            let hayBase = fb.baseAddress!
            let needleBase = UnsafeRawPointer(nd.baseAddress!)
            let needleLen = needle.count
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if delB[id] { continue }   // defensive tombstone skip
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        if l >= needleLen, memmem(hayBase + o, l, needleBase, needleLen) != nil {
                            total += 1; ids.append(Int32(id))
                        }
                    }
                    outIDs[c] = ids; outTot[c] = total
                }
            }}
        }}}}}}

        let total = chunkTotals.reduce(0, +)
        var out = [Int32](); out.reserveCapacity(min(total, limit))
        outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    // MARK: - regex mode (power mode; builds a String per candidate, so slower)

    private func regexSearch(pattern: String, scope: SearchScope, sortKey: SortKey, ascending: Bool,
                             limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return SearchResults(ids: [], total: 0, truncated: false,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }
        let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
        let n = order.count
        let usePath = (scope == .fullPath)
        let nChunks = max(1, min(workerCount, n / 8_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)

        order.withUnsafeBufferPointer { ordB in
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        let s = usePath ? self.index._path(id) : self.index._name(id)
                        let r = NSRange(s.startIndex..., in: s)
                        if re.firstMatch(in: s, options: [], range: r) != nil {
                            total += 1; if ids.count < limit { ids.append(Int32(id)) }
                        }
                    }
                    outIDs[c] = ids; outTot[c] = total
                }
            }}
        }
        let total = chunkTotals.reduce(0, +)
        var out = [Int32](); out.reserveCapacity(min(total, limit))
        outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    // MARK: - general evaluator (modes, filters, multi-term, NOT, path, relevance)

    private func general(parsed: ParsedQuery, mode: MatchMode, sortKey: SortKey, ascending: Bool,
                         limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let relevance = (sortKey == .relevance)
        let order = orderArray(for: relevance ? .name : sortKey)
        let n = order.count
        let needsPath = parsed.terms.contains { $0.scope == .path }
        let caseSensitive = parsed.caseSensitive

        let nChunks = max(1, min(workerCount, n / 8_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkScores = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)

        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameBlob.withUnsafeBufferPointer { nb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.size.withUnsafeBufferPointer { szB in
        index.mtime.withUnsafeBufferPointer { mtB in
        index.deleted.withUnsafeBufferPointer { delB in
        index.objType.withUnsafeBufferPointer { otB in
        order.withUnsafeBufferPointer { ordB in
            let fbBase = fb.baseAddress!, nbBase = nb.baseAddress!
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkScores.withUnsafeMutableBufferPointer { outScores in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var scores = [Int32](); var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if delB[id] { continue }   // defensive: skip tombstones even if order is stale
                        // type filters (folder: / file:)
                        if parsed.onlyDirs && otB[id] != VNODE_VDIR { continue }
                        if parsed.onlyFiles && otB[id] == VNODE_VDIR { continue }
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        // include filters (cheap) first
                        if !parsed.exts.isEmpty && !self.extMatches(fbBase, o, l, parsed.exts) { continue }
                        if !parsed.sizes.isEmpty && !self.sizeMatches(szB[id], parsed.sizes) { continue }
                        if let df = parsed.dateFrom, mtB[id] < df { continue }
                        if let dt = parsed.dateTo, mtB[id] >= dt { continue }
                        // negated filters: exclude if the candidate matches any of them
                        if !parsed.notExts.isEmpty && self.extMatches(fbBase, o, l, parsed.notExts) { continue }
                        if self.excludedBySize(szB[id], parsed.notSizes) { continue }
                        if self.excludedByDate(mtB[id], parsed.notDateRanges) { continue }
                        // terms
                        let hayBase = caseSensitive ? nbBase : fbBase
                        var score = 0; var ok = true
                        var pathBytes: [UInt8]? = nil
                        for term in parsed.terms {
                            let out: MatchOutcome
                            if term.scope == .path || (needsPath && false) {
                                if pathBytes == nil {
                                    let p = self.index._path(id)
                                    pathBytes = caseSensitive ? Array(p.utf8) : Array(p.utf8).map(asciiLower)
                                }
                                out = term.bytes.withUnsafeBufferPointer { tb in
                                    pathBytes!.withUnsafeBufferPointer { pb in
                                        Matcher.match(hay: pb.baseAddress!, hayLen: pb.count,
                                                      needle: tb.baseAddress!, needleLen: tb.count, mode: mode)
                                    }
                                }
                            } else {
                                out = term.bytes.withUnsafeBufferPointer { tb in
                                    Matcher.match(hay: hayBase + o, hayLen: l,
                                                  needle: tb.baseAddress!, needleLen: tb.count, mode: mode)
                                }
                            }
                            let pass = term.negated ? !out.matched : out.matched
                            if !pass { ok = false; break }
                            if !term.negated { score += out.score }
                        }
                        if !ok { continue }
                        total += 1
                        if relevance {
                            ids.append(Int32(id)); scores.append(Int32(clamping: score))
                        } else if ids.count < limit {
                            ids.append(Int32(id))
                        }
                    }
                    outIDs[c] = ids; outScores[c] = scores; outTot[c] = total
                }
            }}}
        }}}}}}}}}

        let total = chunkTotals.reduce(0, +)
        var out: [Int32]
        if relevance {
            var pairs: [(Int32, Int32)] = []
            pairs.reserveCapacity(min(total, 200_000))
            for c in 0..<nChunks {
                let ids = chunkIDs[c], scs = chunkScores[c]
                for j in 0..<ids.count { pairs.append((ids[j], scs[j])) }
            }
            // relevance is conventionally high→low, but honor the ascending flag; stable by id
            pairs.sort { a, b in a.1 != b.1 ? (ascending ? a.1 < b.1 : a.1 > b.1) : a.0 < b.0 }
            out = pairs.prefix(limit).map { $0.0 }
        } else {
            out = []; out.reserveCapacity(min(total, limit))
            outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    @inline(__always)
    private func extMatches(_ base: UnsafePointer<UInt8>, _ o: Int, _ l: Int, _ exts: [[UInt8]]) -> Bool {
        var dot = -1
        var i = l - 1
        while i >= 0 { if base[o + i] == UInt8(ascii: ".") { dot = i; break }; i -= 1 }
        guard dot >= 0 else { return false }
        let extStart = o + dot + 1, extLen = l - dot - 1
        for e in exts where e.count == extLen {
            var match = true
            for j in 0..<extLen where base[extStart + j] != e[j] { match = false; break }
            if match { return true }
        }
        return false
    }

    @inline(__always)
    private func sizeMatches(_ s: Int64, _ filters: [(SizeOp, Int64)]) -> Bool {
        for (op, n) in filters {
            switch op {
            case .gt: if !(s > n) { return false }
            case .lt: if !(s < n) { return false }
            case .ge: if !(s >= n) { return false }
            case .le: if !(s <= n) { return false }
            case .eq: if !(s == n) { return false }
            }
        }
        return true
    }

    // negated filters exclude if the candidate matches ANY of them
    @inline(__always)
    private func excludedBySize(_ s: Int64, _ nots: [(SizeOp, Int64)]) -> Bool {
        for f in nots where sizeMatches(s, [f]) { return true }
        return false
    }
    @inline(__always)
    private func excludedByDate(_ mt: Int64, _ ranges: [(Int64?, Int64?)]) -> Bool {
        for (from, to) in ranges {
            let after = from.map { mt >= $0 } ?? true
            let before = to.map { mt < $0 } ?? true
            if after && before { return true }
        }
        return false
    }

    // MARK: - sort order (argsort) with caching

    private func orderArray(for key: SortKey) -> [Int32] {
        cacheLock.lock()
        if cacheGen != generation { orderCache.removeAll(); cacheGen = generation }
        if let cached = orderCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let order = computeOrder(key)
        cacheLock.lock()
        if cacheGen == generation { orderCache[key] = order }
        cacheLock.unlock()
        return order
    }

    private func computeOrder(_ key: SortKey) -> [Int32] {
        let n = index.count
        let del = index.deleted
        var ids = [Int32](); ids.reserveCapacity(n)
        for i in 0..<n where !del[i] { ids.append(Int32(i)) }
        switch key {
        case .size:
            let size = index.size
            ids.sort { size[Int($0)] != size[Int($1)] ? size[Int($0)] < size[Int($1)] : $0 < $1 }
        case .dateModified:
            let mt = index.mtime
            ids.sort { mt[Int($0)] != mt[Int($1)] ? mt[Int($0)] < mt[Int($1)] : $0 < $1 }
        case .dateCreated:
            let ct = index.crtime
            ids.sort { ct[Int($0)] != ct[Int($1)] ? ct[Int($0)] < ct[Int($1)] : $0 < $1 }
        case .name, .path, .relevance:   // path/relevance use name order as the scan base
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                // Pack the first 8 folded bytes into a UInt64 so most comparisons are
                // a single integer compare; fall back to memcmp only on an 8-byte tie.
                @inline(__always) func key64(_ i: Int) -> UInt64 {
                    let o = Int(offB[i]); let l = min(Int(lenB[i]), 8)
                    var k: UInt64 = 0
                    var j = 0
                    while j < l { k |= UInt64(base[o + j]) << (56 - 8 * j); j += 1 }
                    return k
                }
                var pairs = ids.map { (key64(Int($0)), $0) }
                pairs.sort { a, b in
                    if a.0 != b.0 { return a.0 < b.0 }
                    let ia = Int(a.1), ib = Int(b.1)
                    let oa = Int(offB[ia]), la = Int(lenB[ia])
                    let ob = Int(offB[ib]), lb = Int(lenB[ib])
                    let m = min(la, lb)
                    let r = m > 0 ? memcmp(base + oa, base + ob, m) : 0
                    if r != 0 { return r < 0 }
                    if la != lb { return la < lb }
                    return a.1 < b.1
                }
                for k in 0..<pairs.count { ids[k] = pairs[k].1 }
            }}}
        }
        return ids
    }
}

@inline(__always) func foldedBytes(_ s: String) -> [UInt8] {
    Array(s.precomposedStringWithCanonicalMapping.utf8).map(asciiLower)
}
