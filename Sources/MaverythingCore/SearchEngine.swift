import Darwin
import Foundation
import UniformTypeIdentifiers

// Append-only (keep `runCount` last): the raw values feed switches/lookup arrays and
// may be serialized later, so reordering would silently remap old sorts.
public enum SortKey: Int, Sendable { case name, path, size, dateModified, dateCreated, relevance, runCount }
public enum SearchScope: Int, Sendable { case nameOnly, fullPath }

public struct SearchResults: Sendable {
    public var ids: [Int32]      // entry indices, in requested order
    public var total: Int        // total matches (may exceed ids.count if truncated)
    public var truncated: Bool
    public var queryMillis: Double
    // `content:` search is bounded (it streams file bodies on demand). When it hits the
    // candidate budget or skips oversized files, the result is INCOMPLETE — surfaced so the
    // UI/CLI/MCP can say "not found *so far*" instead of a false "no matches".
    public var contentIncomplete: Bool = false      // hit the 200k-candidate scan budget
    public var contentSkippedLarge: Int = 0         // files skipped for exceeding the 64 MB cap
}

/// Multi-core search over the packed name blob (the Everything model). A simple
/// exact-substring name query uses the tuned parallel `memmem` scan in precomputed
/// sort order (no per-keystroke sort). Fuzzy / wildcard / filtered / multi-term /
/// path queries go through a general evaluator; `.relevance` ranks by match score.
public final class SearchEngine: @unchecked Sendable {
    private let index: FileIndex
    private let workerCount: Int

    // The `.size` order depends on `useFolderSizes` (folder-subtree totals vs raw size),
    // so the cache key includes it — otherwise toggling folder-sizes without an index
    // mutation reuses a stale size order (Codex + red-team review: a real bug even
    // single-threaded, e.g. two socket requests with different useFolderSizes).
    private struct OrderKey: Hashable { let sort: SortKey; let folderSizes: Bool }
    // Each cached order remembers the state it was built at, keyed PER ORDER (no global dump).
    // [13] incremental order maintenance: name/path orders are attribute-INDEPENDENT (a name is
    // immutable per id; a rename is tombstone+append; a deletion leaves a tombstone the scan
    // skips) so they only need to grow on structural change (append/tombstone) — `structSeen`
    // tracks that via FileIndex's change log, letting an attr-only touch (the overwhelmingly
    // common FS event: an mtime/size change on an existing file) hit an O(1) no-op with NO log
    // scan at all (the bulk of the idle-CPU "live-refresh storm"). size(fs=false)/date orders DO
    // depend on attributes, so they track `appliedSeq` against the log's total seq and grow
    // incrementally from it. fs=true folder-size order stays on the full mutationGen (unchanged;
    // subtree-total cascade is a separate design — non-goal here).
    private struct OrderState {
        var epoch: Int
        var mutGen: Int          // used ONLY by the fs=true .size variant (unchanged keying)
        var appliedSeq: Int      // totalSeq consumed into `ids`
        var structSeen: Int      // structSeqValue at build time (name-family O(1) staleness)
        var ids: [Int32]
    }
    private var orderCache: [OrderKey: OrderState] = [:]
    private let cacheLock = NSLock()

    private enum OrderFamily { case name, attr, fsSize }
    @inline(__always) private func family(_ key: SortKey, folderSizes: Bool) -> OrderFamily {
        if key == .size { return folderSizes ? .fsSize : .attr }
        if key == .dateModified || key == .dateCreated { return .attr }
        return .name    // .name/.path (relevance/runCount already mapped to .name upstream)
    }

    // [13] observability: mvsim asserts on the delta of these across a reconcile.
    private let statsLock = NSLock()
    private var _orderFullRebuilds = 0, _orderIncrementalApplies = 0, _orderNoopHits = 0
    @inline(__always) private func bumpFullRebuild() { statsLock.lock(); _orderFullRebuilds += 1;      statsLock.unlock() }
    @inline(__always) private func bumpIncremental() { statsLock.lock(); _orderIncrementalApplies += 1; statsLock.unlock() }
    @inline(__always) private func bumpNoop()        { statsLock.lock(); _orderNoopHits += 1;           statsLock.unlock() }
    /// TEST/observability: read-only snapshot (mvsim asserts on deltas).
    public func _debugOrderStats() -> (full: Int, incr: Int, noop: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (_orderFullRebuilds, _orderIncrementalApplies, _orderNoopHits)
    }
    public func _debugResetOrderStats() {
        statsLock.lock(); _orderFullRebuilds = 0; _orderIncrementalApplies = 0; _orderNoopHits = 0
        statsLock.unlock()
    }

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

    // [23] general-path "narrow as you type": remember the FULL match set of the last NON-relevance
    // general() call so the next keystroke that provably REFINES it rescans only that set. Separate
    // from fastExact's incLock (different query class, different lock to avoid cross-contention).
    private let genNarrowLock = NSLock()
    private var gnValid = false
    private var gnIDs: [Int32] = []            // full, untruncated, in RETURNED (ascending-applied) order
    private var gnParsed = ParsedQuery()       // signature: terms + filters of the cached query
    private var gnMode: MatchMode = .exact
    private var gnScope: SearchScope = .nameOnly
    private var gnScopeRoot: Int32? = nil
    private var gnSortKey: SortKey = .name
    private var gnAscending = true
    private var gnEpoch = -1
    private var gnStructSeen = -1
    private var gnAttrSeen = -1
    private var gnLiveBuildSeen = -1
    private var gnAttrDependent = false
    // SHOULD-FIX 3: engine OPTION flags read inside general()/orderArray change the match set/order
    // for a byte-identical query with an unchanged structSeq. `wholeNameWildcards` star-wraps glob
    // terms when OFF (changes the glob MATCH SET); `useFolderSizes` flips `.size` between the
    // fsSize and attr order families (changes ORDER). Both are per-request (QueryServer) and
    // GUI-toggleable, so they MUST be part of the narrow key.
    private var gnWholeNameWildcards = true
    private var gnUseFolderSizes = false
    // Reuse the same memory bound as fastExact (8M ids ≈ 32 MB). General sets are ≤ display limit
    // (≤100k) in practice, so this bound is rarely the binding constraint — the untruncated
    // condition (OI-2) is.

    // [23] observability: mvsim asserts hits on a KNOWN-refining keystroke run and full scans
    // on a KNOWN-widening edit. Guarded by statsLock (same pattern as the [13] order stats).
    private var _gnHits = 0, _gnFull = 0
    @inline(__always) private func bumpGnHit()  { statsLock.lock(); _gnHits += 1; statsLock.unlock() }
    @inline(__always) private func bumpGnFull() { statsLock.lock(); _gnFull += 1; statsLock.unlock() }
    public func _debugNarrowStats() -> (hits: Int, full: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (_gnHits, _gnFull)
    }
    public func _debugResetNarrowStats() { statsLock.lock(); _gnHits = 0; _gnFull = 0; statsLock.unlock() }

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    // Caches now key off FileIndex.mutationGen (bumped under the index lock on every
    // mutation), so any change auto-invalidates them. This remains as an explicit
    // "refresh now" that simply advances that counter.
    public func invalidate() { index.bumpMutation() }

    // These four toggles are WRITTEN by the app on the main actor (engine.foldersFirst = …)
    // and READ on the background search/warm queues. Unsynchronized cross-thread access to
    // shared mutable state is a data race (UB in Swift's memory model; a Swift-6 error). They
    // are lock-guarded computed properties so every get/set is atomic — read only a handful of
    // times per search (never per-candidate), so the lock cost is negligible. `search()`
    // additionally SNAPSHOTS foldersFirst/hideHidden into locals once at the top, so a toggle
    // landing mid-search can't apply folders-first/hide-hidden to a needFull-truncated set.
    private let optLock = NSLock()
    private var _useFolderSizes = true, _foldersFirst = false, _hideHidden = false, _wholeNameWildcards = true

    /// Everything 1.5-style folder-size sorting: when on, the Size order ranks a
    /// directory by its live subtree TOTAL (from FileIndex's cached bottom-up pass)
    /// instead of 0. Set from the app's "Index folder sizes" toggle.
    public var useFolderSizes: Bool {
        get { optLock.lock(); defer { optLock.unlock() }; return _useFolderSizes }
        set { optLock.lock(); _useFolderSizes = newValue; optLock.unlock() }
    }

    /// Everything 1.5's "Folders first": group directories above files in every sort
    /// (each group keeps the chosen order). Applied at RESULT level pre-cap, so it
    /// holds for ascending AND descending traversals of the cached orders.
    public var foldersFirst: Bool {
        get { optLock.lock(); defer { optLock.unlock() }; return _foldersFirst }
        set { optLock.lock(); _foldersFirst = newValue; optLock.unlock() }
    }

    /// Live "hide hidden files" (dotfiles/UF_HIDDEN) — a RESULT-level filter, so
    /// toggling is instant with NO reindex (better than Everything's index-level
    /// exclude-hidden). The index always stays complete.
    public var hideHidden: Bool {
        get { optLock.lock(); defer { optLock.unlock() }; return _hideHidden }
        set { optLock.lock(); _hideHidden = newValue; optLock.unlock() }
    }

    /// Run-history provider (Everything's Run Count / frecency). When set, the
    /// `.runCount` sort floats most-run-first and `.relevance` gets a frecency boost.
    public var runStats: RunStats?
    // Resolved tracked-path → id → frecency-score, cached by (index mutationGen,
    // runStats.generation, hour-bucket). buildLiveIndexes bumps mutationGen after it
    // repopulates childrenOf/dirIndexByHash, so a map resolved while those maps were
    // still empty (during crawl / right after snapshot load) is cached under the OLD
    // gen and re-resolved once the live maps exist (Codex + red-team review).
    private let frecencyLock = NSLock()
    private var frecencyCache: [Int32: Double] = [:]
    private var frecencyCacheKey: (gen: Int, runGen: Int, now: Int) = (-1, -1, -1)

    /// tracked id → frecency score, resolved WITH THE INDEX READ LOCK ALREADY HELD so
    /// the ids line up atomically with the search that uses them (Codex review: a split
    /// resolve/scan let a reconcile renumber ids in between). Empty if no runStats.
    private func resolveFrecencyLocked(now: TimeInterval) -> [Int32: Double] {
        guard let rs = runStats else { return [:] }
        let gen = index.mutationGenLocked                // safe: caller holds the read lock
        let runGen = rs.generation
        let nowBucket = Int(now / 3600)                  // re-decay at most hourly (cache-friendly)
        frecencyLock.lock()
        if frecencyCacheKey == (gen, runGen, nowBucket) {
            let c = frecencyCache; frecencyLock.unlock(); return c
        }
        frecencyLock.unlock()
        let scored = rs.scoredPaths(now: now)            // path → score
        let resolved = index.resolveIdsLocked(forPaths: Array(scored.keys))   // no nested lock
        var map = [Int32: Double](minimumCapacity: resolved.count)
        for (path, id) in resolved { if let s = scored[path], s > 0 { map[id] = s } }
        frecencyLock.lock()
        frecencyCache = map; frecencyCacheKey = (gen, runGen, nowBucket)
        frecencyLock.unlock()
        return map
    }

    /// Sort key used for the underlying SCAN order: relevance and runCount both scan
    /// in name order, then reorder by score / frecency afterward.
    @inline(__always) private func scanOrderKey(_ k: SortKey) -> SortKey {
        (k == .relevance || k == .runCount) ? .name : k
    }

    /// Precompute the expensive per-generation caches (sort order + package bitmap) so
    /// the next interactive query is WARM. Call on a BACKGROUND queue after the index
    /// settles: on a live Mac, FSEvents bump the mutation generation and invalidate
    /// these, so without warming a type-chip click pays a cold ~170-430ms rebuild.
    /// Cheap to skip if already warm (orderArray/packageDirBitmap are gen-keyed).
    public func warmCaches(sortKey: SortKey) {
        index.withReadLock {
            _ = orderArray(for: .name)                    // base order for name/relevance/runCount/fuzzy
            let sk = scanOrderKey(sortKey)
            if sk != .name { _ = orderArray(for: sk) }    // the user's active sort, if different
            _ = packageDirBitmap()                        // file:/folder: chips + Folders First
        }
    }

    /// Everything's "Match whole filename when using wildcards" (default ON there
    /// and here). OFF = a wildcard pattern matches ANYWHERE in the name: mic?o
    /// behaves like *mic?o* and now finds "microsoft". Implemented by star-
    /// wrapping glob terms at compile time — the matcher itself stays anchored.
    /// Lock-guarded like the other option toggles (written on main, read on the search queue).
    public var wholeNameWildcards: Bool {
        get { optLock.lock(); defer { optLock.unlock() }; return _wholeNameWildcards }
        set { optLock.lock(); _wholeNameWildcards = newValue; optLock.unlock() }
    }

    /// TEST-ONLY: when true, eligible path-scope queries skip `fastPathScope` and run
    /// through `general` (the full-path-materializing evaluator). mvsim flips this to
    /// prove the prepass returns exactly the same set as the ground-truth scan.
    public var _debugForceGeneralPath = false

    /// `isStale`: an optional, thread-safe predicate the caller sets to "has a newer search
    /// superseded me?". The long post-lock scans (content: reads up to 200k files; regex runs
    /// a pattern per candidate) poll it and bail early, so the serial search queue isn't
    /// blocked by a search whose result will be discarded anyway (Codex — responsiveness).
    public func search(_ query: String, mode: MatchMode = .exact, scope: SearchScope = .nameOnly,
                       sortKey: SortKey = .name, ascending: Bool = true,
                       limit: Int = 100_000, now: TimeInterval = 0, scopeRoot: Int32? = nil,
                       isStale: (@Sendable () -> Bool)? = nil) -> SearchResults {
        // content:/tag: are post-filters that do FILE I/O (read contents / xattrs), so they
        // must run OUTSIDE the index read lock — a long scan must never block the reconciler.
        // The name/metadata scan first narrows candidates under the lock as usual.
        var parsedForGate: ParsedQuery? = nil   // [21] see the gate block below — set alongside `post`
        let post: ParsedQuery? = {
            guard mode != .regex else { return nil }
            let p = QueryParser.parse(query, defaultScope: scope == .fullPath ? .path : .name, now: now)
            parsedForGate = p
            return (p.contentNeedle != nil || !p.tagGroups.isEmpty) ? p : nil
        }()
        // Snapshot the two result-stage toggles ONCE so every stage sees a consistent value —
        // a toggle landing between computing needFull and applying the reorder/filter below
        // would otherwise apply folders-first/hide-hidden to a limit-truncated set.
        let ffOpt = foldersFirst, hhOpt = hideHidden
        // needFull: any post-filter or reorder below needs the WHOLE match set, not a
        // limit-capped prefix — the display `limit` is applied ONCE at the very end
        // (both reviewers: capping between stages dropped a most-run file past `limit`
        // before the run-count reorder could float it up).
        let needFull = post != nil || ffOpt || hhOpt || sortKey == .runCount
        // Run Count scans in a STABLE name-ascending base; the `ascending` flag then
        // orders only the tracked prefix (most-run ↔ least), leaving the untracked tail
        // in a fixed a→z order rather than flipping it with the frecency direction.
        let innerAscending = sortKey == .runCount ? true : ascending
        // Resolve the frecency map and run the scan in the SAME read-lock acquisition
        // so the tracked ids line up with the exact index the scan saw (Codex review).
        var frecency: [Int32: Double] = [:]
        // [34] Regex is dispatched OUTSIDE the index read lock: `regexSearch` does its own
        // bounded per-chunk locking (materialize under lock → match off-lock), so the
        // unbounded/catastrophic regex match never blocks the reconciler's writer lock. Every
        // other mode still runs `_search` inside one `withReadLock` acquisition as before. An
        // EMPTY regex query (nothing to compile) is routed through the normal locked path instead
        // — `_search` treats it like any other empty query (unchanged "show all" behavior).
        let isNonEmptyRegex = mode == .regex && !query.trimmingCharacters(in: .whitespaces).isEmpty
        // [21] Phased buildLiveIndexes (warm snapshot-load path): loadSnapshot leaves the index
        // Phase-A-complete (arrays live, nameMask/typeClass/camelBits at safe "match everything"
        // sentinels, CSR/dirIndexByHash empty) and the background queue fills Phase B (masks)
        // then Phase C (tree) afterwards. Most query shapes are correct straight off the Phase-A
        // sentinels (bloom prefilter no-ops, emptyDirBitmap/_folderSizes are parent-based, isUnder
        // walks parent[] — SPEC-B3-FINAL §2.2's full reader table) and must NOT wait. Only the two
        // shapes that would otherwise return WRONG (not just slower) results wait: type:/notType:
        // filters and relevance ranking need authoritative typeClass/camelBits (B3/B4 — sentinel
        // 0xFF over-broadly matches every type:), and a folder-scope root resolve needs an
        // authoritative dirIndexByHash (C1 — an empty map reads "scope unresolved" and returns
        // EMPTY, a silent wrong answer for a valid folder). MUST run HERE, BEFORE the
        // `index.withReadLock { … _search … }` acquisition below — `_search` runs INSIDE that
        // lock, so waiting there would block holding the rwlock (deadlocks Phase B/C's own brief
        // wrlock, which is exactly what it's trying to publish). `isNonEmptyRegex` is excluded:
        // regexSearch's own scope check is parent-based (C2, Phase-A-safe) and it never reads
        // typeClass/camelBits, so it needs neither wait.
        if !isNonEmptyRegex {
            let needMasks = (parsedForGate.map { !$0.typeMasks.isEmpty || !$0.notTypeMasks.isEmpty } ?? false)
                            || sortKey == .relevance
            let needTree  = (scopeRoot != nil)   // C1 ONLY — empty:/size-sort are Phase-A-correct (C3/C4)
            if needMasks { index.waitForMasks() }
            if needTree  { index.waitForTree() }
        }
        let res: SearchResults
        if isNonEmptyRegex {
            let clock = ContinuousClock(); let start = clock.now
            // Codex P1: the .runCount post-reorder below reads `frecency` for every mode — the
            // regex branch must resolve it too or most-run files never float.
            if sortKey == .runCount {
                frecency = index.withReadLock { resolveFrecencyLocked(now: now) }
            }
            // The "all matches" ceiling is computed INSIDE regexSearch, in the same lock
            // acquisition as its order snapshot (Codex P1: a separately-read index.count can
            // disagree with the order actually scanned).
            res = regexSearch(pattern: query.precomposedStringWithCanonicalMapping, scope: scope,
                              sortKey: sortKey, ascending: innerAscending, limit: limit,
                              start: start, clock: clock, scopeRoot: scopeRoot,
                              needFull: needFull, isStale: isStale)
        } else {
            res = index.withReadLock { () -> SearchResults in
                if sortKey == .relevance || sortKey == .runCount {
                    frecency = resolveFrecencyLocked(now: now)
                }
                // "all matches" ≈ every live entry (the true ceiling), read under the lock
                // so it can't undercount vs the order array the scan walks.
                let innerLimit = needFull ? max(limit, index.count) : limit
                return _search(query, mode: mode, scope: scope, sortKey: sortKey,
                               ascending: innerAscending, limit: innerLimit, now: now, scopeRoot: scopeRoot,
                               frecency: frecency, isStale: isStale)
            }
        }
        // From here every stage works on the FULL set; `total` tracks live match count.
        var ids = res.ids
        var total = res.total
        var extraMillis = 0.0
        var contentIncomplete = false
        var contentSkippedLarge = 0
        if let p = post {
            let clock = ContinuousClock(); let t0 = clock.now
            if !p.tagGroups.isEmpty { ids = Self.filterByTags(ids, groups: p.tagGroups, index: index) }
            if let needle = p.contentNeedle {
                let c = Self.filterByContent(ids, needle: needle, caseSensitive: p.caseSensitive,
                                             index: index, isStale: isStale)
                ids = c.ids; contentIncomplete = c.incomplete; contentSkippedLarge = c.skippedLarge
            }
            total = ids.count
            extraMillis += secondsBetween(t0, clock.now) * 1000
        }
        if hhOpt {
            let hid = index.withReadLock { index.hidden }   // COW snapshot, race-free
            ids = ids.filter { Int($0) < hid.count && !hid[Int($0)] }
            total = ids.count
        }
        if sortKey == .runCount {
            // Everything's Run Count sort: tracked (opened-before) matches float to the
            // front in frecency order; everything else keeps the underlying name order.
            // Ordinal tiebreak keeps equal-frecency ties in stable name order (Swift's
            // sort isn't stable — Codex review).
            var tracked: [(id: Int32, score: Double, ord: Int)] = []
            var rest: [Int32] = []
            rest.reserveCapacity(ids.count)
            for (ord, id) in ids.enumerated() {
                if let s = frecency[id] { tracked.append((id, s, ord)) } else { rest.append(id) }
            }
            tracked.sort { a, b in
                a.score != b.score ? (ascending ? a.score < b.score : a.score > b.score) : a.ord < b.ord
            }
            ids = tracked.map(\.id); ids.append(contentsOf: rest)
        }
        if ffOpt {
            // Stable dir/file partition. NOTE: this runs AFTER the run-count reorder, so
            // with both on, folders group above files and frecency ordering holds only
            // WITHIN each group — Folders First is an explicit override (red-team review).
            // objType AND packageDirBitmap read index arrays, so both must be under ONE
            // read lock (Codex: packageDirBitmap outside the lock raced live reconcile).
            let (ot, pkg): ([UInt8], [Bool]) = index.withReadLock { (index.objType, packageDirBitmap()) }
            var dirs: [Int32] = []; var files: [Int32] = []
            dirs.reserveCapacity(ids.count); files.reserveCapacity(ids.count)
            for id in ids {
                let i = Int(id)
                if i < ot.count, ot[i] == VNODE_VDIR, !(i < pkg.count && pkg[i]) { dirs.append(id) }
                else { files.append(id) }
            }
            ids = dirs; ids.append(contentsOf: files)
        }
        // single final cap
        let capped = ids.count > limit ? Array(ids[0..<limit]) : ids
        return SearchResults(ids: capped, total: total, truncated: total > capped.count,
                             queryMillis: res.queryMillis + extraMillis,
                             contentIncomplete: contentIncomplete, contentSkippedLarge: contentSkippedLarge)
    }

    // MARK: - post-lock filters (content: / tag:) — Everything 1.4-style on-demand

    private static let contentMaxFileBytes: Int64 = 64 << 20     // skip files > 64 MB
    public static let contentMaxCandidates = 200_000             // scan budget (bare `content:` safety) — surfaced in the UI warning

    /// On-demand file-content substring (ASCII case-insensitive unless case:on) — the
    /// same 64 KiB-window streaming model Cardinal uses; no content index is kept.
    static func filterByContent(_ ids: [Int32], needle: [UInt8], caseSensitive: Bool,
                                index: FileIndex,
                                isStale: (@Sendable () -> Bool)? = nil) -> (ids: [Int32], incomplete: Bool, skippedLarge: Int) {
        guard !needle.isEmpty else { return (ids, false, 0) }
        let folded = caseSensitive ? needle : needle.map(asciiLower)
        var out: [Int32] = []
        var scanned = 0
        var skippedLarge = 0
        var incomplete = false
        for (i, id) in ids.enumerated() {
            // Superseded by a newer query? Stop reading files — the result is about to be
            // dropped, and each iteration can be a full file open+scan.
            if i & 0xFF == 0, isStale?() == true { break }
            let r = index.row(Int(id))
            if r.isDir { continue }
            if r.size > contentMaxFileBytes { skippedLarge += 1; continue }
            if scanned >= contentMaxCandidates { incomplete = true; break }   // budget → truncated, not frozen
            scanned += 1
            if fileContains(path: r.path, needle: folded, caseSensitive: caseSensitive) {
                out.append(id)
            }
        }
        return (out, incomplete, skippedLarge)
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
                         scopeRoot: Int32?, frecency: [Int32: Double] = [:],
                         isStale: (@Sendable () -> Bool)? = nil) -> SearchResults {
        let clock = ContinuousClock()
        let start = clock.now
        // [34] Regex mode (whole query = one pattern, no term-splitting) is no longer dispatched
        // from here: `search()` now routes it to `regexSearch` BEFORE acquiring the index read
        // lock (regexSearch does its own per-chunk locking off the writer's back — see the
        // "Critical call-site change" note at regexSearch's definition). A non-empty regex query
        // never reaches `_search`; an EMPTY regex query still does and falls through below,
        // behaving like any other empty query (unchanged).

        let parsed = QueryParser.parse(query, defaultScope: scope == .fullPath ? .path : .name, now: now)

        // empty query → return the chosen order directly (unless scoped to a folder).
        // MUST skip tombstones: the name/path order cache is no longer rebuilt on deletion
        // (it's keyed on epoch+count — see orderArray), so the cached order can retain ids
        // that were tombstoned since it was built. The general scan already skips delB; this
        // fast path must too, or the default "show all" view shows deleted files (Codex
        // cross-review caught this regression from the epoch+count keying). `total` = live
        // count via the O(1) running deleted counter (no O(n) rescan).
        if parsed.isEmpty && scopeRoot == nil {
            let order = orderArray(for: scanOrderKey(sortKey))
            let n = order.count
            let del = index.deleted   // COW snapshot under the read lock
            var out = [Int32](); out.reserveCapacity(min(limit, n))
            var k = 0
            while k < n && out.count < limit {
                let id = ascending ? order[k] : order[n - 1 - k]
                if Int(id) >= del.count || !del[Int(id)] { out.append(id) }
                k += 1
            }
            let total = index.count - index.deletedCountLocked   // live entries (tombstones excluded)
            return SearchResults(ids: out, total: total, truncated: total > out.count,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }

        // fast path: a single positive exact name term, no filters, no folder scope.
        // Relevance sort is EXCLUDED (mirrors the path fast path below): fastExact returns the
        // chosen argsort order (i.e. NAME order for relevance's name scan base), so routing a
        // relevance query here silently showed ALPHABETICAL order while the UI said "Relevance"
        // — the single most common relevance query was unranked. `general` scores exact/prefix/
        // boundary/short + frecency + recency, so relevance flows there instead. Name/size/date
        // sorts keep the fast path (and its per-keystroke incremental narrowing).
        if mode == .exact, let needle = parsed.simpleName, !parsed.caseSensitive, scopeRoot == nil,
           sortKey != .relevance {
            return fastExact(needle: needle, sortKey: sortKey, ascending: ascending,
                             limit: limit, start: start, clock: clock)
        }

        // fast path: a single positive exact PATH term (`path:foo` / full-path mode), no
        // filters, no folder scope. A directory-prefix prepass avoids materializing every
        // candidate's full path (the general path's ~100ms → ~10-20ms). `_debugForceGeneralPath`
        // routes these back through `general` so mvsim can A/B the two for equivalence.
        if mode == .exact, let needle = parsed.simplePath, scopeRoot == nil,
           sortKey != .relevance, needle.count <= Self.fastPathMaxNeedle,
           !needle.isEmpty, !_debugForceGeneralPath {
            return fastPathScope(needle: needle, sortKey: sortKey, ascending: ascending,
                                 limit: limit, start: start, clock: clock)
        }

        return general(parsed: parsed, mode: mode, scope: scope, sortKey: sortKey, ascending: ascending,
                       limit: limit, start: start, clock: clock, scopeRoot: scopeRoot,
                       frecency: frecency, now: now)
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

    // MARK: - package-directory bitmap (Finder semantics: a package is a FILE)

    private var pkgCache: [Bool] = []
    private var pkgGen = -1
    private let pkgLock = NSLock()
    // ext → is-package, seeded with the common cases and extended by on-disk probes.
    private var extPkgMap: [String: Bool] = [
        "app": true, "bundle": true, "appex": true, "plugin": true, "kext": true,
        "mlmodelc": true, "xcodeproj": true, "playground": true, "docset": true,
        "photoslibrary": true, "musiclibrary": true, "tvlibrary": true, "fcpbundle": true,
        "framework": false, "sdk": false, "platform": false, "lproj": false, "asset": false,
    ]

    /// Bitmap of directories whose extension marks them as a PACKAGE (.app, .bundle,
    /// .photoslibrary … but NOT .framework) — Finder treats those as files, so the
    /// folder:/file: filters and the Folders/Files chips classify them as files too.
    /// Cached per mutationGen; ext→package decisions memoized via UTType.
    private func packageDirBitmap() -> [Bool] {
        let gen = index.mutationGenLocked
        pkgLock.lock()
        if pkgGen == gen { let c = pkgCache; pkgLock.unlock(); return c }
        pkgLock.unlock()

        let n = index.count
        var bitmap = [Bool](repeating: false, count: n)
        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.objType.withUnsafeBufferPointer { otB in
        index.deleted.withUnsafeBufferPointer { delB in
            let base = fb.baseAddress!
            for i in 0..<n where !delB[i] && otB[i] == VNODE_VDIR {
                let o = Int(offB[i]); let l = Int(lenB[i])
                var dot = -1
                var j = l - 1
                while j > 0 { if base[o + j] == UInt8(ascii: ".") { dot = j; break }; j -= 1 }
                guard dot > 0, dot < l - 1 else { continue }
                let ext = String(decoding: UnsafeBufferPointer(start: base + o + dot + 1, count: l - dot - 1),
                                 as: UTF8.self)
                pkgLock.lock()
                let known = extPkgMap[ext]
                pkgLock.unlock()
                let isPkg: Bool
                if let known { isPkg = known }
                else {
                    // Headless UTType gives dyn.* types, so resolve each NEW extension
                    // ONCE by probing a real on-disk item's isPackageKey (Foundation/LS).
                    let url = URL(fileURLWithPath: self.index._path(i))
                    isPkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
                    pkgLock.lock(); extPkgMap[ext] = isPkg; pkgLock.unlock()
                }
                if isPkg { bitmap[i] = true }
            }
        }}}}}

        pkgLock.lock()
        pkgGen = gen; pkgCache = bitmap
        pkgLock.unlock()
        return bitmap
    }

    /// One term against one haystack, honoring Everything's Match Whole Word (`ww:`)
    /// for exact mode (other modes define their own shape, so ww: applies to exact).
    @inline(__always)
    private func matchTerm(hay: UnsafePointer<UInt8>, hayLen: Int,
                           needle: UnsafePointer<UInt8>, needleLen: Int,
                           mode: MatchMode, wholeWord: Bool, camelBits: UInt64 = 0) -> MatchOutcome {
        wholeWord && mode == .exact
            ? Matcher.wholeWordExact(hay, hayLen, needle, needleLen)
            : Matcher.match(hay: hay, hayLen: hayLen, needle: needle, needleLen: needleLen,
                            mode: mode, camelBits: camelBits)
    }

    // [28] camelBits applies to the ASCII/cased scan only — the Unicode-fold segment has
    // different byte offsets/lengths, so camelBits does NOT align there (pass 0, separator-
    // only; ASCII segment is scanned first and is primary, and camelCase is an ASCII-case
    // concept). See FileIndex.swift §2 coordinate-space note.
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
                                 wholeWord: Bool = false,
                                 camelBits: UInt64 = 0) -> MatchOutcome {
        let o = Int(offB[id]); let l = Int(lenB[id])
        var best = matchTerm(hay: asciiBase + o, hayLen: l,
                             needle: needle, needleLen: needleLen, mode: mode, wholeWord: wholeWord,
                             camelBits: camelBits)
        guard unicodeOffB[id] != noUnicodeFoldOffset, let unicodeBase else { return best }
        let uo = Int(unicodeOffB[id]); let ul = Int(unicodeLenB[id])
        let folded = matchTerm(hay: unicodeBase + uo, hayLen: ul,
                               needle: needle, needleLen: needleLen, mode: mode, wholeWord: wholeWord,
                               camelBits: 0)
        if !best.matched || (folded.matched && folded.score > best.score) { best = folded }
        return best
    }

    /// [26] DP-refine counterpart of `matchFoldedName`, fuzzy-only: re-scores an
    /// ALREADY-GREEDY-MATCHED candidate's name (both fold segments, best-of, mirroring
    /// OI-A) with the bounded DP scorer. Called only on the retained per-chunk survivors
    /// (§4 S1: refine-after-prune), never on the full scan.
    @inline(__always)
    private func matchFoldedNameDP(id: Int,
                                   asciiBase: UnsafePointer<UInt8>,
                                   offB: UnsafeBufferPointer<UInt64>,
                                   lenB: UnsafeBufferPointer<UInt16>,
                                   unicodeBase: UnsafePointer<UInt8>?,
                                   unicodeOffB: UnsafeBufferPointer<UInt64>,
                                   unicodeLenB: UnsafeBufferPointer<UInt32>,
                                   needle: UnsafePointer<UInt8>,
                                   needleLen: Int,
                                   camelBits: UInt64,
                                   dp: SearchEngine.DPScratchPtrs) -> MatchOutcome {
        let o = Int(offB[id]); let l = Int(lenB[id])
        let greedyA = Matcher.fuzzy(asciiBase + o, l, needle, needleLen, camelBits)
        var best = greedyA.matched
            ? Matcher.fuzzyDPRefine(hay: asciiBase + o, hayLen: l, needle: needle, needleLen: needleLen,
                                    camelBits: camelBits, prev: dp.prev, curr: dp.curr,
                                    prevStart: dp.prevStart, currStart: dp.currStart,
                                    prevRun: dp.prevRun, currRun: dp.currRun, greedy: greedyA)
            : MatchOutcome.no
        guard unicodeOffB[id] != noUnicodeFoldOffset, let unicodeBase else { return best }
        let uo = Int(unicodeOffB[id]); let ul = Int(unicodeLenB[id])
        let greedyU = Matcher.fuzzy(unicodeBase + uo, ul, needle, needleLen, 0)
        let folded = greedyU.matched
            ? Matcher.fuzzyDPRefine(hay: unicodeBase + uo, hayLen: ul, needle: needle, needleLen: needleLen,
                                    camelBits: 0, prev: dp.prev, curr: dp.curr,
                                    prevStart: dp.prevStart, currStart: dp.currStart,
                                    prevRun: dp.prevRun, currRun: dp.currRun, greedy: greedyU)
            : MatchOutcome.no
        if !best.matched || (folded.matched && folded.score > best.score) { best = folded }
        return best
    }

    /// Bundle of the six per-chunk DP scratch row pointers ([26] §4/§9: allocated once
    /// per chunk, reused across candidates — passed by value since it's just 6 pointers).
    struct DPScratchPtrs {
        let prev, curr, prevStart, currStart, prevRun, currRun: UnsafeMutableBufferPointer<Int32>
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
            let order = orderArray(for: scanOrderKey(sortKey))
            let n = order.count
            let nChunks = max(1, min(workerCount, n / 16_000 + 1))
            let chunkSize = (n + nChunks - 1) / nChunks
            var chunkIDs = [[Int32]](repeating: [], count: nChunks)
            // Character bloom prefilter for the cold full scan (a single exact needle):
            // reject names that can't contain the needle's chars before the byte scan.
            let needleMask = FileIndex.maskOf(needle)
            // For a SINGLE ascii a-z/0-9 needle, the bloom bit is collision-free (charBit maps
            // each such char to its own bit), and nameMask is the OR of char-presence over both
            // fold blobs — exactly what foldedNameContains verifies. So a passing bloom test IS
            // a definite match: skip the redundant per-candidate memmem over ~2M names. (Only
            // alnum: non-alnum single chars like '.'/'-' share collision buckets, so they keep
            // the memmem.)
            let b0 = needle.first ?? 0
            let singleCharExact = needle.count == 1 &&
                ((b0 >= 97 && b0 <= 122) || (b0 >= 48 && b0 <= 57))

            index.foldBlob.withUnsafeBufferPointer { fb in
            index.unicodeFoldBlob.withUnsafeBufferPointer { ufb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
            index.unicodeFoldOff.withUnsafeBufferPointer { uOffB in
            index.unicodeFoldLen.withUnsafeBufferPointer { uLenB in
            index.deleted.withUnsafeBufferPointer { delB in
            index.nameMask.withUnsafeBufferPointer { maskB in
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
                            if needleMask & maskB[id] != needleMask { continue }   // bloom reject
                            if singleCharExact {          // bloom pass == match (see above)
                                ids.append(Int32(id)); continue
                            }
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
            }}}}}}}}}}
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

    /// Path needles at or below this length use the prepass; longer ones fall back to the
    /// general evaluator (they'd blow up the transient tail store, and are rare).
    private static let fastPathMaxNeedle = 32

    /// PATH-scope fast path (`path:foo`, or a bare term in full-path mode ⌃U): decide, for
    /// every entry, whether the needle appears anywhere in its full folded path WITHOUT
    /// materializing that path per candidate — which is what makes the general evaluator
    /// ~100ms on deep trees. Entries are stored parent-before-child, so one forward pass
    /// can carry each entry's answer down from its parent:
    ///
    ///   contains(e) = contains(parent) OR (needle ⊆ name(e)) OR (needle spans the
    ///                 parent-tail + "/" + name(e) boundary)
    ///
    /// keeping only each directory's last (needleLen-1) folded path bytes (`tail`) — enough
    /// to catch any match straddling the dir/child join. Byte-for-byte identical to the
    /// general path scan (mvsim proves it via `_debugForceGeneralPath`), 5-10x faster.
    private func fastPathScope(needle: [UInt8], sortKey: SortKey, ascending: Bool,
                               limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchResults {
        let nLen = needle.count
        let tailCap = nLen - 1                       // bytes of a dir's path we must remember
        let n = index.count
        let slash = UInt8(ascii: "/")

        // Per-DIRECTORY only (dirs are the dependency chain; files are leaves): does the
        // needle occur in this dir's full path, and its last `tailCap` folded path bytes.
        // dirContains[p]/dirTail[p] are read by p's children in the parallel phase below.
        var dirContains = [Bool](repeating: false, count: n)
        // never empty (max(…,1)) so its baseAddress is non-nil even when tailCap == 0
        // (a 1-char needle) — the boundary probe still needs to emit the "/" separator.
        var dirTail = [UInt8](repeating: 0, count: max(n &* tailCap, 1))
        var dirTailLen = [UInt8](repeating: 0, count: n)
        var pathScopeResult = SearchResults(ids: [], total: 0, truncated: false, queryMillis: 0)

        // reusable helper: a folded boundary probe `parentTail + "/" + nameHead` → does it
        // contain the needle? (catches a match straddling the parent|child join). Also the
        // shared "entry i's folded name segment" accessor.
        needle.withUnsafeBufferPointer { nd in
        index.foldBlob.withUnsafeBufferPointer { fb in
        index.unicodeFoldBlob.withUnsafeBufferPointer { ufb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.unicodeFoldOff.withUnsafeBufferPointer { uOffB in
        index.unicodeFoldLen.withUnsafeBufferPointer { uLenB in
        index.parent.withUnsafeBufferPointer { parB in
        index.objType.withUnsafeBufferPointer { otB in
        index.deleted.withUnsafeBufferPointer { delB in
            let fbBase = fb.baseAddress!
            let ufbBase = ufb.baseAddress
            let ndBase = UnsafeRawPointer(nd.baseAddress!)
            @inline(__always) func nameSeg(_ i: Int) -> (UnsafePointer<UInt8>, Int) {
                if uOffB[i] != noUnicodeFoldOffset, let ufbBase {
                    return (ufbBase + Int(uOffB[i]), Int(uLenB[i]))
                }
                return (fbBase + Int(offB[i]), Int(lenB[i]))
            }
            // needle in (parentTail + "/" + nameHead), written into caller's scratch.
            @inline(__always) func spanHit(_ pTail: Int, _ pBase: Int, _ nmPtr: UnsafePointer<UInt8>,
                                            _ nmLen: Int, _ tb: UnsafePointer<UInt8>,
                                            _ sp: UnsafeMutablePointer<UInt8>) -> Bool {
                var w = 0, j = 0
                while j < pTail { sp[w] = tb[pBase + j]; w += 1; j += 1 }
                sp[w] = slash; w += 1
                let headTake = min(tailCap, nmLen); j = 0
                while j < headTake { sp[w] = nmPtr[j]; w += 1; j += 1 }
                return w >= nLen && memmem(sp, w, ndBase, nLen) != nil
            }

            // ---- Phase 1 (serial, DIRECTORIES only): carry contains/tail down the tree.
            dirContains.withUnsafeMutableBufferPointer { dcB in
            dirTail.withUnsafeMutableBufferPointer { dtB in
            dirTailLen.withUnsafeMutableBufferPointer { dtlB in
                let dtBase = dtB.baseAddress!
                var span = [UInt8](repeating: 0, count: max(2 * tailCap + 1, 1))
                span.withUnsafeMutableBufferPointer { spB in
                    let spBase = spB.baseAddress!
                    for i in 0..<n where otB[i] == VNODE_VDIR {
                        let (nmPtr, nmLen) = nameSeg(i)
                        let p = Int(parB[i])
                        var hit = nmLen >= nLen && memmem(nmPtr, nmLen, ndBase, nLen) != nil
                        if p < 0 || p >= i || otB[p] != VNODE_VDIR {
                            // root (or defensive): path IS the name, except "/" = empty segment.
                            if nmLen == 1 && nmPtr[0] == slash { dcB[i] = false; dtlB[i] = 0; continue }
                            dcB[i] = hit
                            if tailCap > 0 {
                                let take = min(tailCap, nmLen)
                                for j in 0..<take { dtBase[i &* tailCap &+ j] = nmPtr[nmLen - take + j] }
                                dtlB[i] = UInt8(take)
                            }
                            continue
                        }
                        let pTail = Int(dtlB[p]); let pBase = p &* tailCap
                        if !hit { hit = spanHit(pTail, pBase, nmPtr, nmLen, dtBase, spBase) }
                        dcB[i] = dcB[p] || hit
                        if tailCap > 0 {
                            if nmLen >= tailCap {
                                for j in 0..<tailCap { dtBase[i &* tailCap &+ j] = nmPtr[nmLen - tailCap + j] }
                                dtlB[i] = UInt8(tailCap)
                            } else {
                                var w = 0
                                let fromParent = min(tailCap - nmLen - 1, pTail)
                                if fromParent > 0 {
                                    for j in (pTail - fromParent)..<pTail { dtBase[i &* tailCap &+ w] = dtBase[pBase + j]; w += 1 }
                                }
                                if w < tailCap { dtBase[i &* tailCap &+ w] = slash; w += 1 }
                                var j = 0
                                while j < nmLen && w < tailCap { dtBase[i &* tailCap &+ w] = nmPtr[j]; w += 1; j += 1 }
                                dtlB[i] = UInt8(w)
                            }
                        }
                    }
                }
            }}}

            // ---- Phase 2 (PARALLEL over sort order): decide each candidate cheaply.
            //  dir  → dirContains[id];  leaf → dirContains[parent] OR needle∈name OR boundary.
            let order = orderArray(for: scanOrderKey(sortKey))
            let oc = order.count
            let nChunks = max(1, min(workerCount, oc / 16_000 + 1))
            let chunkSize = (oc + nChunks - 1) / nChunks
            var chunkIDs = [[Int32]](repeating: [], count: nChunks)
            dirContains.withUnsafeBufferPointer { dcB in
            dirTail.withUnsafeBufferPointer { dtB in
            dirTailLen.withUnsafeBufferPointer { dtlB in
            order.withUnsafeBufferPointer { ordB in
                let dtBase = dtB.baseAddress!
                chunkIDs.withUnsafeMutableBufferPointer { outIDs in
                    DispatchQueue.concurrentPerform(iterations: nChunks) { c in
                        let lo = c * chunkSize, hi = min(oc, lo + chunkSize)
                        if lo >= hi { return }
                        var ids = [Int32]()
                        var span = [UInt8](repeating: 0, count: max(2 * tailCap + 1, 1))
                        span.withUnsafeMutableBufferPointer { spB in
                            let spBase = spB.baseAddress!
                            for k in lo..<hi {
                                let id = Int(ascending ? ordB[k] : ordB[oc - 1 - k])
                                if delB[id] { continue }
                                if otB[id] == VNODE_VDIR { if dcB[id] { ids.append(Int32(id)) }; continue }
                                let (nmPtr, nmLen) = nameSeg(id)
                                let p = Int(parB[id])
                                var matched = nmLen >= nLen && memmem(nmPtr, nmLen, ndBase, nLen) != nil
                                if !matched, p >= 0 {
                                    if dcB[p] { matched = true }
                                    // spanHit is safe when the parent tail is empty (pTail==0):
                                    // it emits only the "/" separator + name head, never reads dtBase.
                                    else { matched = spanHit(Int(dtlB[p]), p &* tailCap, nmPtr, nmLen, dtBase, spBase) }
                                }
                                if matched { ids.append(Int32(id)) }
                            }
                        }
                        outIDs[c] = ids
                    }
                }
            }}}}

            var full = [Int32](); full.reserveCapacity(chunkIDs.reduce(0) { $0 + $1.count })
            for c in 0..<chunkIDs.count { full.append(contentsOf: chunkIDs[c]) }
            let total = full.count
            let out = total > limit ? Array(full[0..<limit]) : full
            pathScopeResult = SearchResults(ids: out, total: total, truncated: total > out.count,
                                            queryMillis: secondsBetween(start, clock.now) * 1000)
        }}}}}}}}}}

        return pathScopeResult
    }

    /// True if `bytes` begins with `prefix` (byte-wise).
    @inline(__always)
    private static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        guard prefix.count <= bytes.count else { return false }
        for i in 0..<prefix.count where bytes[i] != prefix[i] { return false }
        return true
    }

    // MARK: - regex mode (power mode; builds a String per candidate, so slower)

    /// [34] Single-flight, single-threaded (OI-4: NSRegularExpression parallelism dropped for
    /// correctness — a follow-up could parallelize the off-lock match while keeping single-flight
    /// per search, since `firstMatch` is documented thread-safe). Chunk = 64k candidates (16k for
    /// `.fullPath`, SHOULD-FIX 5 — path strings are ~4KB vs. names' few bytes). Per chunk: lock →
    /// materialize `(id, String)` → unlock → match OFF-lock. Superseded between and within chunks.
    /// Final tombstone re-filter under one last lock.
    ///
    /// **Critical call-site change**: `search()` dispatches here BEFORE acquiring the index read
    /// lock (unlike every other mode, which runs inside `_search` under `index.withReadLock`) —
    /// same structural move `content:`/`tag:` already got. `regexSearch` must be called OUTSIDE
    /// that lock; it does its own per-chunk locking below, so the unbounded/catastrophic part (the
    /// actual regex match) NEVER holds the index lock, and the reconciler's writer lock can always
    /// grab it in the inter-chunk gap.
    private func regexSearch(pattern: String, scope: SearchScope, sortKey: SortKey, ascending: Bool,
                             limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock,
                             scopeRoot: Int32?, needFull: Bool = false,
                             isStale: (@Sendable () -> Bool)? = nil) -> SearchResults {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return SearchResults(ids: [], total: 0, truncated: false,
                                 queryMillis: secondsBetween(start, clock.now) * 1000)
        }
        // Order array under the lock (cached; cheap). This is the ENGINE's own cached [Int32], NOT
        // an index SoA buffer — reading it does NOT fork an index array on the writer's next
        // mutation (that COW hazard is why we re-materialize names per chunk instead of
        // snapshotting index.nameBlob/parent/etc.).
        // epoch0 + effLimit captured in the SAME lock acquisition as the order snapshot (Codex
        // P0/P1): within one epoch ids are append-only (never remapped/out-of-range), so chunks
        // that verify the epoch may safely read _name/_path; a clear()/snapshot-load mid-scan
        // bumps the epoch and the scan aborts instead of trapping or emitting remapped ids. The
        // "all matches" ceiling likewise must come from THIS snapshot, not an earlier count read.
        let (order, epoch0, effLimit): ([Int32], Int, Int) = index.withReadLock {
            let o = orderArray(for: scanOrderKey(sortKey))
            return (o, index.epochLocked, needFull ? max(limit, o.count) : limit)
        }
        let limit = effLimit
        let n = order.count
        let usePath = (scope == .fullPath)
        // SHOULD-FIX 5: fullPath materializes reconstructed PATH strings (up to ~4096 B each on a
        // deep tree). At 64k rows that is ~256 MB transient per chunk, not the tens-of-MB the name-
        // scope estimate implies. Bounded, but a real spike — use a 16k chunk for fullPath (≤~64 MB)
        // and keep 64k for name scope (short strings). More lock cycles for fullPath (~128 at 2M)
        // but each still holds only long enough to build ≤16k strings — the writer-starvation bound
        // is per-chunk, not total, so this only IMPROVES writer interruptibility.
        let chunk = usePath ? 16_000 : 64_000

        var matched: [Int32] = []          // ids that matched, in scan (sort) order
        var superseded = false
        var k = 0
        while k < n && !superseded {
            if isStale?() == true { break }                    // new keystroke → abort remaining chunks
            let hi = min(n, k + chunk)
            // --- UNDER LOCK: materialize this chunk's candidates only (no big-array snapshot) ---
            var batch: [(id: Int32, s: String)] = []
            batch.reserveCapacity(hi - k)
            index.withReadLock {
                guard index.epochLocked == epoch0 else { superseded = true; return }   // Codex P0
                index.parent.withUnsafeBufferPointer { parB in
                index.deleted.withUnsafeBufferPointer { delB in
                    for j in k..<hi {
                        let id = Int(ascending ? order[j] : order[n - 1 - j])
                        if id < delB.count, delB[id] { continue }              // current tombstone
                        if let root = scopeRoot, !self.isUnder(id, root: root, parentB: parB) { continue }
                        batch.append((Int32(id), usePath ? self.index._path(id) : self.index._name(id)))
                    }
                }}
            }
            // --- OFF LOCK: run the (potentially catastrophic) pattern; poll isStale every 512 rows ---
            for (i, item) in batch.enumerated() {
                if i & 0x1FF == 0, isStale?() == true { superseded = true; break }
                let r = NSRange(item.s.startIndex..., in: item.s)
                if re.firstMatch(in: item.s, options: [], range: r) != nil { matched.append(item.id) }
            }
            k = hi
        }

        // --- FINAL EMIT under one lock: re-filter tombstones with CURRENT delB, cap at limit ---
        // An id tombstoned AFTER its chunk was materialized must not be emitted. `matched` is
        // already in sort order; total = live-and-matched count.
        let (out, total): ([Int32], Int) = index.withReadLock {
            guard index.epochLocked == epoch0 else { return ([], 0) }   // Codex P0: dead-index ids
            return index.deleted.withUnsafeBufferPointer { delB in
                var o = [Int32](); o.reserveCapacity(min(matched.count, limit))
                var t = 0
                for id in matched {
                    let i = Int(id)
                    if i < delB.count, delB[i] { continue }
                    t += 1
                    if o.count < limit { o.append(id) }
                }
                return (o, t)
            }
        }
        _ = superseded   // partial results from a superseded scan are still coherent (subset of order)
        return SearchResults(ids: out, total: total, truncated: total > out.count,
                             queryMillis: secondsBetween(start, clock.now) * 1000)
    }

    // MARK: - [23] general-path narrow-as-you-type: refinement predicate (subset-proof)

    /// Does `new` provably yield a SUBSET of `old`'s general match set? Conservative — any
    /// uncertainty returns `false` (fall back to a full scan; the cache is an optimization,
    /// never a semantic).
    private func isGeneralRefinement(old: ParsedQuery, new: ParsedQuery, mode: MatchMode) -> Bool {
        // caseSensitive changes how BOTH terms and filter values are folded → must match.
        guard old.caseSensitive == new.caseSensitive else { return false }
        // (1) All non-term filters byte-identical (OI-3: no filter-superset narrowing in MVP).
        guard Self.generalFiltersIdentical(old, new) else { return false }
        // (2) OLD's groups each matched POSITIONALLY by an equal-or-narrower NEW group; NEW may
        //     APPEND extra groups — an appended positive group ANDs a new constraint and an
        //     appended negated group excludes more, so ANY appended group only SHRINKS the set.
        guard new.termGroups.count >= old.termGroups.count else { return false }
        // caseSensitive already matched; wholeWord is required byte-equal by generalFiltersIdentical,
        // so old.wholeWord == new.wholeWord — pass old's to the per-group check (MUST-FIX 1).
        for i in old.termGroups.indices {
            if !groupRefines(old: old.termGroups[i], new: new.termGroups[i],
                             mode: mode, wholeWord: old.wholeWord) {
                return false
            }
        }
        return true
    }

    private func groupRefines(old: [QueryTerm], new: [QueryTerm], mode: MatchMode,
                              wholeWord: Bool) -> Bool {
        // Structure must line up alternative-for-alternative.
        guard old.count == new.count else { return false }
        for (o, nw) in zip(old, new) where
            o.negated != nw.negated || o.scope != nw.scope || o.isGlob != nw.isGlob {
            return false
        }
        let negated = old.first?.negated ?? false
        // NEGATED group: narrowing holds only if the exclusion is UNCHANGED. Editing a negated
        // needle (`-foo` → `-foob`) EXCLUDES FEWER names → WIDENS. Byte-identical only.
        if negated { return Self.groupBytesIdentical(old, new) }
        // WHOLE-WORD (ww:) positive group in EXACT mode: prefix extension is NON-MONOTONE
        // (MUST-FIX 1). `Matcher.wholeWordExact` requires the hit not be flanked by a word byte
        // (isWordByte: alnum or ≥0x80). A name `foob` does NOT match `foo ww:` (flanked by `b`) but
        // DOES match `foob ww:` — extending the needle can make a name START matching. So the cached
        // set S is NOT a superset. Restrict to byte-identical. effWW = wholeWord && effMode==.exact,
        // so fuzzy/wildcard ignore ww: and need no extra handling; guard on mode==.exact.
        if wholeWord && mode == .exact { return Self.groupBytesIdentical(old, new) }
        // GLOB / wildcard-mode positive group: whole-name anchoring is non-monotonic
        // (`a?` matches 2-char names, `a?c` matches 3-char — NOT a subset). Byte-identical only.
        if mode == .wildcard || old.contains(where: { $0.isGlob }) {
            return Self.groupBytesIdentical(old, new)
        }
        // MULTI-ALTERNATIVE OR group (`jpg|png`): per-alt subset reasoning is fragile (dropping an
        // alt narrows, adding one widens). Byte-identical only.
        if old.count != 1 { return Self.groupBytesIdentical(old, new) }
        // SINGLE positive plain / fuzzy / path-substring term: NEW is OLD prefix-EXTENDED (or equal).
        //   • exact substring: name ⊇ longer ⇒ name ⊇ prefix ⇒ matches(new) ⊆ matches(old).
        //   • fuzzy subsequence: longer subseq present ⇒ its prefix subseq present ⇒ subset.
        //   • path substring: identical substring monotonicity over the full folded path bytes.
        // (Both alternatives folded identically since caseSensitive matched above.)
        let o = old[0].bytes, nw = new[0].bytes
        return nw.count >= o.count && nw.starts(with: o)
    }

    @inline(__always)
    private static func groupBytesIdentical(_ a: [QueryTerm], _ b: [QueryTerm]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bytes == $1.bytes }
    }

    private static func generalFiltersIdentical(_ a: ParsedQuery, _ b: ParsedQuery) -> Bool {
        // content:/tag: DELIBERATELY excluded — general() ignores them (post-filters applied in
        // search()), so the cached general match set is independent of their value. This is a
        // feature: typing the content needle does not invalidate the name-set cache.
        a.exts == b.exts && a.notExts == b.notExts
            && a.typeMasks == b.typeMasks && a.notTypeMasks == b.notTypeMasks
            && a.sizes.elementsEqual(b.sizes, by: ==) && a.notSizes.elementsEqual(b.notSizes, by: ==)
            && a.dateFrom == b.dateFrom && a.dateTo == b.dateTo
            && a.notDateRanges.elementsEqual(b.notDateRanges, by: ==)
            && a.onlyDirs == b.onlyDirs && a.onlyFiles == b.onlyFiles
            && a.wholeWord == b.wholeWord && a.dupesOnly == b.dupesOnly
            && a.emptyDirsOnly == b.emptyDirsOnly
            && a.lenFilters.elementsEqual(b.lenFilters, by: ==)
            && a.prefixes == b.prefixes && a.suffixes == b.suffixes
            && a.notPrefixes == b.notPrefixes && a.notSuffixes == b.notSuffixes
    }

    // MARK: - general evaluator (modes, filters, multi-term, NOT, path, relevance)

    private func general(parsed: ParsedQuery, mode: MatchMode, scope: SearchScope, sortKey: SortKey,
                         ascending: Bool, limit: Int, start: ContinuousClock.Instant, clock: ContinuousClock,
                         scopeRoot: Int32?, frecency: [Int32: Double] = [:],
                         now: TimeInterval = 0) -> SearchResults {
        let relevance = (sortKey == .relevance)
        // [23] narrow eligibility: never for relevance (OI-1 — pruned per-chunk sets are never the
        // FULL match set). Attr-dependent filters/sorts (MUST-FIX 2, §2) additionally require the
        // cached attrSeq to still match — computed once, used by both consume and store below.
        let attrDependentFilters =
               !parsed.sizes.isEmpty || !parsed.notSizes.isEmpty
            || parsed.dateFrom != nil || parsed.dateTo != nil
            || !parsed.notDateRanges.isEmpty
        let attrDependentSort = (sortKey == .size || sortKey == .dateModified || sortKey == .dateCreated)
        let attrDependent = attrDependentFilters || attrDependentSort
        // Codex B2 TOCTOU: sample the option flags ONCE — the gate compare, the term
        // compilation, and the cache store below must all see the SAME values, or a toggle
        // landing mid-search labels a cache computed under different semantics.
        let wnwOpt = wholeNameWildcards, ufsOpt = useFolderSizes
        // liveBuildGen: type:/empty: filters read typeClass/CSR, whose sentinel→authoritative
        // fill (buildLiveIndexes) moves NO other gen — gate those queries on it (Codex B2).
        let sentinelDependent = !parsed.typeMasks.isEmpty || !parsed.notTypeMasks.isEmpty
                             || parsed.emptyDirsOnly
        var narrowBase: [Int32]? = nil
        if !relevance {
            let epoch = index.epochLocked, structSeq = index.structSeqLocked, attrSeq = index.attrSeqLocked
            let liveGen = index.liveBuildGenLocked
            genNarrowLock.lock()
            if gnValid, gnEpoch == epoch, gnStructSeen == structSeq,
               (!attrDependent || gnAttrSeen == attrSeq),
               (!sentinelDependent || gnLiveBuildSeen == liveGen),           // Codex B2
               gnMode == mode, gnScope == scope, gnScopeRoot == scopeRoot,
               gnSortKey == sortKey, gnAscending == ascending,
               gnWholeNameWildcards == wnwOpt,                                // SHOULD-FIX 3
               (sortKey != .size || gnUseFolderSizes == ufsOpt),             // SHOULD-FIX 3
               isGeneralRefinement(old: gnParsed, new: parsed, mode: mode) {
                narrowBase = gnIDs                       // COW O(1) grab; predicate ran under the lock
            }
            genNarrowLock.unlock()
            narrowBase != nil ? bumpGnHit() : bumpGnFull()
        }
        // Recency boost for relevance (ProFind's trick, via the FAF author): what you search
        // for is disproportionately something you JUST worked with, so recently-modified
        // files get a bounded bump. Precomputed step thresholds (ns) so the per-candidate
        // cost is two integer compares against the mtime we already have in RAM.
        let nowNs = now > 0 ? Int64(min(now, 9.2e9) * 1e9) : 0
        let recentHourNs = nowNs - 3_600_000_000_000           // ≤ 1 hour ago
        let recentDayNs  = nowNs - 86_400_000_000_000          // ≤ 1 day ago
        let recentWeekNs = nowNs - 604_800_000_000_000         // ≤ 1 week ago
        // Frecency boost for relevance: a run-history hit adds a bounded bump to the
        // match score BEFORE the top-K prune (Codex review: boosting after prune is too
        // late). log2 keeps it from swamping match quality; only touches matched ids.
        let boostOn = relevance && !frecency.isEmpty
        // [23] scan source: the narrow base when eligible (already in returned order — no cold
        // orderArray call), else the ordinary cached order array.
        let narrowing = narrowBase != nil
        let order = narrowBase ?? orderArray(for: scanOrderKey(sortKey))
        let n = order.count
        let caseSensitive = parsed.caseSensitive
        // Flatten term bytes into one contiguous buffer + trivial refs so the hot loop
        // uses raw pointers only. Touching each term's [UInt8] array (ARC retain/release)
        // per candidate made multi-term scans ~10x slower than single-term.
        // Refs are laid out group-by-group; `group` marks OR-group membership (all refs
        // of a group share the same negated/isPath, matching the parser's guarantee).
        var termBlob: [UInt8] = []
        var termRefs: [(off: Int, len: Int, group: Int, negated: Bool, isPath: Bool, isGlob: Bool)] = []
        termRefs.reserveCapacity(parsed.termGroups.reduce(0) { $0 + $1.count })
        let star = UInt8(ascii: "*")
        for (gi, g) in parsed.termGroups.enumerated() {
            for t in g {
                var bytes = t.bytes
                let willGlob = (t.isGlob && mode == .exact) || mode == .wildcard
                if !wnwOpt, willGlob, !bytes.isEmpty {   // entry-sampled (TOCTOU)
                    if bytes.first != star { bytes.insert(star, at: 0) }
                    if bytes.last != star { bytes.append(star) }
                }
                termRefs.append((termBlob.count, bytes.count, gi, t.negated, t.scope == .path, t.isGlob))
                termBlob.append(contentsOf: bytes)
            }
        }
        let termCount = termRefs.count

        // --- Character bloom prefilter -------------------------------------------------
        // A name can only match a term if it CONTAINS every (folded) character of the
        // needle, so `(nameMask & needleMask) == needleMask` rejects most non-matches
        // before any byte scan. Gate only POSITIVE, NAME-scope, non-regex groups whose
        // every alternative has ≥1 literal char: negation (absence isn't a bloom test),
        // path terms (may match the parent path, not the name), regex, and pure-wildcard
        // terms are never gated — their match doesn't imply the needle's chars are in the
        // name. AND groups fold into one `requiredMask`; multi-alternative OR groups
        // (`jpg|png`) keep their own alt-mask list. See FileIndex.nameMask.
        var requiredMask: UInt64 = 0
        var orGates: [[UInt64]] = []
        if mode != .regex {
            let starB = UInt8(ascii: "*"), qmB = UInt8(ascii: "?")
            for g in parsed.termGroups {
                guard let first = g.first, !first.negated, first.scope != .path else { continue }
                var altMasks: [UInt64] = []
                var gateable = true
                for t in g {
                    let isGlobTerm = t.isGlob || mode == .wildcard
                    var lm: UInt64 = 0, lit = 0
                    for b in t.bytes {
                        if isGlobTerm && (b == starB || b == qmB) { continue }
                        lm |= (1 << UInt64(FileIndex.charBit(b))); lit += 1
                    }
                    if lit == 0 { gateable = false; break }   // e.g. bare "*" matches anything
                    altMasks.append(lm)
                }
                guard gateable, !altMasks.isEmpty else { continue }
                if altMasks.count == 1 { requiredMask |= altMasks[0] } else { orGates.append(altMasks) }
            }
        }
        let hasOrGates = !orGates.isEmpty
        let useBloomGate = requiredMask != 0 || hasOrGates   // hoisted: pure-filter queries skip it entirely
        // -------------------------------------------------------------------------------

        // Hoist filter presence out of the loop (avoid per-candidate array access + ARC).
        let hasExts = !parsed.exts.isEmpty, hasSizes = !parsed.sizes.isEmpty
        let hasNotExts = !parsed.notExts.isEmpty, hasNotSizes = !parsed.notSizes.isEmpty
        let typeMasks = parsed.typeMasks, notTypeMasks = parsed.notTypeMasks
        let hasTypeMasks = !typeMasks.isEmpty, hasNotTypeMasks = !notTypeMasks.isEmpty
        let hasNotDates = !parsed.notDateRanges.isEmpty
        let df = parsed.dateFrom, dt = parsed.dateTo
        let onlyDirs = parsed.onlyDirs, onlyFiles = parsed.onlyFiles
        let pkgB: [Bool] = (onlyDirs || onlyFiles) ? packageDirBitmap() : []
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
        index.nameMask.withUnsafeBufferPointer { maskB in
        index.typeClass.withUnsafeBufferPointer { tcB in
        index.camelBits.withUnsafeBufferPointer { cbB in
        order.withUnsafeBufferPointer { ordB in
        termBlob.withUnsafeBufferPointer { tblobB in
        termRefs.withUnsafeBufferPointer { trefsB in
            let fbBase = fb.baseAddress!, nbBase = nb.baseAddress!
            let unicodeBase = ufb.baseAddress
            let tblobBase = tblobB.baseAddress   // non-nil whenever termCount > 0
            // startwith:/endwith: primarily match the ASCII-folded blob (cased blob if
            // case:on), mirroring how terms pick hayBase. [32]: affixMatches/excludedByAffix
            // ALSO consult the independent Unicode-fold segment (own offsets/lengths) on an
            // ASCII miss, so non-ASCII names (e.g. café/CAFÉ) match affixes via their diacritic-
            // folded form too — no longer a v1 "stored bytes only" limitation.
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
                    // [26] §4/§9: DP-refine scratch — six Int32 rows sized to the 255-byte hay
                    // cap, allocated ONCE per chunk and reused across every refined candidate
                    // (fuzzy mode only; unused/untouched for exact/wildcard/regex chunks).
                    var dpPrev = [Int32](repeating: 0, count: 255)
                    var dpCurr = [Int32](repeating: 0, count: 255)
                    var dpPrevStart = [Int32](repeating: 0, count: 255)
                    var dpCurrStart = [Int32](repeating: 0, count: 255)
                    var dpPrevRun = [Int32](repeating: 0, count: 255)
                    var dpCurrRun = [Int32](repeating: 0, count: 255)
                    pathScratch.withUnsafeMutableBufferPointer { psb in
                    idxStack.withUnsafeMutableBufferPointer { isb in
                    dpPrev.withUnsafeMutableBufferPointer { dpv in
                    dpCurr.withUnsafeMutableBufferPointer { dcv in
                    dpPrevStart.withUnsafeMutableBufferPointer { dpvs in
                    dpCurrStart.withUnsafeMutableBufferPointer { dcvs in
                    dpPrevRun.withUnsafeMutableBufferPointer { dpvr in
                    dpCurrRun.withUnsafeMutableBufferPointer { dcvr in
                    let dp = DPScratchPtrs(prev: dpv, curr: dcv, prevStart: dpvs, currStart: dcvs,
                                           prevRun: dpvr, currRun: dcvr)
                    for k in lo..<hi {
                        // narrowBase is ALREADY in returned order (ascending baked in when it was
                        // produced), so no flip; the cold order array is ascending and flips for
                        // descending (unchanged behavior).
                        let id = narrowing ? Int(ordB[k]) : Int(ascending ? ordB[k] : ordB[n - 1 - k])
                        if delB[id] { continue }   // defensive: skip tombstones even if order is stale
                        // character bloom prefilter: reject before any byte scan when the
                        // name can't possibly contain the needle's characters (cheapest,
                        // most-selective gate for text queries — esp. fuzzy).
                        if useBloomGate {
                            let nm = maskB[id]
                            if requiredMask & nm != requiredMask { continue }
                            if hasOrGates {
                                var pass = true
                                for alts in orGates {
                                    var any = false
                                    for am in alts where nm & am == am { any = true; break }
                                    if !any { pass = false; break }
                                }
                                if !pass { continue }
                            }
                        }
                        // folder scope: only entries under the chosen directory subtree
                        if let root = scopeRoot, !self.isUnder(id, root: root, parentB: parB) { continue }
                        // type filters (folder: / file:) — Finder semantics: a PACKAGE
                        // directory (.app/.bundle…) counts as a FILE, not a folder.
                        if onlyDirs || onlyFiles {
                            let isPkg = id < pkgB.count && pkgB[id]
                            let dirLike = otB[id] == VNODE_VDIR && !isPkg
                            if onlyDirs && !dirLike { continue }
                            if onlyFiles && dirLike { continue }
                        }
                        // duplicate-name filter (dupe:)
                        if dupesOnly && (id >= dupeB.count || !dupeB[id]) { continue }
                        // empty-folder filter (empty:)
                        if emptyOnly && (id >= emptyB.count || !emptyB[id]) { continue }
                        let o = Int(offB[id]); let l = Int(lenB[id])
                        // include filters (cheap) first
                        if hasLens && !self.lenMatches(l, parsed.lenFilters) { continue }
                        if hasExts && !self.extMatches(fbBase, o, l, parsed.exts) { continue }
                        // type: category — precomputed bitmask, O(1) per candidate (no
                        // per-query extension re-scan). Each include mask must overlap.
                        if hasTypeMasks {
                            let tc = tcB[id]
                            var ok = true
                            for m in typeMasks where tc & m == 0 { ok = false; break }
                            if !ok { continue }
                        }
                        if hasSizes && !self.sizeMatches(szB[id], parsed.sizes) { continue }
                        if let df, mtB[id] < df { continue }
                        if let dt, mtB[id] >= dt { continue }
                        // negated filters: exclude if the candidate matches any of them
                        if hasNotExts && self.extMatches(fbBase, o, l, parsed.notExts) { continue }
                        if hasNotTypeMasks {
                            let tc = tcB[id]
                            var bad = false
                            for m in notTypeMasks where tc & m != 0 { bad = true; break }
                            if bad { continue }
                        }
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
                            // Everything-style auto-wildcard: an unquoted term with * or ?
                            // is matched as an anchored glob even in Exact mode.
                            let effMode: MatchMode = (tr.isGlob && mode == .exact) ? .wildcard : mode
                            let effWW = wholeWord && effMode == .exact
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
                                // path-scope scan: reconstructed path breaks per-entry camelBits
                                // alignment ([28] §2) — pass 0 (separator-only).
                                out = self.matchTerm(hay: psb.baseAddress!, hayLen: pathLen,
                                                     needle: needlePtr, needleLen: tr.len,
                                                     mode: effMode, wholeWord: effWW, camelBits: 0)
                            } else if caseSensitive {
                                // caseSensitive scan is over nbBase (CASED bytes) — camelBits aligns.
                                out = self.matchTerm(hay: nbBase + o, hayLen: l,
                                                     needle: needlePtr, needleLen: tr.len,
                                                     mode: effMode, wholeWord: effWW, camelBits: cbB[id])
                            } else {
                                out = self.matchFoldedName(id: id, asciiBase: fbBase,
                                                           offB: offB, lenB: lenB,
                                                           unicodeBase: unicodeBase,
                                                           unicodeOffB: uOffB, unicodeLenB: uLenB,
                                                           needle: needlePtr, needleLen: tr.len,
                                                           mode: effMode, wholeWord: effWW,
                                                           camelBits: cbB[id])
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
                        if hasAffixes && !self.affixMatches(id, affixBase, o, l,
                                                            unicodeBase: caseSensitive ? nil : unicodeBase,
                                                            uOffB: uOffB, uLenB: uLenB,
                                                            prefixes: parsed.prefixes,
                                                            suffixes: parsed.suffixes) { continue }
                        if hasNotAffixes && self.excludedByAffix(id, affixBase, o, l,
                                                                 unicodeBase: caseSensitive ? nil : unicodeBase,
                                                                 uOffB: uOffB, uLenB: uLenB,
                                                                 notPrefixes: parsed.notPrefixes,
                                                                 notSuffixes: parsed.notSuffixes) { continue }
                        total += 1
                        if relevance {
                            if boostOn, let f = frecency[Int32(id)], f > 0 {
                                // +0..~120: log2(1+frecency) scaled; a daily-opened file
                                // gets a firm bump without drowning a much better name match.
                                score += Int(30.0 * log2(1.0 + f))
                            }
                            // Recency bump — stepped so it reorders TIES and near-ties
                            // (equal-quality name matches) without letting a random file
                            // touched today beat a clearly better name match.
                            if nowNs > 0 {
                                let mt = mtB[id]
                                if mt >= recentHourNs { score += 60 }
                                else if mt >= recentDayNs { score += 40 }
                                else if mt >= recentWeekNs { score += 20 }
                            }
                            // [36] shallow-first, demoted to a strict exact-score tie-break (S2: an
                            // additive depth penalty crosses G1 once it stacks with recency — see
                            // spec §1/§7). Walked on matched candidates only, ≤16 parent hops.
                            var depth = 0; var pcur = parB[id]
                            while pcur >= 0 && depth < 16 { depth += 1; pcur = parB[Int(pcur)] }
                            // Codex P2: cap BEFORE ×64 so pathological many-term totals can't
                            // saturate Int32 and collapse distinct scores into a tie.
                            let cappedScore = min(score, Int(Int32.max) / 64 - 16)
                            let scaledScore = cappedScore * 64 - min(depth, 16)   // DEPTH_SCALE=64 > DEPTH_CAP=16
                            pairs.append((id: Int32(id), score: Int32(scaledScore)))
                            // Codex P1: the collection prune must KEEP the full pruneThreshold
                            // survivor window (DP re-ranks it below — cutting to `limit` here made
                            // the top result depend on limit). 2× trigger = amortized sorting.
                            if pairs.count > pruneThreshold &* 2 {
                                pairs.sort { a, b in
                                    if a.score != b.score {
                                        return ascending ? a.score < b.score : a.score > b.score
                                    }
                                    return self.nameLess(a.id, b.id, fbBase, offB, lenB)   // agy#1: was a.id < b.id
                                }
                                pairs.removeSubrange(pruneThreshold..<pairs.count)
                            }
                        } else if ids.count < limit {
                            ids.append(Int32(id))
                        }
                    }
                    // [26] §4 S1: refine-after-prune (the DEFAULT, not conditional) — DP-refine
                    // ONLY the retained per-chunk survivors (≤ pruneThreshold), re-summing each
                    // candidate's term score with the DP scorer instead of greedy, then reapplying
                    // frecency/recency/depth exactly as the main pass did. Greedy already gated
                    // existence above (the match SET never changes); this only reorders ties within
                    // it. A broad 2/3-char fuzzy surviving on a huge fraction of 2M would make
                    // inline-per-candidate DP billions of ops — refining only the survivors keeps
                    // this bounded to ≤ pruneThreshold × termCount DP calls per chunk.
                    if relevance, mode == .fuzzy, termCount > 0 {
                        for pi in pairs.indices {
                            let id = Int(pairs[pi].id)
                            let o = Int(offB[id]); let l = Int(lenB[id])
                            var newScore = 0
                            var pathLen = -1
                            var ti = 0
                            while ti < termCount {
                                let tr = trefsB[ti]
                                if tr.negated { ti += 1; continue }   // never contributes score
                                let needlePtr = tblobBase! + tr.off
                                let out: MatchOutcome
                                if tr.isPath {
                                    if pathLen < 0 {
                                        pathLen = caseSensitive
                                            ? self.foldedPathBytes(id, blob: nbBase, offB: offB, lenB: lenB,
                                                                   parB: parB, stack: isb, out: psb)
                                            : self.searchFoldedPathBytes(id, asciiBlob: fbBase, offB: offB,
                                                                         lenB: lenB, unicodeBlob: unicodeBase,
                                                                         unicodeOffB: uOffB, unicodeLenB: uLenB,
                                                                         parB: parB, stack: isb, out: psb)
                                    }
                                    // path-scope: reconstructed path breaks per-entry camelBits
                                    // alignment ([28] §2) — 0 (separator-only), same as the main pass.
                                    let greedy = Matcher.fuzzy(psb.baseAddress!, pathLen, needlePtr, tr.len, 0)
                                    out = greedy.matched
                                        ? Matcher.fuzzyDPRefine(hay: psb.baseAddress!, hayLen: pathLen,
                                                                needle: needlePtr, needleLen: tr.len, camelBits: 0,
                                                                prev: dp.prev, curr: dp.curr,
                                                                prevStart: dp.prevStart, currStart: dp.currStart,
                                                                prevRun: dp.prevRun, currRun: dp.currRun,
                                                                greedy: greedy)
                                        : .no
                                } else if caseSensitive {
                                    let greedy = Matcher.fuzzy(nbBase + o, l, needlePtr, tr.len, cbB[id])
                                    out = greedy.matched
                                        ? Matcher.fuzzyDPRefine(hay: nbBase + o, hayLen: l,
                                                                needle: needlePtr, needleLen: tr.len,
                                                                camelBits: cbB[id],
                                                                prev: dp.prev, curr: dp.curr,
                                                                prevStart: dp.prevStart, currStart: dp.currStart,
                                                                prevRun: dp.prevRun, currRun: dp.currRun,
                                                                greedy: greedy)
                                        : .no
                                } else {
                                    out = self.matchFoldedNameDP(id: id, asciiBase: fbBase, offB: offB, lenB: lenB,
                                                                 unicodeBase: unicodeBase, unicodeOffB: uOffB,
                                                                 unicodeLenB: uLenB, needle: needlePtr,
                                                                 needleLen: tr.len, camelBits: cbB[id], dp: dp)
                                }
                                if out.matched {
                                    newScore += out.score
                                    ti += 1
                                    while ti < termCount && trefsB[ti].group == tr.group { ti += 1 }
                                } else {
                                    ti += 1
                                }
                            }
                            if boostOn, let f = frecency[Int32(id)], f > 0 {
                                newScore += Int(30.0 * log2(1.0 + f))
                            }
                            if nowNs > 0 {
                                let mt = mtB[id]
                                if mt >= recentHourNs { newScore += 60 }
                                else if mt >= recentDayNs { newScore += 40 }
                                else if mt >= recentWeekNs { newScore += 20 }
                            }
                            var depth = 0; var pcur = parB[id]
                            while pcur >= 0 && depth < 16 { depth += 1; pcur = parB[Int(pcur)] }
                            let capped = min(newScore, Int(Int32.max) / 64 - 16)   // Codex P2
                            pairs[pi].score = Int32(capped * 64 - min(depth, 16))
                        }
                    }
                    if relevance && pairs.count > limit {
                        pairs.sort { a, b in
                            if a.score != b.score {
                                    return ascending ? a.score < b.score : a.score > b.score
                            }
                            return self.nameLess(a.id, b.id, fbBase, offB, lenB)   // agy#1: was a.id < b.id
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
                    }}}}}}}}
                }
            }}}
        }}}}}}}}}}}}}}}}}}

        let total = chunkTotals.reduce(0, +)
        var out: [Int32]
        if relevance {
            var pairs: [(Int32, Int32)] = []
            pairs.reserveCapacity(min(total, nChunks * limit))
            for c in 0..<nChunks {
                let ids = chunkIDs[c], scs = chunkScores[c]
                for j in 0..<ids.count { pairs.append((ids[j], scs[j])) }
            }
            // relevance is conventionally high→low, but honor the ascending flag; tie-break by
            // folded name (agy#1: was a.0 < b.0 — id/crawl order, not user-visible order).
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                pairs.sort { a, b in
                    a.1 != b.1 ? (ascending ? a.1 < b.1 : a.1 > b.1)
                               : self.nameLess(a.0, b.0, base, offB, lenB)
                }
            }}}
            out = pairs.prefix(limit).map { $0.0 }
        } else {
            out = []; out.reserveCapacity(min(total, limit))
            outer: for c in 0..<nChunks { for id in chunkIDs[c] { if out.count >= limit { break outer }; out.append(id) } }
        }
        // [23] store: only a NON-relevance, UNTRUNCATED (`out` IS the full set) result seeds the
        // next keystroke's narrow. Read the gens again here (still under the same inherited read
        // lock general() ran under — Codex/skeleton note: the whole call is one lock acquisition,
        // so this is the SAME snapshot the consume gate above compared against).
        if !relevance {
            genNarrowLock.lock()
            if total == out.count, total <= Self.incMaxCacheIDs {
                gnValid = true
                gnIDs = out                       // returned order
                gnParsed = parsed; gnMode = mode; gnScope = scope; gnScopeRoot = scopeRoot
                gnSortKey = sortKey; gnAscending = ascending
                gnWholeNameWildcards = wnwOpt; gnUseFolderSizes = ufsOpt   // entry-sampled (TOCTOU)
                gnEpoch = index.epochLocked; gnStructSeen = index.structSeqLocked
                gnAttrSeen = index.attrSeqLocked; gnAttrDependent = attrDependent
                gnLiveBuildSeen = index.liveBuildGenLocked
            } else {
                gnValid = false                    // truncated or over-bound → do not seed a partial set
            }
            genNarrowLock.unlock()
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

    @inline(__always)
    private func prefixHit(_ base: UnsafePointer<UInt8>, _ o: Int, _ l: Int, _ p: [UInt8]) -> Bool {
        p.withUnsafeBufferPointer { $0.isEmpty || ($0.count <= l && memcmp(base + o, $0.baseAddress!, $0.count) == 0) }
    }
    @inline(__always)
    private func suffixHit(_ base: UnsafePointer<UInt8>, _ o: Int, _ l: Int, _ s: [UInt8]) -> Bool {
        s.withUnsafeBufferPointer { $0.isEmpty || ($0.count <= l && memcmp(base + o + l - $0.count, $0.baseAddress!, $0.count) == 0) }
    }

    /// `startwith:`/`endwith:` — the name bytes must begin/end with EVERY affix. [32]: consults
    /// BOTH fold segments (ASCII-fold, and on miss the Unicode fold) mirroring `matchFoldedName`
    /// (OI-A) — so `startwith:café` matches CAFÉ.txt (ASCII fold "cafe" won't have the diacritic,
    /// but the Unicode-fold segment does). case:on stays ASCII/cased-only (unicodeBase nil there).
    @inline(__always)
    private func affixMatches(_ id: Int, _ affixBase: UnsafePointer<UInt8>, _ o: Int, _ l: Int,
                              unicodeBase: UnsafePointer<UInt8>?,
                              uOffB: UnsafeBufferPointer<UInt64>, uLenB: UnsafeBufferPointer<UInt32>,
                              prefixes: [[UInt8]], suffixes: [[UInt8]]) -> Bool {
        let hasU = unicodeBase != nil && uOffB[id] != noUnicodeFoldOffset
        let uo = hasU ? Int(uOffB[id]) : 0, ul = hasU ? Int(uLenB[id]) : 0
        for p in prefixes {
            if p.isEmpty { continue }                                    // isEmpty ⇒ no constraint
            var ok = prefixHit(affixBase, o, l, p)                       // ASCII/cased segment
            if !ok && hasU { ok = prefixHit(unicodeBase!, uo, ul, p) }   // Unicode segment (on miss)
            if !ok { return false }
        }
        for s in suffixes {   // suffix uses the SEGMENT's own length (l for ASCII, ul for Unicode)
            if s.isEmpty { continue }
            var ok = suffixHit(affixBase, o, l, s)
            if !ok && hasU { ok = suffixHit(unicodeBase!, uo, ul, s) }
            if !ok { return false }
        }
        return true
    }

    /// Negated affixes: exclude if EITHER fold segment begins/ends with ANY not-affix (red-team 4).
    @inline(__always)
    private func excludedByAffix(_ id: Int, _ affixBase: UnsafePointer<UInt8>, _ o: Int, _ l: Int,
                                 unicodeBase: UnsafePointer<UInt8>?,
                                 uOffB: UnsafeBufferPointer<UInt64>, uLenB: UnsafeBufferPointer<UInt32>,
                                 notPrefixes: [[UInt8]], notSuffixes: [[UInt8]]) -> Bool {
        let hasU = unicodeBase != nil && uOffB[id] != noUnicodeFoldOffset
        let uo = hasU ? Int(uOffB[id]) : 0, ul = hasU ? Int(uLenB[id]) : 0
        for p in notPrefixes where !p.isEmpty {
            if p.count <= l && prefixHit(affixBase, o, l, p) { return true }
            if hasU && p.count <= ul && prefixHit(unicodeBase!, uo, ul, p) { return true }
        }
        for s in notSuffixes where !s.isEmpty {
            if s.count <= l && suffixHit(affixBase, o, l, s) { return true }
            if hasU && s.count <= ul && suffixHit(unicodeBase!, uo, ul, s) { return true }
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

    // Lock discipline: the index rdlock is ALREADY held by every caller (via withReadLock/the
    // search scan). `cacheLock` guards `orderCache` only and is NEVER held across
    // computeOrder/applyIncremental (both scan index arrays and can be slow) — mirrors the
    // pre-[13] lock/unlock/compute/relock dance. The freshness check AND the name-family
    // `appliedSeq` refresh happen in a SINGLE `cacheLock` section (no second acquisition on the
    // hot attr-storm no-op path — that path is exactly what this feature exists to make O(1)).
    // Stats bumps (which take `statsLock`) happen only AFTER `cacheLock` is released: `cacheLock`
    // and `statsLock` are never held together.
    private func orderArray(for key: SortKey) -> [Int32] {
        let fs  = (key == .size && useFolderSizes)
        let ck  = OrderKey(sort: key, folderSizes: fs)
        let fam = family(key, folderSizes: fs)
        let epoch     = index.epochLocked
        let structSeq = index.structSeqLocked
        let totalSeq  = index.totalSeqLocked
        let mutGen    = index.mutationGenLocked

        cacheLock.lock()
        let base: OrderState? = orderCache[ck]
        if var s = base {
            switch fam {
            case .name:
                if s.epoch == epoch && s.structSeen == structSeq {
                    if s.appliedSeq != totalSeq { s.appliedSeq = totalSeq; orderCache[ck] = s }   // CF-2: in-lock
                    let ids = s.ids; cacheLock.unlock(); bumpNoop(); return ids
                }
            case .attr:
                if s.epoch == epoch && s.appliedSeq == totalSeq {
                    let ids = s.ids; cacheLock.unlock(); bumpNoop(); return ids
                }
            case .fsSize:
                if s.mutGen == mutGen {
                    let ids = s.ids; cacheLock.unlock(); bumpNoop(); return ids
                }
            }
        }
        cacheLock.unlock()

        // Try incremental (name/attr only, and only if we have a same-epoch base to grow from).
        var result: [Int32]? = nil
        if fam != .fsSize, let s = base, s.epoch == epoch,
           let recs = index.changeRecordsLocked(from: s.appliedSeq) {
            result = applyIncremental(key: key, fam: fam, base: s.ids, ids: recs.ids, kinds: recs.kinds)
        }
        let order: [Int32]
        if let r = result { order = r; bumpIncremental() }
        else              { order = computeOrder(key); bumpFullRebuild() }

        let newState = OrderState(epoch: epoch, mutGen: mutGen, appliedSeq: totalSeq,
                                  structSeen: structSeq, ids: order)
        cacheLock.lock(); orderCache[ck] = newState; cacheLock.unlock()
        return order
    }

    /// Applies a suffix of the index's change log to `base` to produce the current order without
    /// a full re-argsort. Runs under the index rdlock (inherited). Returns nil to signal "fall
    /// back to full rebuild" (caller does `computeOrder`).
    private func applyIncremental(key: SortKey, fam: OrderFamily, base: [Int32],
                                  ids: [Int32], kinds: [UInt8]) -> [Int32]? {
        let n = index.count
        // 1. Coalesce (sets ⇒ idempotent; ids never resurrect ⇒ order within the window is
        //    irrelevant). append-then-tombstone / attr-then-tombstone both net to "absent"; a
        //    multi-attr id's final in-place value is read once at sort time (idempotent).
        var tomb = Set<Int32>(); var appended = Set<Int32>(); var attrTouched = Set<Int32>()
        for k in 0..<ids.count {
            switch kinds[k] {
            case 0: appended.insert(ids[k])
            case 1: tomb.insert(ids[k])
            default: attrTouched.insert(ids[k])          // kind 2
            }
        }
        // name family ignores attr records entirely.
        let inserts = appended.subtracting(tomb)
        let moved: Set<Int32> = (fam == .attr) ? attrTouched.subtracting(tomb).subtracting(appended)
                                               : []
        // 2. Size guard: distinct affected ids. Cheap upper bound.
        let k = inserts.count + moved.count + tomb.count
        if k > max(8192, n / 16) { return nil }          // too big ⇒ full rebuild cheaper/simpler
        // membership bitset over old ids for O(1) drop test (drop = tomb ∪ moved).
        var drop = [Bool](repeating: false, count: n)     // sized n; every affected id < n
        for id in tomb  where Int(id) < n { drop[Int(id)] = true }
        for id in moved where Int(id) < n { drop[Int(id)] = true }
        // 3. Pass 1 — filter old order (REQUIRED before any comparison: removes every stale-valued
        //    id so a probe never compares a moved id's NEW value against its OLD neighbourhood).
        var filtered = [Int32](); filtered.reserveCapacity(base.count)
        for id in base { let i = Int(id); if i < n && !drop[i] { filtered.append(id) } }
        // 4. Sort the k new/moved ids with the SHARED comparator (§5). For attr `moved` ids the
        //    comparator reads index.size/mtime/crtime which already hold the NEW value
        //    (applyDirDiff wrote it in-place BEFORE logging), so they sort into their new position.
        var news = Array(inserts); news.append(contentsOf: moved)
        if news.isEmpty { return filtered }   // pure deletion batch: nothing to merge in
        if key == .path { return mergePathIncremental(filtered: filtered, news: news) }
        sortIds(&news, key: key)                          // shared comparator
        // 5. Two-pointer merge (both `news` and `filtered` are sorted by the SAME total order):
        var out = [Int32](); out.reserveCapacity(filtered.count + news.count)
        var a = 0, b = 0
        while a < filtered.count && b < news.count {
            if lessId(news[b], filtered[a], key: key) { out.append(news[b]); b += 1 }
            else                                       { out.append(filtered[a]); a += 1 }
        }
        while a < filtered.count { out.append(filtered[a]); a += 1 }
        while b < news.count     { out.append(news[b]);     b += 1 }
        return out
    }

    /// `.path`-family incremental merge: `news`' folded paths are materialized ONCE into a
    /// small packed side-blob (k entries, tiny) and sorted with the shared `pathBytesLess`;
    /// `filtered` is already in path order from the cached base, so each `filtered[a]` probe
    /// reconstructs its path on demand into REUSED scratch (no full O(n) path blob, unlike
    /// `computePathOrder`). Uses the exact `foldedPathBytes` signature/args computePathOrder
    /// uses, so the two can never drift.
    private func mergePathIncremental(filtered: [Int32], news: [Int32]) -> [Int32] {
        index.foldBlob.withUnsafeBufferPointer { fb in
        index.nameOff.withUnsafeBufferPointer { offB in
        index.nameLen.withUnsafeBufferPointer { lenB in
        index.parent.withUnsafeBufferPointer { parB -> [Int32] in
            let base = fb.baseAddress!
            var newsBlob = [UInt8](); newsBlob.reserveCapacity(news.count * 24)
            var newsOff = [Int](); newsOff.reserveCapacity(news.count)
            var newsLen = [Int32](); newsLen.reserveCapacity(news.count)
            var scratch = [UInt8](repeating: 0, count: 8192)
            var stack   = [Int32](repeating: 0, count: 4096)
            scratch.withUnsafeMutableBufferPointer { sb in
            stack.withUnsafeMutableBufferPointer { stk in
                for id in news {
                    let w = foldedPathBytes(Int(id), blob: base, offB: offB, lenB: lenB,
                                            parB: parB, stack: stk, out: sb)
                    newsOff.append(newsBlob.count); newsLen.append(Int32(w))
                    newsBlob.append(contentsOf: UnsafeBufferPointer(start: sb.baseAddress!, count: w))
                }
            }}
            return newsBlob.withUnsafeBufferPointer { nb -> [Int32] in
                let nbase = nb.baseAddress!
                var order = Array(0..<news.count)
                order.sort { i, j in
                    pathBytesLess(nbase + newsOff[i], Int(newsLen[i]), news[i],
                                 nbase + newsOff[j], Int(newsLen[j]), news[j])
                }
                let sNews = order.map { news[$0] }
                let sOff  = order.map { newsOff[$0] }
                let sLen  = order.map { newsLen[$0] }

                var out = [Int32](); out.reserveCapacity(filtered.count + news.count)
                var a = 0, b = 0
                var probeScratch = [UInt8](repeating: 0, count: 8192)
                var probeStack   = [Int32](repeating: 0, count: 4096)
                probeScratch.withUnsafeMutableBufferPointer { psb in
                probeStack.withUnsafeMutableBufferPointer { pstk in
                    while a < filtered.count && b < sNews.count {
                        let fid = filtered[a]
                        let fw = foldedPathBytes(Int(fid), blob: base, offB: offB, lenB: lenB,
                                                 parB: parB, stack: pstk, out: psb)
                        if pathBytesLess(nbase + sOff[b], Int(sLen[b]), sNews[b],
                                        psb.baseAddress!, fw, fid) {
                            out.append(sNews[b]); b += 1
                        } else {
                            out.append(fid); a += 1
                        }
                    }
                }}
                while a < filtered.count { out.append(filtered[a]); a += 1 }
                while b < sNews.count    { out.append(sNews[b]);    b += 1 }
                return out
            }
        }}}}
    }

    // MARK: - shared comparator core (§5) — full computeOrder/computePathOrder AND the
    // incremental applyIncremental route every tie-break through these SAME free functions,
    // so the two paths cannot drift apart.

    /// First 8 folded name bytes packed into a UInt64 for a cheap integer-compare fast path.
    @inline(__always) func nameKey64(_ i: Int, _ base: UnsafePointer<UInt8>,
            _ offB: UnsafeBufferPointer<UInt64>, _ lenB: UnsafeBufferPointer<UInt16>) -> UInt64 {
        let o = Int(offB[i]); let l = min(Int(lenB[i]), 8); var k: UInt64 = 0; var j = 0
        while j < l { k |= UInt64(base[o + j]) << (56 - 8 * j); j += 1 }; return k
    }
    @inline(__always) func nameLessTie(_ ia: Int, _ ib: Int, _ base: UnsafePointer<UInt8>,
            _ offB: UnsafeBufferPointer<UInt64>, _ lenB: UnsafeBufferPointer<UInt16>) -> Bool {
        let oa = Int(offB[ia]), la = Int(lenB[ia]), ob = Int(offB[ib]), lb = Int(lenB[ib])
        let m = min(la, lb); let r = m > 0 ? memcmp(base + oa, base + ob, m) : 0
        if r != 0 { return r < 0 }; if la != lb { return la < lb }; return ia < ib   // id tie-break
    }
    @inline(__always) func nameLess(_ a: Int32, _ b: Int32, _ base: UnsafePointer<UInt8>,
            _ offB: UnsafeBufferPointer<UInt64>, _ lenB: UnsafeBufferPointer<UInt16>) -> Bool {
        let ka = nameKey64(Int(a), base, offB, lenB), kb = nameKey64(Int(b), base, offB, lenB)
        return ka != kb ? ka < kb : nameLessTie(Int(a), Int(b), base, offB, lenB)
    }

    /// Raw folded-path-byte compare (first 8 bytes are packed by callers for the fast path;
    /// this is the full memcmp tie-break both the full path sort and the incremental merge use).
    @inline(__always) func pathBytesLess(_ aPtr: UnsafePointer<UInt8>, _ aLen: Int, _ aId: Int32,
                                         _ bPtr: UnsafePointer<UInt8>, _ bLen: Int, _ bId: Int32) -> Bool {
        let m = min(aLen, bLen); let r = m > 0 ? memcmp(aPtr, bPtr, m) : 0
        if r != 0 { return r < 0 }; if aLen != bLen { return aLen < bLen }; return aId < bId
    }

    // Attr-family comparators (size fs=false / dateModified / dateCreated), shared by
    // computeOrder and the incremental sortIds/lessId dispatch.
    @inline(__always) private func sizeLess(_ a: Int32, _ b: Int32) -> Bool {
        let s = index.size
        return s[Int(a)] != s[Int(b)] ? s[Int(a)] < s[Int(b)] : a < b
    }
    @inline(__always) private func mtimeLess(_ a: Int32, _ b: Int32) -> Bool {
        let mt = index.mtime
        return mt[Int(a)] != mt[Int(b)] ? mt[Int(a)] < mt[Int(b)] : a < b
    }
    @inline(__always) private func crtimeLess(_ a: Int32, _ b: Int32) -> Bool {
        let ct = index.crtime
        return ct[Int(a)] != ct[Int(b)] ? ct[Int(a)] < ct[Int(b)] : a < b
    }

    /// Incremental-only comparison entry point for the name/size/date families (`.path` is
    /// handled specially inside `applyIncremental` — it needs reused path-reconstruction
    /// scratch threaded through the merge loop, not a per-call buffer open). Never called
    /// with `.path`/`.relevance`/`.runCount` (scanOrderKey maps the latter two to `.name`
    /// before `orderArray` is reached — OI-5).
    private func lessId(_ a: Int32, _ b: Int32, key: SortKey) -> Bool {
        switch key {
        case .size: return sizeLess(a, b)
        case .dateModified: return mtimeLess(a, b)
        case .dateCreated: return crtimeLess(a, b)
        default:   // .name (and the unreachable .relevance/.runCount/.path)
            return index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                nameLess(a, b, fb.baseAddress!, offB, lenB)
            }}}
        }
    }
    private func sortIds(_ arr: inout [Int32], key: SortKey) {
        switch key {
        case .size: arr.sort { sizeLess($0, $1) }
        case .dateModified: arr.sort { mtimeLess($0, $1) }
        case .dateCreated: arr.sort { crtimeLess($0, $1) }
        default:
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                arr.sort { nameLess($0, $1, fb.baseAddress!, offB, lenB) }
            }}}
        }
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
                ids.sort { sizeLess($0, $1) }
            }
        case .dateModified:
            ids.sort { mtimeLess($0, $1) }
        case .dateCreated:
            ids.sort { crtimeLess($0, $1) }
        case .path:
            break   // handled above by computePathOrder (unreachable; kept exhaustive)
        case .name, .relevance, .runCount:   // relevance/runCount use name order as the scan base
            index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                if useNameRadix {
                    radixNameOrder(&ids, base, offB, lenB)
                } else {
                    // Pack the first 8 folded bytes into a UInt64 so most comparisons are a single
                    // integer compare; nameLessTie's memcmp only runs on an 8-byte key tie. Shared
                    // with the incremental path (§5) so the two orders cannot drift.
                    var pairs = ids.map { (nameKey64(Int($0), base, offB, lenB), $0) }
                    pairs.sort { a, b in
                        a.0 != b.0 ? a.0 < b.0 : nameLessTie(Int(a.1), Int(b.1), base, offB, lenB)
                    }
                    for k in 0..<pairs.count { ids[k] = pairs[k].1 }
                }
            }}}
        }
        return ids
    }

    /// Gate (OI-8): measured on the 1M synthetic bench (mvsim inc13 bench fixture) — radix ~2.2-2.4×
    /// faster than the comparator sort (clean, single-run timings; e.g. radix=0.041s comparator=0.097s).
    /// KEPT (>2× gate). The comparator path (pairs.sort below) survives unconditionally for the oracle
    /// and as a one-flag revert if a future regression drops radix below the gate.
    private let useNameRadix = true

    /// Produces the EXACT same total order as `pairs.sort { (key64, nameLessTie) }` — key64 asc, then folded-name
    /// memcmp beyond 8 bytes, then length, then id. Runs under the inherited index rdlock.
    private func radixNameOrder(_ ids: inout [Int32], _ base: UnsafePointer<UInt8>,
            _ offB: UnsafeBufferPointer<UInt64>, _ lenB: UnsafeBufferPointer<UInt16>) {
        let n = ids.count; if n < 2 { return }
        var srcK = [UInt64](repeating: 0, count: n)
        for k in 0..<n { srcK[k] = nameKey64(Int(ids[k]), base, offB, lenB) }
        var src = ids
        var dst = [Int32](repeating: 0, count: n)
        var dstK = [UInt64](repeating: 0, count: n)
        var count = [Int](repeating: 0, count: 65537)
        for pass in 0..<4 {
            let shift = UInt64(pass * 16)
            for k in 0...65536 { count[k] = 0 }
            for k in 0..<n { count[Int((srcK[k] >> shift) & 0xFFFF) + 1] &+= 1 }
            for k in 1...65536 { count[k] &+= count[k - 1] }
            for k in 0..<n {
                let b = Int((srcK[k] >> shift) & 0xFFFF)
                let pos = count[b]; count[b] &+= 1
                dst[pos] = src[k]; dstK[pos] = srcK[k]
            }
            swap(&src, &dst); swap(&srcK, &dstK)
        }
        // src is now sorted by key64 asc (stable, even pass count). Sort each equal-key64 run by the full tie-break.
        var i = 0
        while i < n {
            var j = i + 1
            while j < n && srcK[j] == srcK[i] { j += 1 }
            if j - i > 1 {
                src[i..<j].sort { nameLessTie(Int($0), Int($1), base, offB, lenB) }
            }
            i = j
        }
        ids = src
    }

    /// TEST-ONLY: computes the name-family order both ways (radix, comparator) over all live ids.
    public func _debugNameOrders() -> (radix: [Int32], comparator: [Int32]) {
        index.withReadLock {
            let n = index.count
            let del = index.deleted
            var ids = [Int32](); ids.reserveCapacity(n)
            for i in 0..<n where !del[i] { ids.append(Int32(i)) }
            return index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                var radixIds = ids
                radixNameOrder(&radixIds, base, offB, lenB)
                var pairs = ids.map { (nameKey64(Int($0), base, offB, lenB), $0) }
                pairs.sort { a, b in
                    a.0 != b.0 ? a.0 < b.0 : nameLessTie(Int(a.1), Int(b.1), base, offB, lenB)
                }
                let cmpIds = pairs.map { $0.1 }
                return (radixIds, cmpIds)
            }}}
        }
    }

    /// TEST-ONLY (bench): same computation as `_debugNameOrders()` but times the radix pass and
    /// the comparator pass separately (each over an identical `ids` snapshot) so mvsim can print
    /// the ratio the [OI-8] `< 2×` keep/revert gate is read off. Print-only — never asserted on.
    public func _debugBenchNameOrders() -> (radixSeconds: Double, comparatorSeconds: Double, n: Int) {
        index.withReadLock {
            let n = index.count
            let del = index.deleted
            var ids = [Int32](); ids.reserveCapacity(n)
            for i in 0..<n where !del[i] { ids.append(Int32(i)) }
            return index.foldBlob.withUnsafeBufferPointer { fb in
            index.nameOff.withUnsafeBufferPointer { offB in
            index.nameLen.withUnsafeBufferPointer { lenB in
                let base = fb.baseAddress!
                let clock = ContinuousClock()
                var radixIds = ids
                let r0 = clock.now
                radixNameOrder(&radixIds, base, offB, lenB)
                let r1 = clock.now
                let c0 = clock.now
                var pairs = ids.map { (nameKey64(Int($0), base, offB, lenB), $0) }
                pairs.sort { a, b in
                    a.0 != b.0 ? a.0 < b.0 : nameLessTie(Int(a.1), Int(b.1), base, offB, lenB)
                }
                let c1 = clock.now
                let rd = r0.duration(to: r1), cd = c0.duration(to: c1)
                let rSec = Double(rd.components.seconds) + Double(rd.components.attoseconds) * 1e-18
                let cSec = Double(cd.components.seconds) + Double(cd.components.attoseconds) * 1e-18
                return (rSec, cSec, ids.count)
            }}}
        }
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
                // Tie-break through the SAME pathBytesLess (§5) the incremental merge uses, so
                // the two orders cannot drift.
                pairs.sort { a, b in
                    if a.0 != b.0 { return a.0 < b.0 }
                    let pa = Int(a.1), pbp = Int(b.1)
                    return pathBytesLess(pbase + offs[pa], Int(lens[pa]), ids[pa],
                                         pbase + offs[pbp], Int(lens[pbp]), ids[pbp])
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
