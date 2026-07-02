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

    // Incremental "narrow as you type": remember the FULL match set of the last simple
    // exact query so the next keystroke (which appends to it) can rescan only that set
    // instead of the whole index. Everything's key perceived-speed trick.
    private let incLock = NSLock()
    private var incValid = false
    private var incNeedle: [UInt8] = []
    private var incIDs: [Int32] = []          // full, untruncated, in sort order
    private var incSortKey: SortKey = .name
    private var incAscending = true
    private var incGen = -1

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    public func invalidate() { cacheLock.lock(); generation &+= 1; cacheLock.unlock() }
    private func currentGen() -> Int { cacheLock.lock(); defer { cacheLock.unlock() }; return generation }

    public func search(_ query: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly,
                       sortKey: SortKey = .name, ascending: Bool = true,
                       limit: Int = 100_000, now: TimeInterval = 0, scopeRoot: Int32? = nil) -> SearchResults {
        index.withReadLock {
            _search(query, mode: mode, scope: scope, sortKey: sortKey,
                    ascending: ascending, limit: limit, now: now, scopeRoot: scopeRoot)
        }
    }

    private func _search(_ query: String, mode: MatchMode, scope: SearchScope,
                         sortKey: SortKey, ascending: Bool, limit: Int, now: TimeInterval,
                         scopeRoot: Int32?) -> SearchResults {
        let clock = ContinuousClock()
        let start = clock.now
        // Regex mode treats the whole query as one pattern (no term-splitting).
        if mode == .regex, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            // NFC-normalize the pattern like the other modes, so a decomposed (NFD) literal
            // pasted into regex still matches the NFC names stored in the index.
            return regexSearch(pattern: query.precomposedStringWithCanonicalMapping,
                               scope: scope, sortKey: sortKey,
                               ascending: ascending, limit: limit, start: start, clock: clock,
                               scopeRoot: scopeRoot)
        }

        let parsed = QueryParser.parse(query, defaultScope: scope == .fullPath ? .path : .name, now: now)

        // empty query → return the chosen order directly (unless scoped to a folder)
        if parsed.isEmpty && scopeRoot == nil {
            let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
            let n = order.count
            var out = [Int32](); out.reserveCapacity(min(limit, n))
            if ascending { for k in 0..<min(limit, n) { out.append(order[k]) } }
            else { for k in 0..<min(limit, n) { out.append(order[n - 1 - k]) } }
            return SearchResults(ids: out, total: n, truncated: n > limit,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }

        // fast path: a single positive exact name term, no filters, no folder scope
        if mode == .exact, let needle = parsed.simpleName, !parsed.caseSensitive, scopeRoot == nil {
            return fastExact(needle: needle, sortKey: sortKey, ascending: ascending,
                             limit: limit, start: start, clock: clock)
        }

        return general(parsed: parsed, mode: mode, sortKey: sortKey, ascending: ascending,
                       limit: limit, start: start, clock: clock, scopeRoot: scopeRoot)
    }

    /// Walk parent links up from `id`; true if `root` is an ancestor (or is `id`).
    /// Integer-only (no path strings), depth-bounded so a cycle can't hang.
    @inline(__always)
    private func isUnder(_ id: Int, root: Int32, parentB: UnsafeBufferPointer<Int32>) -> Bool {
        var cur = Int32(id)
        var hops = 0
        while cur >= 0 && hops < 4096 {
            if cur == root { return true }
            cur = parentB[Int(cur)]
            hops += 1
        }
        return false
    }

    /// Reconstruct an entry's absolute-path bytes into `out` using ONLY the raw name
    /// blob + parent links — no String, no allocation — for fast path-scope matching.
    /// `blob` is the folded blob (or cased name blob) that the offsets index into.
    /// Returns the number of bytes written (clamped to out.count). Mirrors _path().
    @inline(__always)
    private func foldedPathBytes(_ id: Int,
                                 blob: UnsafePointer<UInt8>,
                                 offB: UnsafeBufferPointer<UInt32>,
                                 lenB: UnsafeBufferPointer<UInt16>,
                                 parB: UnsafeBufferPointer<Int32>,
                                 stack: UnsafeMutableBufferPointer<Int32>,
                                 out: UnsafeMutableBufferPointer<UInt8>) -> Int {
        let cap = out.count
        let slash = UInt8(ascii: "/")
        var depth = 0, cur = id
        while parB[cur] >= 0 && depth < stack.count {
            stack[depth] = Int32(cur); depth += 1; cur = Int(parB[cur])
        }
        var w = 0
        @inline(__always) func emit(_ e: Int) {
            let o = Int(offB[e]); let l = Int(lenB[e])
            var j = 0
            while j < l && w < cap { out[w] = blob[o + j]; w += 1; j += 1 }
        }
        // root name — matches _path: a root literally named "/" contributes no prefix
        let ro = Int(offB[cur]); let rl = Int(lenB[cur])
        if !(rl == 1 && blob[ro] == slash) { emit(cur) }
        var s = depth - 1
        while s >= 0 {
            if w < cap { out[w] = slash; w += 1 }
            emit(Int(stack[s])); s -= 1
        }
        if w == 0 && cap > 0 { out[0] = slash; w = 1 }
        return w
    }

    // MARK: - fast exact substring path (unchanged tuned scan)

    private func fastExact(needle: [UInt8], sortKey: SortKey, ascending: Bool,
                           limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let gen = currentGen()
        // Incremental narrowing: if this needle extends the cached one (same order + index
        // generation), rescan ONLY the cached full match set — O(prev matches), not O(index).
        var base: [Int32]? = nil
        incLock.lock()
        if incValid, incGen == gen, incSortKey == sortKey, incAscending == ascending,
           !incNeedle.isEmpty, needle.count > incNeedle.count, Self.hasPrefix(needle, incNeedle) {
            base = incIDs
        }
        incLock.unlock()

        var full: [Int32]     // the COMPLETE match set (in sort order), before the display cap

        if let base {
            // Serial rescan of the (already ordered, already small) previous result set.
            var res = [Int32](); res.reserveCapacity(base.count)
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
            index.deleted.withUnsafeBufferPointer { delB in
            needle.withUnsafeBufferPointer { nd in
                let hayBase = fb.baseAddress!
                let needleBase = UnsafeRawPointer(nd.baseAddress!)
                let needleLen = needle.count
                for id32 in base {
                    let id = Int(id32)
                    if delB[id] { continue }
                    let o = Int(offB[id]); let l = Int(lenB[id])
                    if l >= needleLen, memmem(hayBase + o, l, needleBase, needleLen) != nil { res.append(id32) }
                }
            }}}}}
            full = res
        } else {
            let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
            let n = order.count
            let nChunks = max(1, min(workerCount, n / 16_000 + 1))
            let chunkSize = (n + nChunks - 1) / nChunks
            var chunkIDs = [[Int32]](repeating: [], count: nChunks)

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
                    DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                        let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                        if lo >= hi { return }
                        var ids = [Int32]()
                        for k in lo..<hi {
                            let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                            if delB[id] { continue }   // defensive tombstone skip
                            let o = Int(offB[id]); let l = Int(lenB[id])
                            if l >= needleLen, memmem(hayBase + o, l, needleBase, needleLen) != nil {
                                ids.append(Int32(id))
                            }
                        }
                        outIDs[c] = ids
                    }
                }
            }}}}}}
            // chunks each keep ALL their matches (no per-chunk cap) → concat = full set in order
            var merged = [Int32](); merged.reserveCapacity(chunkIDs.reduce(0) { $0 + $1.count })
            for c in 0..<chunkIDs.count { merged.append(contentsOf: chunkIDs[c]) }
            full = merged
        }

        let total = full.count
        let out = total > limit ? Array(full[0..<limit]) : full
        // Cache the full set for the next keystroke — only when it's complete (untruncated).
        incLock.lock()
        if total <= limit {
            incValid = true; incGen = gen; incNeedle = needle; incIDs = full
            incSortKey = sortKey; incAscending = ascending
        } else {
            incValid = false
        }
        incLock.unlock()

        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    /// True if `bytes` begins with `prefix` (byte-wise).
    @inline(__always)
    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard prefix.count <= bytes.count else { return false }
        for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
        return true
    }

    // MARK: - regex mode (power mode; builds a String per candidate, so slower)

    private func regexSearch(pattern: String, scope: SearchScope, sortKey: SortKey, ascending: Bool,
                             limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock,
                             scopeRoot: Int32?) -> SearchResults {
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

        index.parent.withUnsafeBufferPointer { parB in
        order.withUnsafeBufferPointer { ordB in
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if let root = scopeRoot, !self.isUnder(id, root: root, parentB: parB) { continue }
                        let s = usePath ? self.index._path(id) : self.index._name(id)
                        let r = NSRange(s.startIndex..., in: s)
                        if re.firstMatch(in: s, options: [], range: r) != nil {
                            total += 1; if ids.count < limit { ids.append(Int32(id)) }
                        }
                    }
                    outIDs[c] = ids; outTot[c] = total
                }
            }}
        }}
        let total = chunkTotals.reduce(0, +)
        var out = [Int32](); out.reserveCapacity(min(total, limit))
        outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    // MARK: - general evaluator (modes, filters, multi-term, NOT, path, relevance)

    private func general(parsed: ParsedQuery, mode: MatchMode, sortKey: SortKey, ascending: Bool,
                         limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock,
                         scopeRoot: Int32?) -> SearchResults {
        let relevance = (sortKey == .relevance)
        let order = orderArray(for: relevance ? .name : sortKey)
        let n = order.count
        let caseSensitive = parsed.caseSensitive
        // Flatten term bytes into one contiguous buffer + trivial refs so the hot loop
        // uses raw pointers only. Touching each term's [UInt8] array (ARC retain/release)
        // per candidate made multi-term scans ~10x slower than single-term.
        var termBlob: [UInt8] = []
        var termRefs: [(off: Int, len: Int, negated: Bool, isPath: Bool)] = []
        termRefs.reserveCapacity(parsed.terms.count)
        for t in parsed.terms {
            termRefs.append((termBlob.count, t.bytes.count, t.negated, t.scope == .path))
            termBlob.append(contentsOf: t.bytes)
        }
        let termCount = termRefs.count
        // Hoist filter presence out of the loop (avoid per-candidate array access + ARC).
        let hasExts = !parsed.exts.isEmpty, hasSizes = !parsed.sizes.isEmpty
        let hasNotExts = !parsed.notExts.isEmpty, hasNotSizes = !parsed.notSizes.isEmpty
        let hasNotDates = !parsed.notDateRanges.isEmpty
        let df = parsed.dateFrom, dt = parsed.dateTo
        let onlyDirs = parsed.onlyDirs, onlyFiles = parsed.onlyFiles

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
        index.parent.withUnsafeBufferPointer { parB in
        order.withUnsafeBufferPointer { ordB in
        termBlob.withUnsafeBufferPointer { tblobB in
        termRefs.withUnsafeBufferPointer { trefsB in
            let fbBase = fb.baseAddress!, nbBase = nb.baseAddress!
            let tblobBase = tblobB.baseAddress   // non-nil whenever termCount > 0
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkScores.withUnsafeMutableBufferPointer { outScores in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var scores = [Int32](); var total = 0
                    let hayBase = caseSensitive ? nbBase : fbBase
                    let pathBlob = caseSensitive ? nbBase : fbBase
                    // Per-chunk scratch for on-the-fly path reconstruction (path-scope terms).
                    // Reused across every candidate in the chunk → no per-candidate allocation.
                    var pathScratch = [UInt8](repeating: 0, count: 8192)
                    var idxStack = [Int32](repeating: 0, count: 1024)
                    pathScratch.withUnsafeMutableBufferPointer { psb in
                    idxStack.withUnsafeMutableBufferPointer { isb in
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if delB[id] { continue }   // defensive: skip tombstones even if order is stale
                        // folder scope: only entries under the chosen directory subtree
                        if let root = scopeRoot, !self.isUnder(id, root: root, parentB: parB) { continue }
                        // type filters (folder: / file:)
                        if onlyDirs && otB[id] != VNODE_VDIR { continue }
                        if onlyFiles && otB[id] == VNODE_VDIR { continue }
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        // include filters (cheap) first
                        if hasExts && !self.extMatches(fbBase, o, l, parsed.exts) { continue }
                        if hasSizes && !self.sizeMatches(szB[id], parsed.sizes) { continue }
                        if let df, mtB[id] < df { continue }
                        if let dt, mtB[id] >= dt { continue }
                        // negated filters: exclude if the candidate matches any of them
                        if hasNotExts && self.extMatches(fbBase, o, l, parsed.notExts) { continue }
                        if hasNotSizes && self.excludedBySize(szB[id], parsed.notSizes) { continue }
                        if hasNotDates && self.excludedByDate(mtB[id], parsed.notDateRanges) { continue }
                        // terms — raw pointers into the flattened term blob (no per-candidate ARC)
                        var score = 0; var ok = true
                        var pathLen = -1   // built lazily once per candidate, reused across path terms
                        var ti = 0
                        while ti < termCount {
                            let tr = trefsB[ti]
                            let needlePtr = tblobBase! + tr.off
                            let out: MatchOutcome
                            if tr.isPath {
                                if pathLen < 0 {
                                    pathLen = self.foldedPathBytes(id, blob: pathBlob, offB: offB,
                                                                   lenB: lenB, parB: parB, stack: isb, out: psb)
                                }
                                out = Matcher.match(hay: psb.baseAddress!, hayLen: pathLen,
                                                    needle: needlePtr, needleLen: tr.len, mode: mode)
                            } else {
                                out = Matcher.match(hay: hayBase + o, hayLen: l,
                                                    needle: needlePtr, needleLen: tr.len, mode: mode)
                            }
                            let pass = tr.negated ? !out.matched : out.matched
                            if !pass { ok = false; break }
                            if !tr.negated { score += out.score }
                            ti += 1
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
                    }}
                }
            }}}
        }}}}}}}}}}}}

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
