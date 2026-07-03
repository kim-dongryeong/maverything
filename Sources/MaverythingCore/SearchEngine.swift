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
    private var cacheGen: Int = -1     // the FileIndex.mutationGen the orderCache was built at
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
    private static let incMaxCacheIDs = 8_000_000   // memory bound for the narrowing cache

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    // Caches now key off FileIndex.mutationGen (bumped under the index lock on every
    // mutation), so any change auto-invalidates them. This remains as an explicit
    // "refresh now" that simply advances that counter.
    public func invalidate() { index.bumpMutation() }

    /// Everything 1.5-style folder-size sorting: when on, the Size order ranks a
    /// directory by its live subtree TOTAL (from FileIndex's cached bottom-up pass)
    /// instead of 0. Set from the app's "Index folder sizes" toggle.
    public var useFolderSizes = true

    public func search(_ query: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly,
                       sortKey: SortKey = .name, ascending: Bool = true,
                       limit: Int = 100_000, now: TimeInterval = 0, scopeRoot: Int32? = nil) -> SearchResults {
        // content:/tag: are post-filters that do FILE I/O (read contents / xattrs), so they
        // must run OUTSIDE the index read lock — a long scan must never block the reconciler.
        // The name/metadata scan first narrows candidates under the lock as usual.
        let post: ParsedQuery? = {
            guard mode != .regex else { return nil }
            let p = QueryParser.parse(query, defaultScope: scope == .fullPath ? .path : .name, now: now)
            return (p.contentNeedle != nil || !p.tagGroups.isEmpty) ? p : nil
        }()
        let innerLimit = post != nil ? 5_000_000 : limit   // need the FULL candidate set pre-filter
        var res = index.withReadLock {
            _search(query, mode: mode, scope: scope, sortKey: sortKey,
                    ascending: ascending, limit: innerLimit, now: now, scopeRoot: scopeRoot)
        }
        if let p = post {
            let clock = ContinuousClock(); let t0 = clock.now
            var ids = res.ids
            if !p.tagGroups.isEmpty { ids = Self.filterByTags(ids, groups: p.tagGroups, index: index) }
            if let needle = p.contentNeedle {
                ids = Self.filterByContent(ids, needle: needle, caseSensitive: p.caseSensitive, index: index)
            }
            let capped = ids.count > limit ? Array(ids[0..<limit]) : ids
            res = SearchResults(ids: capped, total: ids.count, truncated: ids.count > capped.count,
                                queryMillis: res.queryMillis + secondsBetween(t0, clock.now) * 1000)
        }
        return res
    }

    // MARK: - post-lock filters (content: / tag:) — Everything 1.4-style on-demand

    private static let contentMaxFileBytes: Int64 = 64 << 20     // skip files > 64 MB
    private static let contentMaxCandidates = 200_000            // scan budget (bare `content:` safety)

    /// On-demand file-content substring (ASCII case-insensitive unless case:on) — the
    /// same 64 KiB-window streaming model Cardinal uses; no content index is kept.
    static func filterByContent(_ ids: [Int32], needle: [UInt8], caseSensitive: Bool,
                                index: FileIndex) -> [Int32] {
        guard !needle.isEmpty else { return ids }
        let folded = caseSensitive ? needle : needle.map(asciiLower)
        var out: [Int32] = []
        var scanned = 0
        for id in ids {
            let r = index.row(Int(id))
            if r.isDir { continue }
            if r.size > contentMaxFileBytes { continue }
            if scanned >= contentMaxCandidates { break }   // budget → truncated, not frozen
            scanned += 1
            if fileContains(path: r.path, needle: folded, caseSensitive: caseSensitive) {
                out.append(id)
            }
        }
        return out
    }

    /// Streaming scan: 64 KiB windows with a needle-1 overlap so matches can span
    /// chunk boundaries; case-insensitive mode lowercases the window in place.
    static func fileContains(path: String, needle: [UInt8], caseSensitive: Bool) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let winSize = 64 << 10
        let keep = needle.count - 1
        var buf = [UInt8](repeating: 0, count: winSize + max(0, keep))
        var carry = 0
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + carry, winSize) }
            if n <= 0 { return false }
            let total = carry + n
            if !caseSensitive {
                for i in carry..<total { buf[i] = asciiLower(buf[i]) }
            }
            let hit = buf.withUnsafeBytes { raw in
                needle.withUnsafeBytes { nd in
                    memmem(raw.baseAddress!, total, nd.baseAddress!, needle.count) != nil
                }
            }
            if hit { return true }
            if n < winSize { return false }                 // EOF
            if keep > 0 {                                   // slide the overlap window
                for i in 0..<keep { buf[i] = buf[total - keep + i] }
                carry = keep
            }
        }
    }

    /// Finder-tag filter: per-file xattr reads for small candidate sets; above the
    /// threshold, pre-filter through Spotlight (`mdfind`) exactly like Cardinal does.
    static let tagMdfindThreshold = 10_000

    static func filterByTags(_ ids: [Int32], groups: [[String]], index: FileIndex) -> [Int32] {
        if ids.count > tagMdfindThreshold, let sets = mdfindTagPathSets(groups: groups) {
            return ids.filter { id in
                let p = index.path(Int(id)).precomposedStringWithCanonicalMapping
                return sets.allSatisfy { $0.contains(p) }
            }
        }
        return ids.filter { id in
            let tags = xattrTagNames(path: index.path(Int(id)))
            guard !tags.isEmpty else { return false }
            return groups.allSatisfy { group in
                group.contains { want in tags.contains { $0.contains(want) } }
            }
        }
    }

    /// Lowercased Finder tag names from com.apple.metadata:_kMDItemUserTags.
    public static func xattrTagNames(path: String) -> [String] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard got > 0,
              let arr = try? PropertyListSerialization.propertyList(
                  from: data.prefix(got), options: [], format: nil) as? [String] else { return [] }
        return arr.map { $0.split(separator: "\n").first.map(String.init)?.lowercased() ?? $0.lowercased() }
    }

    /// One NFC path set per AND-group via `mdfind` (any tag in the group matches).
    private static func mdfindTagPathSets(groups: [[String]]) -> [Set<String>]? {
        var sets: [Set<String>] = []
        for group in groups {
            let pred = group.map { "kMDItemUserTags == \"*\($0)*\"cd" }.joined(separator: " || ")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            proc.arguments = [pred]
            let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let paths = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map { String($0).precomposedStringWithCanonicalMapping }
            sets.append(Set(paths))
        }
        return sets
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
                                 offB: UnsafeBufferPointer<UInt64>,
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

    /// Path bytes for case-insensitive matching: emit the ASCII-folded component
    /// for ordinary names, and the independent Unicode search fold for non-ASCII
    /// names whose fold may have a different byte length.
    @inline(__always)
    private func searchFoldedPathBytes(_ id: Int,
                                       asciiBlob: UnsafePointer<UInt8>,
                                       offB: UnsafeBufferPointer<UInt64>,
                                       lenB: UnsafeBufferPointer<UInt16>,
                                       unicodeBlob: UnsafePointer<UInt8>?,
                                       unicodeOffB: UnsafeBufferPointer<UInt64>,
                                       unicodeLenB: UnsafeBufferPointer<UInt32>,
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
            if unicodeOffB[e] != noUnicodeFoldOffset, let unicodeBlob {
                let o = Int(unicodeOffB[e]); let l = Int(unicodeLenB[e])
                var j = 0
                while j < l && w < cap { out[w] = unicodeBlob[o + j]; w += 1; j += 1 }
            } else {
                let o = Int(offB[e]); let l = Int(lenB[e])
                var j = 0
                while j < l && w < cap { out[w] = asciiBlob[o + j]; w += 1; j += 1 }
            }
        }
        let ro = Int(offB[cur]); let rl = Int(lenB[cur])
        if !(rl == 1 && asciiBlob[ro] == slash) { emit(cur) }
        var s = depth - 1
        while s >= 0 {
            if w < cap { out[w] = slash; w += 1 }
            emit(Int(stack[s])); s -= 1
        }
        if w == 0 && cap > 0 { out[0] = slash; w = 1 }
        return w
    }

    @inline(__always)
    private func foldedNameContains(id: Int,
                                    asciiBase: UnsafePointer<UInt8>,
                                    offB: UnsafeBufferPointer<UInt64>,
                                    lenB: UnsafeBufferPointer<UInt16>,
                                    unicodeBase: UnsafePointer<UInt8>?,
                                    unicodeOffB: UnsafeBufferPointer<UInt64>,
                                    unicodeLenB: UnsafeBufferPointer<UInt32>,
                                    needle: UnsafeRawPointer,
                                    needleLen: Int) -> Bool {
        let o = Int(offB[id]); let l = Int(lenB[id])
        if l >= needleLen, memmem(asciiBase + o, l, needle, needleLen) != nil { return true }
        guard unicodeOffB[id] != noUnicodeFoldOffset, let unicodeBase else { return false }
        let uo = Int(unicodeOffB[id]); let ul = Int(unicodeLenB[id])
        return ul >= needleLen && memmem(unicodeBase + uo, ul, needle, needleLen) != nil
    }

    // MARK: - duplicate-name bitmap (Everything's dupe:)

    private var dupeCache: [Bool] = []
    private var dupeGen = -1
    private let dupeLock = NSLock()

    /// Bitmap of entries whose FOLDED name occurs more than once among live entries
    /// (hash-based; a 64-bit FNV collision could rarely over-mark — acceptable for a
    /// discovery filter). Built once per index mutation, cached. Called under rdlock.
    private func dupeBitmap() -> [Bool] {
        let gen = index.mutationGenLocked
        dupeLock.lock()
        if dupeGen == gen { let c = dupeCache; dupeLock.unlock(); return c }
        dupeLock.unlock()

        let n = index.count
        var counts = [UInt64: Int32](minimumCapacity: n)
        var bitmap = [Bool](repeating: false, count: n)
        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.deleted.withUnsafeBufferPointer { delB in
            let base = fb.baseAddress!
            @inline(__always) func nameHash(_ i: Int) -> UInt64 {
                var h: UInt64 = 0xcbf2_9ce4_8422_2325           // FNV-1a
                let o = Int(offB[i]); let l = Int(lenB[i])
                for j in 0..<l { h = (h ^ UInt64(base[o + j])) &* 0x1_0000_0000_01b3 }
                return h
            }
            for i in 0..<n where !delB[i] { counts[nameHash(i), default: 0] &+= 1 }
            for i in 0..<n where !delB[i] { if counts[nameHash(i)] ?? 0 > 1 { bitmap[i] = true } }
        }}}}

        dupeLock.lock()
        dupeGen = gen; dupeCache = bitmap
        dupeLock.unlock()
        return bitmap
    }

    // MARK: - empty-directory bitmap (Everything's empty:)

    private var emptyCache: [Bool] = []
    private var emptyGen = -1
    private let emptyLock = NSLock()

    /// Bitmap of live directories with NO live children (Everything's `empty:`).
    /// One pass over parent/deleted/objType: mark every live dir, then clear any
    /// entry that a live child points at. Built once per index mutation, cached.
    /// Called under the index read lock (same pattern as dupeBitmap).
    private func emptyDirBitmap() -> [Bool] {
        let gen = index.mutationGenLocked
        emptyLock.lock()
        if emptyGen == gen { let c = emptyCache; emptyLock.unlock(); return c }
        emptyLock.unlock()

        let n = index.count
        var bitmap = [Bool](repeating: false, count: n)
        index.parent.withUnsafeBufferPointer { parB in
        index.deleted.withUnsafeBufferPointer { delB in
        index.objType.withUnsafeBufferPointer { otB in
            for i in 0..<n where !delB[i] && otB[i] == VNODE_VDIR { bitmap[i] = true }
            for i in 0..<n where !delB[i] {
                let p = Int(parB[i])
                if p >= 0 && p < n { bitmap[p] = false }   // has a live child → not empty
            }
        }}}

        emptyLock.lock()
        emptyGen = gen; emptyCache = bitmap
        emptyLock.unlock()
        return bitmap
    }

    /// One term against one haystack, honoring Everything's Match Whole Word (`ww:`)
    /// for exact mode (other modes define their own shape, so ww: applies to exact).
    @inline(__always)
    private func matchTerm(hay: UnsafePointer<UInt8>, hayLen: Int,
                           needle: UnsafePointer<UInt8>, needleLen: Int,
                           mode: MatchMode, wholeWord: Bool) -> MatchOutcome {
        wholeWord && mode == .exact
            ? Matcher.wholeWordExact(hay, hayLen, needle, needleLen)
            : Matcher.match(hay: hay, hayLen: hayLen, needle: needle, needleLen: needleLen, mode: mode)
    }

    @inline(__always)
    private func matchFoldedName(id: Int,
                                 asciiBase: UnsafePointer<UInt8>,
                                 offB: UnsafeBufferPointer<UInt64>,
                                 lenB: UnsafeBufferPointer<UInt16>,
                                 unicodeBase: UnsafePointer<UInt8>?,
                                 unicodeOffB: UnsafeBufferPointer<UInt64>,
                                 unicodeLenB: UnsafeBufferPointer<UInt32>,
                                 needle: UnsafePointer<UInt8>,
                                 needleLen: Int,
                                 mode: MatchMode,
                                 wholeWord: Bool = false) -> MatchOutcome {
        let o = Int(offB[id]); let l = Int(lenB[id])
        var best = matchTerm(hay: asciiBase + o, hayLen: l,
                             needle: needle, needleLen: needleLen, mode: mode, wholeWord: wholeWord)
        guard unicodeOffB[id] != noUnicodeFoldOffset, let unicodeBase else { return best }
        let uo = Int(unicodeOffB[id]); let ul = Int(unicodeLenB[id])
        let folded = matchTerm(hay: unicodeBase + uo, hayLen: ul,
                               needle: needle, needleLen: needleLen, mode: mode, wholeWord: wholeWord)
        if !best.matched || (folded.matched && folded.score > best.score) { best = folded }
        return best
    }

    // MARK: - fast exact substring path

    private func fastExact(needle: [UInt8], sortKey: SortKey, ascending: Bool,
                           limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let gen = index.mutationGenLocked   // safe: called inside the index read lock
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
            index.unicodeFoldBlob.withUnsafeBufferPointer { ufb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
            index.unicodeFoldOff.withUnsafeBufferPointer { uOffB in
            index.unicodeFoldLen.withUnsafeBufferPointer { uLenB in
            index.deleted.withUnsafeBufferPointer { delB in
            needle.withUnsafeBufferPointer { nd in
                let hayBase = fb.baseAddress!
                let unicodeBase = ufb.baseAddress
                let needleBase = UnsafeRawPointer(nd.baseAddress!)
                let needleLen = needle.count
                for id32 in base {
                    let id = Int(id32)
                    if delB[id] { continue }
                    if self.foldedNameContains(id: id, asciiBase: hayBase,
                                               offB: offB, lenB: lenB,
                                               unicodeBase: unicodeBase,
                                               unicodeOffB: uOffB, unicodeLenB: uLenB,
                                               needle: needleBase, needleLen: needleLen) {
                        res.append(id32)
                    }
                }
            }}}}}}}}
            full = res
        } else {
            let order = orderArray(for: sortKey == .relevance ? .name : sortKey)
            let n = order.count
            let nChunks = max(1, min(workerCount, n / 16_000 + 1))
            let chunkSize = (n + nChunks - 1) / nChunks
            var chunkIDs = [[Int32]](repeating: [], count: nChunks)

            index.foldBlob.withUnsafeBufferPointer { fb in
            index.unicodeFoldBlob.withUnsafeBufferPointer { ufb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
            index.unicodeFoldOff.withUnsafeBufferPointer { uOffB in
            index.unicodeFoldLen.withUnsafeBufferPointer { uLenB in
            index.deleted.withUnsafeBufferPointer { delB in
            order.withUnsafeBufferPointer { ordB in
            needle.withUnsafeBufferPointer { nd in
                let hayBase = fb.baseAddress!
                let unicodeBase = ufb.baseAddress
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
                            if self.foldedNameContains(id: id, asciiBase: hayBase,
                                                       offB: offB, lenB: lenB,
                                                       unicodeBase: unicodeBase,
                                                       unicodeOffB: uOffB, unicodeLenB: uLenB,
                                                       needle: needleBase, needleLen: needleLen) {
                                ids.append(Int32(id))
                            }
                        }
                        outIDs[c] = ids
                    }
                }
            }}}}}}}}}
            // chunks each keep ALL their matches (no per-chunk cap) → concat = full set in order
            var merged = [Int32](); merged.reserveCapacity(chunkIDs.reduce(0) { $0 + $1.count })
            for c in 0..<chunkIDs.count { merged.append(contentsOf: chunkIDs[c]) }
            full = merged
        }

        let total = full.count
        let out = total > limit ? Array(full[0..<limit]) : full
        // Cache the COMPLETE match set for the next keystroke. `full` is already the whole set
        // (we cap only the returned `out`), so cache it by a memory bound — NOT the UI display
        // limit — so even a broad first query ("a", 1M+ hits) lets the next char narrow from it
        // instead of rescanning the whole index. ~4 bytes/id → 8M ids ≈ 32MB worst case.
        incLock.lock()
        if total <= Self.incMaxCacheIDs {
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
        index.deleted.withUnsafeBufferPointer { delB in
        order.withUnsafeBufferPointer { ordB in
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var total = 0
                    for k in lo..<hi {
                        let id = Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if delB[id] { continue }   // defensive: skip tombstones (parity with other paths)
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
        }}}
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
        // Refs are laid out group-by-group; `group` marks OR-group membership (all refs
        // of a group share the same negated/isPath, matching the parser's guarantee).
        var termBlob: [UInt8] = []
        var termRefs: [(off: Int, len: Int, group: Int, negated: Bool, isPath: Bool)] = []
        termRefs.reserveCapacity(parsed.termGroups.reduce(0) { $0 + $1.count })
        for (gi, g) in parsed.termGroups.enumerated() {
            for t in g {
                termRefs.append((termBlob.count, t.bytes.count, gi, t.negated, t.scope == .path))
                termBlob.append(contentsOf: t.bytes)
            }
        }
        let termCount = termRefs.count
        // Hoist filter presence out of the loop (avoid per-candidate array access + ARC).
        let hasExts = !parsed.exts.isEmpty, hasSizes = !parsed.sizes.isEmpty
        let hasNotExts = !parsed.notExts.isEmpty, hasNotSizes = !parsed.notSizes.isEmpty
        let hasNotDates = !parsed.notDateRanges.isEmpty
        let df = parsed.dateFrom, dt = parsed.dateTo
        let onlyDirs = parsed.onlyDirs, onlyFiles = parsed.onlyFiles
        let wholeWord = parsed.wholeWord
        let dupeB: [Bool] = parsed.dupesOnly ? dupeBitmap() : []
        let dupesOnly = parsed.dupesOnly
        let emptyB: [Bool] = parsed.emptyDirsOnly ? emptyDirBitmap() : []
        let emptyOnly = parsed.emptyDirsOnly
        let hasLens = !parsed.lenFilters.isEmpty
        let hasAffixes = !parsed.prefixes.isEmpty || !parsed.suffixes.isEmpty
        let hasNotAffixes = !parsed.notPrefixes.isEmpty || !parsed.notSuffixes.isEmpty

        let nChunks = max(1, min(workerCount, n / 8_000 + 1))
        let chunkSize = (n + nChunks - 1) / nChunks
        let pruneThreshold = limit + max(512, limit)
        var chunkIDs = [[Int32]](repeating: [], count: nChunks)
        var chunkScores = [[Int32]](repeating: [], count: nChunks)
        var chunkTotals = [Int](repeating: 0, count: nChunks)

        index.foldBlob.withUnsafeBufferPointer { fb in
        index.unicodeFoldBlob.withUnsafeBufferPointer { ufb in
        index.nameBlob.withUnsafeBufferPointer { nb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.unicodeFoldOff.withUnsafeBufferPointer { uOffB in
        index.unicodeFoldLen.withUnsafeBufferPointer { uLenB in
        index.size.withUnsafeBufferPointer { szB in
        index.mtime.withUnsafeBufferPointer { mtB in
        index.deleted.withUnsafeBufferPointer { delB in
        index.objType.withUnsafeBufferPointer { otB in
        index.parent.withUnsafeBufferPointer { parB in
        order.withUnsafeBufferPointer { ordB in
        termBlob.withUnsafeBufferPointer { tblobB in
        termRefs.withUnsafeBufferPointer { trefsB in
            let fbBase = fb.baseAddress!, nbBase = nb.baseAddress!
            let unicodeBase = ufb.baseAddress
            let tblobBase = tblobB.baseAddress   // non-nil whenever termCount > 0
            // startwith:/endwith: match the ASCII-folded blob (cased blob if case:on),
            // mirroring how terms pick hayBase. The independent Unicode fold lives at
            // different offsets, so non-ASCII names match affixes by their stored bytes
            // only (v1 limitation, same spirit as extMatches).
            let affixBase = caseSensitive ? nbBase : fbBase
            chunkIDs.withUnsafeMutableBufferPointer { outIDs in
            chunkScores.withUnsafeMutableBufferPointer { outScores in
            chunkTotals.withUnsafeMutableBufferPointer { outTot in
                DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                    let lo = c * chunkSize, hi = min(n, lo + chunkSize)
                    if lo >= hi { return }
                    var ids = [Int32](); var total = 0
                    var pairs: [(id: Int32, score: Int32)] = []
                    if relevance {
                        pairs.reserveCapacity(min(hi - lo, pruneThreshold + 1))
                    } else {
                        ids.reserveCapacity(min(hi - lo, limit))
                    }
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
                        // duplicate-name filter (dupe:)
                        if dupesOnly && (id >= dupeB.count || !dupeB[id]) { continue }
                        // empty-folder filter (empty:)
                        if emptyOnly && (id >= emptyB.count || !emptyB[id]) { continue }
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        // include filters (cheap) first
                        if hasLens && !self.lenMatches(l, parsed.lenFilters) { continue }
                        if hasExts && !self.extMatches(fbBase, o, l, parsed.exts) { continue }
                        if hasSizes && !self.sizeMatches(szB[id], parsed.sizes) { continue }
                        if let df, mtB[id] < df { continue }
                        if let dt, mtB[id] >= dt { continue }
                        // negated filters: exclude if the candidate matches any of them
                        if hasNotExts && self.extMatches(fbBase, o, l, parsed.notExts) { continue }
                        if hasNotSizes && self.excludedBySize(szB[id], parsed.notSizes) { continue }
                        if hasNotDates && self.excludedByDate(mtB[id], parsed.notDateRanges) { continue }
                        // terms — raw pointers into the flattened term blob (no per-candidate ARC).
                        // Refs walk group-by-group: a POSITIVE OR-group needs ≥1 alternative to
                        // match (first hit scores and skips the group's remaining refs); a NEGATED
                        // group needs ALL alternatives to miss (each ref checked like a plain NOT).
                        var score = 0; var ok = true
                        var pathLen = -1   // built lazily once per candidate, reused across path terms
                        var ti = 0
                        while ti < termCount {
                            let tr = trefsB[ti]
                            let needlePtr = tblobBase! + tr.off
                            let out: MatchOutcome
                            if tr.isPath {
                                if pathLen < 0 {
                                    if caseSensitive {
                                        pathLen = self.foldedPathBytes(id, blob: nbBase, offB: offB,
                                                                       lenB: lenB, parB: parB, stack: isb, out: psb)
                                    } else {
                                        pathLen = self.searchFoldedPathBytes(id, asciiBlob: fbBase,
                                                                             offB: offB, lenB: lenB,
                                                                             unicodeBlob: unicodeBase,
                                                                             unicodeOffB: uOffB,
                                                                             unicodeLenB: uLenB,
                                                                             parB: parB, stack: isb, out: psb)
                                    }
                                }
                                out = self.matchTerm(hay: psb.baseAddress!, hayLen: pathLen,
                                                     needle: needlePtr, needleLen: tr.len,
                                                     mode: mode, wholeWord: wholeWord)
                            } else if caseSensitive {
                                out = self.matchTerm(hay: nbBase + o, hayLen: l,
                                                     needle: needlePtr, needleLen: tr.len,
                                                     mode: mode, wholeWord: wholeWord)
                            } else {
                                out = self.matchFoldedName(id: id, asciiBase: fbBase,
                                                           offB: offB, lenB: lenB,
                                                           unicodeBase: unicodeBase,
                                                           unicodeOffB: uOffB, unicodeLenB: uLenB,
                                                           needle: needlePtr, needleLen: tr.len,
                                                           mode: mode, wholeWord: wholeWord)
                            }
                            if tr.negated {
                                // negated group: NO alternative may match
                                if out.matched { ok = false; break }
                                ti += 1
                            } else if out.matched {
                                // positive group satisfied: score it, skip its remaining alternatives
                                score += out.score
                                ti += 1
                                while ti < termCount && trefsB[ti].group == tr.group { ti += 1 }
                            } else {
                                // alternative missed: fail only if it was the group's last one
                                ti += 1
                                if ti >= termCount || trefsB[ti].group != tr.group { ok = false; break }
                            }
                        }
                        if !ok { continue }
                        // anchored name-affix filters (startwith:/endwith:)
                        if hasAffixes && !self.affixMatches(affixBase, o, l,
                                                            prefixes: parsed.prefixes,
                                                            suffixes: parsed.suffixes) { continue }
                        if hasNotAffixes && self.excludedByAffix(affixBase, o, l,
                                                                 notPrefixes: parsed.notPrefixes,
                                                                 notSuffixes: parsed.notSuffixes) { continue }
                        total += 1
                        if relevance {
                            pairs.append((id: Int32(id), score: Int32(clamping: score)))
                            if pairs.count > pruneThreshold {
                                pairs.sort { a, b in
                                    if a.score != b.score {
                                        return ascending ? a.score < b.score : a.score > b.score
                                    }
                                    return a.id < b.id
                                }
                                pairs.removeSubrange(limit..<pairs.count)
                            }
                        } else if ids.count < limit {
                            ids.append(Int32(id))
                        }
                    }
                    if relevance && pairs.count > limit {
                        pairs.sort { a, b in
                            if a.score != b.score {
                                    return ascending ? a.score < b.score : a.score > b.score
                            }
                            return a.id < b.id
                        }
                        pairs.removeSubrange(limit..<pairs.count)
                    }
                    if relevance {
                        outIDs[c] = pairs.map { $0.id }
                        outScores[c] = pairs.map { $0.score }
                    } else {
                        outIDs[c] = ids
                    }
                    outTot[c] = total
                    }}
                }
            }}}
        }}}}}}}}}}}}}}}

        let total = chunkTotals.reduce(0, +)
        var out: [Int32]
        if relevance {
            var pairs: [(Int32, Int32)] = []
            pairs.reserveCapacity(min(total, nChunks * limit))
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

    /// `len:` — the name's UTF-8 byte length must satisfy EVERY comparison.
    @inline(__always)
    private func lenMatches(_ l: Int, _ filters: [(SizeOp, Int)]) -> Bool {
        for (op, n) in filters {
            switch op {
            case .gt: if !(l > n) { return false }
            case .lt: if !(l < n) { return false }
            case .ge: if !(l >= n) { return false }
            case .le: if !(l <= n) { return false }
            case .eq: if !(l == n) { return false }
            }
        }
        return true
    }

    /// `startwith:`/`endwith:` — the name bytes must begin/end with EVERY affix.
    @inline(__always)
    private func affixMatches(_ base: UnsafePointer<UInt8>, _ o: Int, _ l: Int,
                              prefixes: [[UInt8]], suffixes: [[UInt8]]) -> Bool {
        for p in prefixes {
            if p.count > l { return false }
            if !p.withUnsafeBufferPointer({ $0.isEmpty || memcmp(base + o, $0.baseAddress!, $0.count) == 0 }) { return false }
        }
        for s in suffixes {
            if s.count > l { return false }
            if !s.withUnsafeBufferPointer({ $0.isEmpty || memcmp(base + o + l - $0.count, $0.baseAddress!, $0.count) == 0 }) { return false }
        }
        return true
    }

    /// Negated affixes: exclude if the name begins/ends with ANY of them.
    @inline(__always)
    private func excludedByAffix(_ base: UnsafePointer<UInt8>, _ o: Int, _ l: Int,
                                 notPrefixes: [[UInt8]], notSuffixes: [[UInt8]]) -> Bool {
        for p in notPrefixes where !p.isEmpty && p.count <= l {
            if p.withUnsafeBufferPointer({ memcmp(base + o, $0.baseAddress!, $0.count) == 0 }) { return true }
        }
        for s in notSuffixes where !s.isEmpty && s.count <= l {
            if s.withUnsafeBufferPointer({ memcmp(base + o + l - $0.count, $0.baseAddress!, $0.count) == 0 }) { return true }
        }
        return false
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
        let gen = index.mutationGenLocked   // safe: called inside the index read lock
        cacheLock.lock()
        if cacheGen != gen { orderCache.removeAll(); cacheGen = gen }
        if let cached = orderCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let order = computeOrder(key)
        cacheLock.lock()
        if cacheGen == gen { orderCache[key] = order }
        cacheLock.unlock()
        return order
    }

    private func computeOrder(_ key: SortKey) -> [Int32] {
        if key == .path { return computePathOrder() }   // true full-path order (folded), not basename
        let n = index.count
        let del = index.deleted
        var ids = [Int32](); ids.reserveCapacity(n)
        for i in 0..<n where !del[i] { ids.append(Int32(i)) }
        switch key {
        case .size:
            let size = index.size
            if useFolderSizes {
                let fs = index._folderSizes()   // under the read lock (orderArray path)
                let ot = index.objType
                @inline(__always) func eff(_ i: Int32) -> Int64 {
                    ot[Int(i)] == VNODE_VDIR ? fs[Int(i)] : size[Int(i)]
                }
                ids.sort { eff($0) != eff($1) ? eff($0) < eff($1) : $0 < $1 }
            } else {
                ids.sort { size[Int($0)] != size[Int($1)] ? size[Int($0)] < size[Int($1)] : $0 < $1 }
            }
        case .dateModified:
            let mt = index.mtime
            ids.sort { mt[Int($0)] != mt[Int($1)] ? mt[Int($0)] < mt[Int($1)] : $0 < $1 }
        case .dateCreated:
            let ct = index.crtime
            ids.sort { ct[Int($0)] != ct[Int($1)] ? ct[Int($0)] < ct[Int($1)] : $0 < $1 }
        case .path:
            break   // handled above by computePathOrder (unreachable; kept exhaustive)
        case .name, .relevance:   // relevance uses name order as the scan base
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

    /// True full-path sort order (OQ1A): reconstruct each LIVE entry's folded
    /// absolute path ONCE into a packed blob, then argsort by those path bytes so
    /// clicking the "Path" column sorts by directory/path — not by basename. Runs
    /// under the index read lock (via `orderArray` → `computeOrder`), and the result
    /// is cached in `orderCache[.path]` like every other order, so the O(n) path
    /// reconstruction happens once per index generation, not per keystroke. The
    /// transient path blob (~40 MB / 1M files) is freed when this returns; only the
    /// `[Int32]` order is retained. Mirrors the fold used by `foldedPathBytes` and the
    /// name sort so path order and name matching stay case-folded-consistent.
    private func computePathOrder() -> [Int32] {
        let n = index.count
        if n == 0 { return [] }
        return index.foldBlob.withUnsafeBufferPointer { fb -> [Int32] in
        index.nameOff.withUnsafeBufferPointer { offB -> [Int32] in
        index.nameLen.withUnsafeBufferPointer { lenB -> [Int32] in
        index.parent.withUnsafeBufferPointer { parB -> [Int32] in
        index.deleted.withUnsafeBufferPointer { delB -> [Int32] in
            let base = fb.baseAddress!
            var pathBlob = [UInt8](); pathBlob.reserveCapacity(n * 24)   // ~avg folded path length
            var offs = [Int]();   offs.reserveCapacity(n)                // start of each path in pathBlob
            var lens = [Int32](); lens.reserveCapacity(n)                // path byte length
            var ids  = [Int32](); ids.reserveCapacity(n)                 // parallel entry ids (live only)
            var scratch = [UInt8](repeating: 0, count: 8192)             // reused per-entry path buffer
            var stack   = [Int32](repeating: 0, count: 4096)             // reused ancestor stack
            scratch.withUnsafeMutableBufferPointer { sb in
            stack.withUnsafeMutableBufferPointer { stk in
                for i in 0..<n where !delB[i] {
                    let w = foldedPathBytes(i, blob: base, offB: offB, lenB: lenB,
                                            parB: parB, stack: stk, out: sb)
                    offs.append(pathBlob.count)
                    lens.append(Int32(w))
                    ids.append(Int32(i))
                    pathBlob.append(contentsOf: UnsafeBufferPointer(start: sb.baseAddress!, count: w))
                }
            }}
            let m = ids.count
            if m == 0 { return [] }
            return pathBlob.withUnsafeBufferPointer { pb -> [Int32] in
                let pbase = pb.baseAddress!
                // First 8 path bytes packed into a UInt64 → most comparisons are one integer
                // compare; memcmp fallback only on an 8-byte tie (same trick as the name sort).
                @inline(__always) func key64(_ p: Int) -> UInt64 {
                    let o = offs[p]; let l = min(Int(lens[p]), 8)
                    var k: UInt64 = 0; var j = 0
                    while j < l { k |= UInt64(pbase[o + j]) << (56 - 8 * j); j += 1 }
                    return k
                }
                var pairs = (0..<m).map { (key64($0), Int32($0)) }   // (key, position-in-ids)
                pairs.sort { a, b in
                    if a.0 != b.0 { return a.0 < b.0 }
                    let pa = Int(a.1), pbp = Int(b.1)
                    let oa = offs[pa], la = Int(lens[pa])
                    let ob = offs[pbp], lb = Int(lens[pbp])
                    let mm = min(la, lb)
                    let r = mm > 0 ? memcmp(pbase + oa, pbase + ob, mm) : 0
                    if r != 0 { return r < 0 }
                    if la != lb { return la < lb }
                    return ids[pa] < ids[pbp]   // stable tiebreak by entry id
                }
                var result = [Int32](); result.reserveCapacity(m)
                for pr in pairs { result.append(ids[Int(pr.1)]) }
                return result
            }
        }}}}}
    }
}

@inline(__always) func foldedBytes(_ s: String) -> [UInt8] {
    searchFoldedBytes(s)
}
