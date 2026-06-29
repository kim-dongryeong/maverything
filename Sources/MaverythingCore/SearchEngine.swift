import Darwin
import Foundation

public enum SortKey: Int, Sendable { case name, path, size, dateModified }
public enum SearchScope: Int, Sendable { case nameOnly, fullPath }

public struct SearchResults: Sendable {
    public var ids: [Int32]      // entry indices, already in requested sort order
    public var total: Int        // total matches (may exceed ids.count if truncated)
    public var truncated: Bool
    public var queryMillis: Double
}

/// Brute-force, multi-core substring search over the packed name blob — the
/// Everything model. Results come out pre-sorted because we scan the index in a
/// precomputed sort order (per-column argsort), so there is no per-keystroke sort.
public final class SearchEngine: @unchecked Sendable {
    private let index: FileIndex
    private let workerCount: Int

    // cached argsort orders, invalidated by `generation`
    private var orderCache: [SortKey: [Int32]] = [:]
    private var cacheGen: Int = -1
    public internal(set) var generation: Int = 0
    private let cacheLock = NSLock()

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    /// Bump after the index is mutated so cached sort orders rebuild.
    public func invalidate() {
        cacheLock.lock(); generation &+= 1; cacheLock.unlock()
    }

    public func search(_ query: String, scope: SearchScope = .nameOnly,
                       sortKey: SortKey = .name, ascending: Bool = true,
                       limit: Int = 100_000) -> SearchResults {
        // Hold the index read lock for the whole scan so a concurrent live delta
        // (reconciler appending / tombstoning) can never reallocate under us.
        index.withReadLock {
            _search(query, scope: scope, sortKey: sortKey, ascending: ascending, limit: limit)
        }
    }

    private func _search(_ query: String, scope: SearchScope,
                         sortKey: SortKey, ascending: Bool, limit: Int) -> SearchResults {
        let clock = ContinuousClock()
        let start = clock.now
        let order = orderArray(for: sortKey)
        let n = order.count

        let needle = foldedBytes(query)
        if needle.isEmpty {
            var out = [Int32]()
            out.reserveCapacity(min(limit, n))
            if ascending { for k in 0..<min(limit, n) { out.append(order[k]) } }
            else { for k in 0..<min(limit, n) { out.append(order[n - 1 - k]) } }
            return SearchResults(ids: out, total: n, truncated: n > limit,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }

        if scope == .fullPath {
            return searchPaths(needle: needle, order: order, ascending: ascending,
                               limit: limit, start: start, clock: clock)
        }

        // name-only: scan foldBlob slices in sort order, chunked across cores.
        let nChunks = max(1, min(workerCount, n / 16_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)

        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        order.withUnsafeBufferPointer { ordB in
        needle.withUnsafeBufferPointer { nd in
            let hayBase = fb.baseAddress!
            let needleBase = UnsafeRawPointer(nd.baseAddress!)
            let needleLen = needle.count
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize
                    let hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32]()
                    var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        if l >= needleLen,
                           memmem(hayBase + o, l, needleBase, needleLen) != nil {
                            total += 1
                            ids.append(Int32(id))
                        }
                    }
                    outIDs[c] = ids
                    outTot[c] = total
                }
            }}
        }}}}}

        let total = chunkTotals.reduce(0, +)
        var out = [Int32]()
        out.reserveCapacity(min(total, limit))
        outer: for c in 0..<nChunks {
            for id in chunkIDs[c] {
                if out.count >= limit { break outer }
                out.append(id)
            }
        }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    // Full-path matching (Ctrl+U scope). Reconstructs each candidate's path —
    // heavier, but only used in this mode.
    private func searchPaths(needle: [UInt8], order: [Int32], ascending: Bool,
                             limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let n = order.count
        let needleStr = String(decoding: needle, as: UTF8.self)
        let nChunks = max(1, min(workerCount, n / 8_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)
        chunkIDs.withUnsafeMutableBufferPointer { outIDs in
        chunkTotals.withUnsafeMutableBufferPointer { outTot in
            DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                if lo >= hi { return }
                var ids = [Int32](); var total = 0
                for k in lo..<hi {
                    let id = Int(ascending ? order[k] : order[n - 1 - k])
                    let p = self.index._path(id).lowercased()   // lock already held by search()
                    if p.contains(needleStr) { total += 1; if ids.count < limit { ids.append(Int32(id)) } }
                }
                outIDs[c] = ids; outTot[c] = total
            }
        }}
        let total = chunkTotals.reduce(0, +)
        var out = [Int32](); out.reserveCapacity(min(total, limit))
        outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
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
        for i in 0..<n where !del[i] { ids.append(Int32(i)) }   // exclude tombstones
        switch key {
        case .size:
            let size = index.size
            ids.sort { size[Int($0)] != size[Int($1)] ? size[Int($0)] < size[Int($1)] : $0 < $1 }
        case .dateModified:
            let mt = index.mtime
            ids.sort { mt[Int($0)] != mt[Int($1)] ? mt[Int($0)] < mt[Int($1)] : $0 < $1 }
        case .name, .path:   // path sort falls back to name for now
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                ids.sort { a, b in
                    let ia = Int(a), ib = Int(b)
                    let oa = Int(offB[ia]), la = Int(lenB[ia])
                    let ob = Int(offB[ib]), lb = Int(lenB[ib])
                    let m = min(la, lb)
                    let r = m > 0 ? memcmp(base + oa, base + ob, m) : 0
                    if r != 0 { return r < 0 }
                    if la != lb { return la < lb }
                    return a < b
                }
            }}}
        }
        return ids
    }
}

@inline(__always) func foldedBytes(_ s: String) -> [UInt8] {
    Array(s.utf8).map(asciiLower)
}
