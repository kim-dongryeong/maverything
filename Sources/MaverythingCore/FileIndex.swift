import Foundation

/// The in-memory file index, modeled after Everything's flat RAM structure.
///
/// Stored as a *struct of arrays* for cache locality. Names are packed into one
/// contiguous UTF-8 blob (plus an ASCII-lowercased shadow blob for fast
/// case-insensitive matching). Full paths are NEVER stored; they are
/// reconstructed on demand by walking the `parent` chain — this dedups
/// directory strings and keeps the footprint tiny (~100 MB / 1M files).
///
/// Root entries (the crawl roots, e.g. "/" or "/Users/me") have `parent == -1`
/// and store their *absolute path* as their name.
public final class FileIndex: @unchecked Sendable {
    // Packed name storage. `nameOff[i] ..< nameOff[i]+nameLen[i]` indexes the
    // original and ASCII-folded blobs. Non-ASCII names additionally get a
    // case/diacritic-insensitive search fold with independent offsets because
    // Unicode folding can change the UTF-8 byte length (e.g. CAFÉ -> cafe).
    public internal(set) var nameBlob: [UInt8] = []   // original UTF-8 bytes
    public internal(set) var foldBlob: [UInt8] = []   // ASCII-lowercased shadow (same offsets)
    public internal(set) var unicodeFoldBlob: [UInt8] = []
    public internal(set) var nameOff: [UInt64] = []
    public internal(set) var nameLen: [UInt16] = []
    public internal(set) var unicodeFoldOff: [UInt64] = []
    public internal(set) var unicodeFoldLen: [UInt32] = []

    // Character bloom mask (one UInt64 per entry): a case-folded set of which
    // characters appear anywhere in the name. A search term can only match a name
    // if every character of the (folded) needle is present, so `(nameMask & needleMask)
    // == needleMask` is a cheap NECESSARY-condition prefilter — it rejects most
    // non-matches before the byte scan (biggest win for fuzzy + cold first queries).
    // Never persisted (recomputed in buildLiveIndexes after crawl/snapshot-load, so the
    // snapshot format is untouched). `.max` (all bits) = "unknown, scan me" — the safe
    // default for freshly-appended entries before the authoritative rebuild, so a
    // half-built mask can only cost a scan, never drop a real match.
    public internal(set) var nameMask: [UInt64] = []

    // Media "kind" bitmask per entry (one byte): which of documents/images/audio/video/
    // archives/apps the entry's extension belongs to (see FileTypeClass). Powers the
    // `type:` operator and the app's type chips with a single AND'd bit test in the hot
    // loop instead of a per-candidate extension re-scan. Kept EXACT at every append (it's
    // a filter, not a prefilter — a wrong bit would drop or add a real match), authoritative
    // values (re)computed in buildLiveIndexes. Never persisted (snapshot format untouched);
    // snapshot-load seeds 0xFF ("unknown → matches any type:", like nameMask's .max) until
    // the caller's buildLiveIndexes fills it.
    public internal(set) var typeClass: [UInt8] = []

    // [28] camelCase boundary bits — one UInt64 per entry, bit i set iff byte i of the
    // entry's CASED name bytes is a camelCase word start (isLowerOrDigit(name[i-1]) &&
    // isUpper(name[i])); covers bytes 0..63 (bit 0 never set — pos 0 is the PREFIX case,
    // handled separately). Names >64 bytes: camel starts past byte 63 fall back to
    // separator-only (documented cutoff). Mirrors typeClass's lifecycle exactly (see
    // every append site below). Never persisted (recomputed like nameMask/typeClass);
    // 0 = "no camel starts known yet" is a safe passthrough (separator-only boundary
    // rule still applies) until buildLiveIndexes fills the authoritative values.
    public internal(set) var camelBits: [UInt64] = []

    /// Cased-byte camelCase word-start bitmap for `p[o..<o+len]` (bit i set ⇔ i is a
    /// camel start). MUST be computed from CASED bytes (nameBlob/batch.blob/name), never
    /// foldBlob (folding erases the case transition camelCase detection depends on).
    @inline(__always) static func camelBitsOf(_ p: UnsafePointer<UInt8>, _ o: Int, _ len: Int) -> UInt64 {
        var bits: UInt64 = 0
        let m = min(len, 64)
        var i = 1
        while i < m {
            let a = p[o + i - 1], b = p[o + i]
            if ((a >= 97 && a <= 122) || (a >= 48 && a <= 57)) && (b >= 65 && b <= 90) {
                bits |= (1 << UInt64(i))
            }
            i += 1
        }
        return bits
    }

    // Per-entry attributes (parallel arrays).
    public internal(set) var parent: [Int32] = []     // index of parent entry, -1 for roots
    public internal(set) var size: [Int64] = []       // logical bytes (0 for dirs)
    public internal(set) var mtime: [Int64] = []      // modified, nanoseconds since 1970
    public internal(set) var crtime: [Int64] = []     // created, nanoseconds since 1970
    public internal(set) var objType: [UInt8] = []    // VREG=1 VDIR=2 VLNK=5
    public internal(set) var flags: [UInt32] = []     // BSD st_flags
    public internal(set) var hidden: [Bool] = []      // name starts with '.' or UF_HIDDEN
    public internal(set) var deleted: [Bool] = []     // tombstones (live removals)

    // Live-update indexes (built during crawl, maintained by the reconciler).
    // CSR (csrChildIds/csrChildOff) + childOverlay map a directory entry to its child entry
    // indices (see childrenLocked); dirIndexByHash maps the FNV-1a 64 hash of a directory's
    // DISPLAY path (NFC bytes) to its entry
    // index so FSEvents paths resolve WITHOUT storing every directory's path string
    // (~400k dirs × 60-100+ B each). Lookups verify the hit by reconstructing the
    // entry's real path, so a hash collision can never resolve to a wrong directory —
    // it just misses (nil) and the caller treats the dir as unknown. Two different
    // dirs colliding on insert is last-write-wins (same as the old String map for
    // equal paths); the loser merely falls back to parent-rescan reconciles.
    // CSR adjacency, rebuilt each buildLiveIndexes (crawl end / snapshot load / rescan). children of dir d
    // (0 ≤ d < n) are csrChildIds[csrChildOff[d] ..< csrChildOff[d+1]]; csrChildOff has length n+1.
    var csrChildIds: [Int32] = []
    var csrChildOff: [Int32] = []
    // Overlay: dirs whose child set changed AFTER the CSR build (live reconcile). Absorbed at next
    // buildLiveIndexes. Live-churn growth is acceptable.
    var childOverlay: [Int32: [Int32]] = [:]
    var dirIndexByHash: [UInt64: Int32] = [:]

    /// The children of a directory entry. CALLER HOLDS THE LOCK (rd for readers, wr for the reconciler).
    /// Overlay wins over CSR. Returns a slice — no per-dir heap array, no copy on the CSR path. The slice is
    /// valid for the duration of the lock hold; the CSR path aliases csrChildIds, the overlay path retains the
    /// overlay array's buffer.
    @inline(__always) func childrenLocked(of dir: Int32) -> ArraySlice<Int32> {
        if let ov = childOverlay[dir] { return ov[...] }
        let d = Int(dir)
        guard d >= 0, d + 1 < csrChildOff.count else { return ArraySlice<Int32>() }
        return csrChildIds[Int(csrChildOff[d]) ..< Int(csrChildOff[d + 1])]
    }

    /// TEST-ONLY: children of `dir` via the maintained CSR+overlay path (copies the slice).
    public func _debugChildren(of dir: Int32) -> [Int32] {
        rdlock(); defer { unlock() }
        return Array(childrenLocked(of: dir))
    }
    /// TEST-ONLY: number of dirs currently holding a live overlay entry (should be 0 right
    /// after a buildLiveIndexes rebuild, since the CSR build absorbs/drops the overlay).
    public var _debugOverlayCount: Int { rdlock(); defer { unlock() }; return childOverlay.count }

    /// A READ-WRITE lock: many concurrent readers (searches + row/path accessors +
    /// main-thread cell rendering) run in parallel; only mutations (crawl append,
    /// reconcile, clear) take the exclusive write lock. This stops a background search
    /// from stalling main-thread rendering (and vice-versa) the way one exclusive lock
    /// did. Heap-allocated so concurrent `pthread_*lock(rwlock)` calls don't trip
    /// Swift's exclusive-access-to-a-`var` checking.
    private let rwlock: UnsafeMutablePointer<pthread_rwlock_t> = {
        let p = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(p, nil)
        return p
    }()
    @inline(__always) func rdlock() { pthread_rwlock_rdlock(rwlock) }   // internal: Snapshot.swift extension uses these
    @inline(__always) func wrlock() { pthread_rwlock_wrlock(rwlock) }
    @inline(__always) func unlock() { pthread_rwlock_unlock(rwlock) }
    deinit {
        pthread_rwlock_destroy(rwlock); rwlock.deallocate()
        pthread_cond_destroy(readyCond); readyCond.deallocate()
        pthread_mutex_destroy(readyMutex); readyMutex.deallocate()
    }

    // MARK: - [21] Phased buildLiveIndexes readiness (warm-path snapshot load)
    //
    // `loadSnapshot` leaves a Phase-A-complete index on return: arrays live, nameMask/
    // typeClass/camelBits seeded to safe "match everything" sentinels, CSR/dirIndexByHash
    // empty. `buildNameMasksPhase()` (Phase B) and `buildTreePhase()` (Phase C) fill the
    // authoritative values afterwards on the warm path; `buildLiveIndexes()` (crawl/cold
    // path) does both in one shot and sets both flags true at the end, so its callers are
    // unaffected. See SPEC-B3-FINAL §2.1.
    private var liveMasksReadyValue = false   // Phase B done: nameMask/typeClass/camelBits authoritative
    private var liveTreeReadyValue  = false   // Phase C done: dirIndexByHash + CSR authoritative
    var liveMasksReadyLocked: Bool { liveMasksReadyValue }   // caller holds a lock (rd or wr)
    var liveTreeReadyLocked:  Bool { liveTreeReadyValue }
    /// TEST/UI: true once Phase C (the full live indexes) is ready. Takes its own rdlock.
    public var liveIndexesReady: Bool { rdlock(); defer { unlock() }; return liveTreeReadyValue }
    /// TEST-ONLY: Phase B done (nameMask/typeClass/camelBits authoritative). `liveIndexesReady`
    /// only surfaces Phase C; mvsim's phased-warm block needs to observe Phase B independently.
    public var _debugMasksReady: Bool { rdlock(); defer { unlock() }; return liveMasksReadyValue }

    /// Dedicated cond var (NOT the rwlock) so a search waiting on a phase never blocks — and
    /// is never blocked by — a concurrent rdlock/wrlock holder. A waiter must NEVER hold the
    /// index rwlock while parked here (§2.2 scan-time gate calls these before acquiring it).
    private let readyMutex: UnsafeMutablePointer<pthread_mutex_t> = {
        let p = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        pthread_mutex_init(p, nil)
        return p
    }()
    private let readyCond: UnsafeMutablePointer<pthread_cond_t> = {
        let p = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
        pthread_cond_init(p, nil)
        return p
    }()

    /// Blocks until Phase B (nameMask/typeClass/camelBits) is authoritative. Returns
    /// immediately if already ready (bounded wait: Phase B/C are scheduled on the warm
    /// queue right after Phase A, ~30-50ms/~10-20ms — see §2.1).
    public func waitForMasks() {
        pthread_mutex_lock(readyMutex)
        while !liveMasksReadyValue { pthread_cond_wait(readyCond, readyMutex) }
        pthread_mutex_unlock(readyMutex)
    }
    /// Blocks until Phase C (dirIndexByHash + CSR) is authoritative.
    public func waitForTree() {
        pthread_mutex_lock(readyMutex)
        while !liveTreeReadyValue { pthread_cond_wait(readyCond, readyMutex) }
        pthread_mutex_unlock(readyMutex)
    }
    /// Flip a readiness flag TRUE. Caller MUST hold the wrlock (lock order is always
    /// wrlock → readyMutex; waiters take readyMutex only, so no inversion). Writing the
    /// value INSIDE the cond mutex while still under the wrlock closes the agy-review race:
    /// a clear()/loadSnapshot between "phase done under wrlock" and a separate broadcast
    /// could be overwritten, marking an emptied index "ready" and waking waiters into OOB
    /// reads. With the single-site write + the phase functions' epoch guard, a stale phase
    /// can never re-assert readiness over a reset.
    @inline(__always) private func setReadyLocked(masks: Bool, tree: Bool) {
        pthread_mutex_lock(readyMutex)
        if masks { liveMasksReadyValue = true }
        if tree { liveTreeReadyValue = true }
        pthread_cond_broadcast(readyCond)
        pthread_mutex_unlock(readyMutex)
    }
    /// clear() / loadSnapshot() / crawl start: both phases are false again until the next
    /// buildLiveIndexes() (cold) or buildNameMasksPhase()+buildTreePhase() (warm) run.
    /// Caller holds the wrlock; the cond mutex is taken too so the false-write is
    /// synchronized with waiters' predicate reads (same wrlock → readyMutex order).
    func resetReadinessLocked() {
        pthread_mutex_lock(readyMutex)
        liveMasksReadyValue = false; liveTreeReadyValue = false
        pthread_mutex_unlock(readyMutex)
    }

    /// Bumped under the write lock on EVERY content mutation (append/delete/attr/clear/
    /// load). SearchEngine keys its order/narrowing caches off this, so a mutation can
    /// never leave a stale cache even if the engine's `invalidate()` is forgotten — the
    /// caches self-heal on the next search. Read only while holding the lock.
    private var _mutationGen = 0
    var mutationGenLocked: Int { _mutationGen }                       // caller already holds the lock
    @inline(__always) private func bumpMut() { _mutationGen &+= 1 }   // caller holds wrlock
    func bumpMutationLocked() { _mutationGen &+= 1 }                  // internal: Snapshot.swift, caller holds wrlock
    // External "refresh now" (SearchEngine.invalidate()). Must force a full rebuild in ALL THREE
    // order families, not just fs=true .size: advance _mutationGen (fsSize), structSeqValue (name),
    // and strictly advance totalSeq via chgBase (attr family, keyed on (epoch, totalSeq) — a mere
    // ++ of chgBase with the log emptied would leave totalSeq numerically unchanged, see spec CF-1).
    public func bumpMutation() {
        wrlock(); defer { unlock() }
        _mutationGen &+= 1                                 // fs=true .size family
        structSeqValue &+= 1                               // name family
        attrSeqValue   &+= 1                               // kept monotone; not strictly required
        chgBase = chgBase &+ chgIds.count &+ 1
        chgIds.removeAll(keepingCapacity: true)
        chgKinds.removeAll(keepingCapacity: true)
        chgPayload.removeAll(keepingCapacity: true)
    }
    /// Locked snapshot of the mutation generation — bumped on every content change. Caches
    /// keyed only by path (e.g. BundleSizeCache) compare against this to self-invalidate.
    public func mutationGeneration() -> Int { rdlock(); defer { unlock() }; return _mutationGen }

    /// Bumped on every clear() so an in-flight reconcile from a previous crawl
    /// generation can detect it's stale and no-op instead of corrupting the fresh index.
    private var epochValue = 0
    public func currentEpoch() -> Int { rdlock(); defer { unlock() }; return epochValue }
    var epochLocked: Int { epochValue }                 // caller holds the lock (SearchEngine order cache)
    func bumpEpochLocked() { epochValue &+= 1 }          // internal: Snapshot load, caller holds wrlock

    public init() {}

    public var count: Int { nameOff.count }

    /// TEST-ONLY: parent id of entry `i` (-1 for a root or out-of-range index) — a tiny
    /// accessor so mvsim's brute-force children oracle can walk `parent[]` without a lock dance.
    public func parentOf(_ i: Int) -> Int32 {
        rdlock(); defer { unlock() }
        return i >= 0 && i < parent.count ? parent[i] : -1
    }

    // MARK: - Character bloom mask

    /// The bloom bit for one byte, CASE-FOLDED (A-Z and a-z share a bit) so a
    /// case-sensitive query ("Report") and the folded blobs agree — the mask is a
    /// pure existence set, case discrimination is left to the byte scan.
    /// Layout: a-z → 0..25, 0-9 → 26..35, everything else → 36 + (b % 28) buckets
    /// (covers UTF-8 continuation bytes; collisions only ever cost extra scans).
    @inline(__always) public static func charBit(_ b: UInt8) -> Int {
        if b >= 65, b <= 90 { return Int(b - 65) }         // A-Z
        if b >= 97, b <= 122 { return Int(b - 97) }        // a-z → same bits as A-Z
        if b >= 48, b <= 57 { return 26 + Int(b - 48) }    // 0-9
        return 36 + Int(b % 28)                            // 36..63
    }

    /// The bloom mask for a byte sequence (used for both entry names and query needles).
    @inline(__always) public static func maskOf<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var m: UInt64 = 0
        for b in bytes { m |= (1 << UInt64(charBit(b))) }
        return m
    }

    /// Lock-safe count for live progress polling while a crawl is appending.
    public func safeCount() -> Int { rdlock(); defer { unlock() }; return nameOff.count }

    /// Running count of tombstoned rows, so liveStats() is O(1) instead of an O(n) scan.
    /// The ONLY place a row flips deleted=true is `_markDeletedSubtree`; appends are always
    /// deleted=false; clear() and snapshot-load reset it (load compacts tombstones away).
    /// Maintained under the write lock. (internal so Snapshot.swift's load can reset it.)
    var _deletedCount = 0
    var deletedCountLocked: Int { _deletedCount }   // caller holds the lock
    /// (total slots, tombstoned) — for deciding when to compact away dead entries. O(1): the
    /// 120s periodic compaction check used to scan all ~2M rows on the main thread under the
    /// read lock every 2 minutes (a multi-ms hitch + lock hold); now a plain counter read.
    public func liveStats() -> (total: Int, deleted: Int) {
        rdlock(); defer { unlock() }
        return (nameOff.count, _deletedCount)
    }

    // MARK: - Order-maintenance change log (all writes under wrlock; reads under rdlock)
    // A flat record stream the SearchEngine replays to update cached sort orders incrementally
    // instead of re-argsorting ~2M ids per reconcile batch. kinds: 0=append 1=tombstone 2=attr.
    private var chgIds:   [Int32] = []
    private var chgKinds: [UInt8] = []
    private var chgPayload: [Int64] = []     // parallel; attr → sizeDelta, append/tombstone → 0
    private var chgBase:  Int = 0            // global seq of chgIds[0]; totalSeq = chgBase + chgIds.count
    private var structSeqValue: Int = 0      // monotonic: ++ per append OR tombstone record
    private var attrSeqValue:   Int = 0      // monotonic: ++ per attr record
    private var logCap: Int = 1 << 18        // 262144; var so a test hook can shrink it

    @inline(__always) private func logAppend(_ id: Int32)    { logRecord(id, 0, 0); structSeqValue &+= 1 }
    @inline(__always) private func logTombstone(_ id: Int32) { logRecord(id, 1, 0); structSeqValue &+= 1 }
    @inline(__always) private func logAttr(_ id: Int32, _ sizeDelta: Int64) { logRecord(id, 2, sizeDelta); attrSeqValue &+= 1 }

    @inline(__always) private func logRecord(_ id: Int32, _ kind: UInt8, _ payload: Int64) {
        chgIds.append(id); chgKinds.append(kind); chgPayload.append(payload)
        assert(chgIds.count == chgKinds.count && chgIds.count == chgPayload.count)   // [S4] lockstep guard
        if chgIds.count > logCap {                 // overflow: drop oldest half, advance base
            let drop = chgIds.count / 2
            chgIds.removeFirst(drop); chgKinds.removeFirst(drop); chgPayload.removeFirst(drop)  // LOCKSTEP
            chgBase &+= drop                        // consumers with appliedSeq < chgBase → full rebuild
        }
    }

    func resetChangeLog() {                 // clear() / snapshot load (internal: Snapshot.swift calls this)
        chgIds.removeAll(keepingCapacity: false); chgKinds.removeAll(keepingCapacity: false)
        chgPayload.removeAll(keepingCapacity: false)
        chgBase = 0; structSeqValue = 0; attrSeqValue = 0
    }

    // Locked accessors — CALLER HOLDS THE READ LOCK (SearchEngine order path runs under rdlock).
    var structSeqLocked: Int { structSeqValue }
    var attrSeqLocked:   Int { attrSeqValue }
    var totalSeqLocked:  Int { chgBase &+ chgIds.count }
    var chgBaseLocked:   Int { chgBase }
    /// Slice-copy the records in [fromSeq, totalSeq). Returns nil if fromSeq < chgBase (log dropped
    /// that far back → caller must full-rebuild). COW array slices are safe under the shared rdlock.
    func changeRecordsLocked(from fromSeq: Int) -> (ids: [Int32], kinds: [UInt8])? {
        let total = chgBase &+ chgIds.count
        guard fromSeq >= chgBase, fromSeq <= total else { return nil }
        let lo = fromSeq - chgBase
        return (Array(chgIds[lo...]), Array(chgKinds[lo...]))   // lo..<count
    }

    /// Like changeRecordsLocked but also returns the parallel Int64 payload (attr → sizeDelta). Only the
    /// folder-size consumer uses this; the order replay keeps the 2-tuple API and never sees payloads.
    /// (`_folderSizes()` replays the log arrays DIRECTLY under the held lock rather than calling this
    /// sibling, to avoid three transient Array copies on the hot path. Provided for symmetry/future
    /// callers; not on the fsize hot path — kept, costs nothing unless called.)
    func changeRecordsWithPayloadLocked(from fromSeq: Int) -> (ids: [Int32], kinds: [UInt8], payload: [Int64])? {
        let total = chgBase &+ chgIds.count
        guard fromSeq >= chgBase, fromSeq <= total else { return nil }
        let lo = fromSeq - chgBase
        return (Array(chgIds[lo...]), Array(chgKinds[lo...]), Array(chgPayload[lo...]))
    }

    // TEST-ONLY: force a small cap so mvsim can exercise the overflow→full-rebuild fallback.
    public func _debugSetChangeLogCap(_ cap: Int) { wrlock(); defer { unlock() }; logCap = max(2, cap) }

    // Locked (safe to call from the main thread while the reconciler mutates).
    // Bounds-guarded like `row(_:)`: SwiftUI (GridResults et al.) can render one frame
    // with result ids from the PREVIOUS index generation while a reindex has already
    // clear()ed the arrays — an out-of-range subscript here killed the whole app
    // (crash: "Index out of range" in FileIndex.isDir ← GridResults.cell). Out of
    // range answers as "not there": false / deleted / empty string.
    @inline(__always) public func isDir(_ i: Int) -> Bool {
        rdlock(); defer { unlock() }
        guard i >= 0, i < objType.count else { return false }
        return objType[i] == VNODE_VDIR
    }
    @inline(__always) public func isDeleted(_ i: Int) -> Bool {
        rdlock(); defer { unlock() }
        guard i >= 0, i < deleted.count else { return true }
        return deleted[i]
    }

    /// Empties the index (for a full re-crawl).
    public func clear() {
        wrlock(); defer { unlock() }
        bumpMut()
        epochValue &+= 1   // invalidate any in-flight reconcile captured before this
        nameBlob.removeAll(keepingCapacity: false)
        foldBlob.removeAll(keepingCapacity: false)
        unicodeFoldBlob.removeAll(keepingCapacity: false)
        nameOff.removeAll(keepingCapacity: false); nameLen.removeAll(keepingCapacity: false)
        unicodeFoldOff.removeAll(keepingCapacity: false); unicodeFoldLen.removeAll(keepingCapacity: false)
        nameMask.removeAll(keepingCapacity: false)
        typeClass.removeAll(keepingCapacity: false)
        camelBits.removeAll(keepingCapacity: false)
        parent.removeAll(keepingCapacity: false); size.removeAll(keepingCapacity: false)
        mtime.removeAll(keepingCapacity: false); crtime.removeAll(keepingCapacity: false)
        objType.removeAll(keepingCapacity: false)
        flags.removeAll(keepingCapacity: false); hidden.removeAll(keepingCapacity: false)
        deleted.removeAll(keepingCapacity: false)
        _deletedCount = 0
        csrChildIds.removeAll(); csrChildOff.removeAll(); childOverlay.removeAll()
        dirIndexByHash.removeAll(keepingCapacity: false)
        resetChangeLog()
        resetFsizeLocked()   // [N2] defense-in-depth
        resetReadinessLocked()   // [21] a fresh crawl starts back at "no phase complete"
    }

    public func reserveCapacity(_ n: Int) {
        wrlock(); defer { unlock() }   // reallocation must not race a concurrent reader
        // The byte blobs + typeClass were omitted here, so they grew from empty during the
        // crawl — ~log2(60MB) reallocations each, memcpy'ing ~120MB+ of redundant data UNDER
        // the write lock (stalling every append + concurrent reader). Reserve a rough average
        // name length so the large blobs don't repeatedly realloc. (~24 B/entry is generous;
        // over-reservation just wastes transient RAM, which grows-past normally anyway.)
        nameBlob.reserveCapacity(n * 24); foldBlob.reserveCapacity(n * 24)
        unicodeFoldBlob.reserveCapacity(n)   // conservative — only a few % of names carry a fold
        typeClass.reserveCapacity(n)
        camelBits.reserveCapacity(n)
        nameOff.reserveCapacity(n); nameLen.reserveCapacity(n)
        unicodeFoldOff.reserveCapacity(n); unicodeFoldLen.reserveCapacity(n)
        nameMask.reserveCapacity(n)
        parent.reserveCapacity(n); size.reserveCapacity(n); mtime.reserveCapacity(n)
        crtime.reserveCapacity(n)
        objType.reserveCapacity(n); flags.reserveCapacity(n); hidden.reserveCapacity(n)
        deleted.reserveCapacity(n)
    }

    // MARK: - Building

    /// Appends a crawl root (absolute path stored as the name). Returns its index.
    public func appendRoot(path: String) -> Int32 {
        wrlock(); defer { unlock() }
        bumpMut()
        // NFC-normalize like every other stored name, so a non-ASCII volume root is
        // findable by an NFC query / full-path match (APFS may store names as NFD).
        let bytes = Array(path.precomposedStringWithCanonicalMapping.utf8)
        let fold = bytes.map(asciiLower)
        let idx = Int32(nameOff.count)
        nameOff.append(UInt64(nameBlob.count))
        nameLen.append(UInt16(bytes.count))
        nameBlob.append(contentsOf: bytes)
        foldBlob.append(contentsOf: fold)
        appendUnicodeFoldStorage(for: bytes, blob: &unicodeFoldBlob,
                                 off: &unicodeFoldOff, len: &unicodeFoldLen)
        parent.append(-1)
        size.append(0); mtime.append(0); crtime.append(0)
        objType.append(VNODE_VDIR); flags.append(0); hidden.append(false); deleted.append(false)
        nameMask.append(.max)   // authoritative value filled by buildLiveIndexes (safe passthrough meanwhile)
        typeClass.append(fold.withUnsafeBufferPointer { FileTypeClass.mask(foldedName: $0.baseAddress!, 0, $0.count) })
        camelBits.append(bytes.withUnsafeBufferPointer { Self.camelBitsOf($0.baseAddress!, 0, bytes.count) })
        logAppend(idx)   // real append site: crawl-start root + live volume mount (spec OI-1)
        return idx   // live-update maps are built in bulk post-crawl (buildLiveIndexes)
    }

    /// Appends a whole directory's children in one locked batch (amortizes lock
    /// cost to one acquisition per directory rather than per file). Returns the
    /// base global index; child `j` lives at `base + j`. Kept deliberately lean —
    /// no string/dict work under the lock — so the parallel crawl stays fast.
    /// Live-update maps are built afterwards by `buildLiveIndexes()`.
    func appendChildren(parent parentIdx: Int32, displayParent: String, _ batch: ChildBatch) -> Int32 {
        wrlock(); defer { unlock() }
        bumpMut()
        let base = Int32(nameOff.count)
        let blobBase = UInt64(nameBlob.count)
        let unicodeBlobBase = UInt64(unicodeFoldBlob.count)
        nameBlob.append(contentsOf: batch.blob)
        foldBlob.append(contentsOf: batch.fold)
        unicodeFoldBlob.append(contentsOf: batch.unicodeFoldBlob)
        for o in batch.off { nameOff.append(checkedBlobOffset(o, adding: blobBase)) }
        nameLen.append(contentsOf: batch.len)
        for o in batch.unicodeFoldOff {
            unicodeFoldOff.append(o == noUnicodeFoldOffset ? o : checkedBlobOffset(o, adding: unicodeBlobBase))
        }
        unicodeFoldLen.append(contentsOf: batch.unicodeFoldLen)
        size.append(contentsOf: batch.size)
        mtime.append(contentsOf: batch.mtime)
        crtime.append(contentsOf: batch.crtime)
        objType.append(contentsOf: batch.objType)
        flags.append(contentsOf: batch.flags)
        hidden.append(contentsOf: batch.hidden)
        let n = batch.len.count
        for _ in 0..<n { parent.append(parentIdx); deleted.append(false) }
        nameMask.append(contentsOf: repeatElement(.max, count: n))   // filled by buildLiveIndexes
        // typeClass is a FILTER (not a prefilter) computed EXACT at append time (a search during
        // the crawl must not miss these). Now computed in ChildBatch.appendName off the write
        // lock (parallel scan phase) — here we just splice the precomputed masks in.
        typeClass.append(contentsOf: batch.typeClass)
        camelBits.append(contentsOf: batch.camelBits)
        for j in 0..<n { logAppend(base &+ Int32(j)) }   // crawl floods overflow the cap ⇒ chgBase
                                                          // jumps ⇒ consumers full-rebuild (today's behavior)
        return base
    }

    /// Builds the live-update maps (CSR children, dirIndexByHash) in one O(n) pass
    /// after the crawl. Entries are appended parent-before-child, so a forward
    /// pass can extend each directory's display-path FNV state from its parent's —
    /// no path string is ever materialized (FNV-1a streams left-to-right, and a
    /// child's display path is parentPath + "/" + name), so the only transient is
    /// one UInt64 per entry instead of an array of every directory path string.
    // Bumped by every buildLiveIndexes: the sentinel→authoritative transition for
    // typeClass/nameMask/camelBits (and the CSR rebuild) changes type:/empty: filter RESULTS
    // without any epoch/structSeq/attrSeq movement — caches keyed on those gens alone would
    // go stale across it (Codex B2 review: a -type: query cached against sentinel typeClass).
    private var liveBuildGenValue = 0
    var liveBuildGenLocked: Int { liveBuildGenValue }   // caller holds a lock

    /// Cold path (crawl end / rescan): builds masks AND the tree in one shot, matching
    /// pre-[21] behavior exactly. The warm (snapshot-load) path instead runs
    /// `buildNameMasksPhase()` then `buildTreePhase()` so the UI can serve name search
    /// after Phase A without waiting for either (§2.1/§2.5 — crawl is intentionally NOT
    /// phased, to avoid complicating the one code path every launch depends on).
    public func buildLiveIndexes() {
        wrlock()
        liveBuildGenValue &+= 1
        let n = nameOff.count
        dirIndexByHash.removeAll(keepingCapacity: true)
        computeNameMasksLocked(n)
        var dirHash = [UInt64](repeating: 0, count: n)   // FNV state of each dir's display path
        nameBlob.withUnsafeBufferPointer { blob in
            // Feed entry i's name bytes into FNV state h. Blob bytes are NFC (normalized
            // at ingestion), so this equals hashing the reconstructed path's String.utf8.
            func feedName(_ h: UInt64, _ i: Int) -> UInt64 {
                var h = h
                let o = Int(nameOff[i]), e = o + Int(nameLen[i])
                for k in o..<e { h = fnvFeed(h, blob[k]) }
                return h
            }
            for i in 0..<n {
                let p = parent[i]
                if objType[i] == VNODE_VDIR {
                    let pi = Int(p)
                    let h: UInt64
                    if p < 0 {
                        h = feedName(fnvOffsetBasis, i)   // root: name IS the display path
                    } else if pi < i, objType[pi] == VNODE_VDIR {
                        // parentPath + "/" + name — unless the parent is a "/" root,
                        // whose display path already IS the separator ("/" + name).
                        let parentIsSlashRoot = parent[pi] < 0 && nameLen[pi] == 1
                            && blob[Int(nameOff[pi])] == UInt8(ascii: "/")
                        h = feedName(parentIsSlashRoot ? dirHash[pi]
                                                       : fnvFeed(dirHash[pi], UInt8(ascii: "/")), i)
                    } else {
                        h = feedName(fnvOffsetBasis, i)   // shouldn't happen (parent dir precedes child)
                    }
                    dirHash[i] = h
                    dirIndexByHash[h] = Int32(i)   // "/" roots collide; harmless
                }
            }
        }
        // CSR children (counting sort — two flat O(n) passes, zero hashing/COW). Order within a parent is
        // ASCENDING id, identical to the old forward-append dict-of-arrays. Empty-index safe: at n==0,
        // csrChildOff = [0] (length 1), the prefix-sum loop is skipped, totalChildren = 0, and the
        // count/scatter loops are empty (reachable: a fully-excluded / permission-denied root crawls 0 rows).
        childOverlay.removeAll(keepingCapacity: false)          // CSR now authoritative — absorb/drop overlay
        csrChildOff = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { let p = parent[i]; if p >= 0 { csrChildOff[Int(p) + 1] &+= 1 } }   // counts (shifted by 1)
        if n > 0 { for i in 1...n { csrChildOff[i] &+= csrChildOff[i - 1] } }               // prefix sum
        let totalChildren = Int(csrChildOff[n])                                            // 0 when n==0
        csrChildIds = [Int32](repeating: 0, count: totalChildren)
        var cursor = csrChildOff                                                            // per-parent write head
        for i in 0..<n {
            let p = parent[i]
            if p >= 0 { let pos = Int(cursor[Int(p)]); csrChildIds[pos] = Int32(i); cursor[Int(p)] &+= 1 }
        }
        // Bump the generation so every gen-keyed cache (order, incremental narrowing,
        // the engine's frecency-id map) rebuilds AGAINST the freshly-built live maps.
        // Without this a frecency map resolved while children were still empty (during
        // crawl / right after snapshot load) would be cached under an unchanged gen and
        // never re-resolve (Codex review).
        bumpMut()
        setReadyLocked(masks: true, tree: true)   // [21] one-shot cold path: both phases at once
        unlock()
    }

    /// [21] Phase B (warm path only): compute nameMask/typeClass/camelBits authoritatively —
    /// exactly what `computeNameMasksLocked` computes, but OFF-LOCK (§2.4): read the
    /// immutable-through-A→C source arrays under a brief rdlock, compute three FRESH local
    /// arrays with NO lock held (safe under OI-4 — no writer runs between Phase A and Phase C
    /// on the warm path, so nothing mutates nameOff/nameLen/foldBlob/unicodeFold*/nameBlob
    /// concurrently), then take the wrlock only to swap the three properties in (microseconds)
    /// and flip the readiness flag. This keeps a concurrent Phase-A search's rdlock hold short
    /// even while a ~2M-entry mask scan runs in the background.
    public func buildNameMasksPhase() {
        rdlock()
        let epoch0 = epochValue   // agy review: guard the publish against a mid-phase clear/reload
        let n = nameOff.count
        let nameOffL = nameOff, nameLenL = nameLen, foldBlobL = foldBlob
        let unicodeFoldBlobL = unicodeFoldBlob
        let unicodeFoldOffL = unicodeFoldOff, unicodeFoldLenL = unicodeFoldLen
        let nameBlobL = nameBlob
        unlock()

        var newMask = [UInt64](repeating: 0, count: n)
        var newType = [UInt8](repeating: 0, count: n)
        var newCamel = [UInt64](repeating: 0, count: n)
        foldBlobL.withUnsafeBufferPointer { fb in
        unicodeFoldBlobL.withUnsafeBufferPointer { ub in
        nameBlobL.withUnsafeBufferPointer { nbb in
        newMask.withUnsafeMutableBufferPointer { mb in
        newType.withUnsafeMutableBufferPointer { tc in
        newCamel.withUnsafeMutableBufferPointer { cb in
            let fbBase = fb.baseAddress!, nbBase = nbb.baseAddress!
            for i in 0..<n {
                var m: UInt64 = 0
                let o = Int(nameOffL[i]), e = o + Int(nameLenL[i])
                for k in o..<e { m |= (1 << UInt64(Self.charBit(fb[k]))) }
                if unicodeFoldOffL[i] != noUnicodeFoldOffset {
                    let uo = Int(unicodeFoldOffL[i]), ue = uo + Int(unicodeFoldLenL[i])
                    for k in uo..<ue { m |= (1 << UInt64(Self.charBit(ub[k]))) }
                }
                mb[i] = m
                tc[i] = FileTypeClass.mask(foldedName: fbBase, o, Int(nameLenL[i]))
                cb[i] = Self.camelBitsOf(nbBase, o, Int(nameLenL[i]))
            }
        }}}}}}

        wrlock()
        // agy review: if a clear()/loadSnapshot replaced the index while we computed, these
        // buffers describe a DEAD index — publishing them (or re-asserting readiness over the
        // reset) would hand waiters authoritative-looking garbage. Abandon; the new epoch's
        // own build owns readiness now.
        guard epochValue == epoch0 else { unlock(); return }
        nameMask = newMask
        typeClass = newType
        camelBits = newCamel
        liveBuildGenValue &+= 1
        bumpMut()
        setReadyLocked(masks: true, tree: false)
        unlock()
    }

    /// [21] Phase C (warm path only): build dirIndexByHash + CSR (csrChildOff/csrChildIds) and
    /// drop childOverlay — the second half of `buildLiveIndexes`, off-lock (§2.4) the same way
    /// as Phase B: snapshot the immutable-through-A→C source arrays under a brief rdlock,
    /// compute fresh locals with no lock held, then take the wrlock only to publish + flip the
    /// readiness flag.
    public func buildTreePhase() {
        rdlock()
        let epoch0 = epochValue   // agy review: guard the publish against a mid-phase clear/reload
        let n = nameOff.count
        let nameOffL = nameOff, nameLenL = nameLen, nameBlobL = nameBlob
        let parentL = parent, objTypeL = objType
        unlock()

        var dirHash = [UInt64](repeating: 0, count: n)   // FNV state of each dir's display path
        var newDirIndexByHash: [UInt64: Int32] = [:]
        nameBlobL.withUnsafeBufferPointer { blob in
            func feedName(_ h: UInt64, _ i: Int) -> UInt64 {
                var h = h
                let o = Int(nameOffL[i]), e = o + Int(nameLenL[i])
                for k in o..<e { h = fnvFeed(h, blob[k]) }
                return h
            }
            for i in 0..<n {
                let p = parentL[i]
                if objTypeL[i] == VNODE_VDIR {
                    let pi = Int(p)
                    let h: UInt64
                    if p < 0 {
                        h = feedName(fnvOffsetBasis, i)   // root: name IS the display path
                    } else if pi < i, objTypeL[pi] == VNODE_VDIR {
                        let parentIsSlashRoot = parentL[pi] < 0 && nameLenL[pi] == 1
                            && blob[Int(nameOffL[pi])] == UInt8(ascii: "/")
                        h = feedName(parentIsSlashRoot ? dirHash[pi]
                                                       : fnvFeed(dirHash[pi], UInt8(ascii: "/")), i)
                    } else {
                        h = feedName(fnvOffsetBasis, i)   // shouldn't happen (parent dir precedes child)
                    }
                    dirHash[i] = h
                    newDirIndexByHash[h] = Int32(i)   // "/" roots collide; harmless
                }
            }
        }
        // CSR children — identical counting-sort as buildLiveIndexes (see there for the
        // empty-index-safe reasoning).
        var newCsrChildOff = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { let p = parentL[i]; if p >= 0 { newCsrChildOff[Int(p) + 1] &+= 1 } }
        if n > 0 { for i in 1...n { newCsrChildOff[i] &+= newCsrChildOff[i - 1] } }
        let totalChildren = Int(newCsrChildOff[n])
        var newCsrChildIds = [Int32](repeating: 0, count: totalChildren)
        var cursor = newCsrChildOff
        for i in 0..<n {
            let p = parentL[i]
            if p >= 0 { let pos = Int(cursor[Int(p)]); newCsrChildIds[pos] = Int32(i); cursor[Int(p)] &+= 1 }
        }

        wrlock()
        guard epochValue == epoch0 else { unlock(); return }   // agy review: dead-index buffers
        dirIndexByHash = newDirIndexByHash
        childOverlay.removeAll(keepingCapacity: false)   // CSR now authoritative — absorb/drop overlay
        csrChildOff = newCsrChildOff
        csrChildIds = newCsrChildIds
        liveBuildGenValue &+= 1
        bumpMut()
        setReadyLocked(masks: false, tree: true)
        unlock()
    }

    /// Authoritative bloom-mask pass. Each entry's mask = the folded characters of
    /// its ASCII fold blob (covers original + case:on via case-folded bits) OR'd with
    /// its Unicode fold blob (covers diacritic folds, e.g. café↔cafe) — so whichever
    /// representation `matchFoldedName` matches, the needle's chars are guaranteed
    /// present in the mask (no false negative). Caller holds the write lock.
    private func computeNameMasksLocked(_ n: Int) {
        nameMask = [UInt64](repeating: 0, count: n)
        typeClass = [UInt8](repeating: 0, count: n)
        camelBits = [UInt64](repeating: 0, count: n)
        foldBlob.withUnsafeBufferPointer { fb in
        unicodeFoldBlob.withUnsafeBufferPointer { ub in
        nameBlob.withUnsafeBufferPointer { nbb in
        nameMask.withUnsafeMutableBufferPointer { mb in
        typeClass.withUnsafeMutableBufferPointer { tc in
        camelBits.withUnsafeMutableBufferPointer { cb in
            let fbBase = fb.baseAddress!, nbBase = nbb.baseAddress!
            for i in 0..<n {
                var m: UInt64 = 0
                let o = Int(nameOff[i]), e = o + Int(nameLen[i])
                for k in o..<e { m |= (1 << UInt64(Self.charBit(fb[k]))) }
                if unicodeFoldOff[i] != noUnicodeFoldOffset {
                    let uo = Int(unicodeFoldOff[i]), ue = uo + Int(unicodeFoldLen[i])
                    for k in uo..<ue { m |= (1 << UInt64(Self.charBit(ub[k]))) }
                }
                mb[i] = m
                // typeClass reads the SAME folded name bytes (last-dot extension) that
                // SearchEngine.extMatches uses → type: and ext: agree by construction.
                tc[i] = FileTypeClass.mask(foldedName: fbBase, o, Int(nameLen[i]))
                // camelBits reads CASED bytes (nameBlob) — folding erases the case
                // transition camelCase detection depends on. nameOff/nameLen index
                // both blobs identically (asciiLower is byte-length-preserving).
                cb[i] = Self.camelBitsOf(nbBase, o, Int(nameLen[i]))
            }
        }}}}}}
    }

    /// TEST-ONLY: force every bloom mask to all-bits, disabling the prefilter so a
    /// search performs the full ground-truth scan. Used by mvsim to prove the gate
    /// (masks on) returns exactly the same results as the brute scan (masks off).
    public func _debugSetAllMasksAllBits() {
        wrlock(); defer { unlock() }
        for i in nameMask.indices { nameMask[i] = .max }
        bumpMut()   // invalidate search caches so the next query rescans
    }

    // MARK: - Reading  (public = takes the lock; `_`-prefixed = caller holds it)

    /// Runs `body` while holding the index lock (used by the search scan so a
    /// concurrent live delta can't reallocate the arrays mid-read).
    @inline(__always) func withReadLock<T>(_ body: () -> T) -> T {
        rdlock(); defer { unlock() }; return body()
    }

    func _name(_ i: Int) -> String {
        let o = Int(nameOff[i]); let l = Int(nameLen[i])
        return nameBlob.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(start: buf.baseAddress! + o, count: l), as: UTF8.self)
        }
    }

    func _path(_ i: Int) -> String {
        guard i >= 0, i < parent.count else { return "" }   // defensive: stale id → no crash
        var comps: [String] = []
        var cur = i
        var rootName = ""
        var hops = 0
        while true {
            guard cur >= 0, cur < parent.count else { break }   // broken/stale parent chain
            let p = parent[cur]
            if p < 0 { rootName = _name(cur); break }
            comps.append(_name(cur))
            cur = Int(p)
            hops += 1
            if hops > 4096 { break }                             // cycle guard
        }
        var result = (rootName == "/") ? "" : rootName
        for c in comps.reversed() { result += "/" + c }
        return result.isEmpty ? "/" : result
    }

    /// The bare file/dir name of entry `i`. Bounds-guarded (stale-generation render — see isDir).
    public func name(_ i: Int) -> String {
        rdlock(); defer { unlock() }
        guard i >= 0, i < nameOff.count else { return "" }
        return _name(i)
    }

    /// Reconstructs the absolute path of entry `i` by walking parents. Bounds-guarded (see isDir).
    public func path(_ i: Int) -> String {
        rdlock(); defer { unlock() }
        guard i >= 0, i < nameOff.count else { return "" }
        return _path(i)
    }

    /// Resolve a folder's absolute path to its entry index (for folder-scoped search).
    /// NFC-normalizes first: the map is keyed by NFC bytes, whereas the old String
    /// dictionary hashed canonically-equivalent paths identically.
    public func dirIndex(forPath p: String) -> Int32? {
        rdlock(); defer { unlock() }
        return _dirIndexVerified(p.precomposedStringWithCanonicalMapping)
    }

    /// Hash-keyed dir lookup with verification (caller holds the lock; `p` must be NFC).
    /// Reconstructs the candidate's real path and compares, so an FNV collision can
    /// never resolve to a WRONG directory — a colliding query just misses (nil), which
    /// callers already treat as "unknown dir" (safe parent-rescan fallback).
    @inline(__always) private func _dirIndexVerified(_ p: String) -> Int32? {
        guard let i = dirIndexByHash[pathHash(p)], !deleted[Int(i)], _path(Int(i)) == p else { return nil }
        return i
    }

    /// Resolve NFC file paths to their CURRENT entry ids (ids change on reindex,
    /// paths don't). Grouped by parent directory so each parent's `name → id` map is
    /// built ONCE (never a per-path child rescan — Codex review: large dirs would
    /// blow up). Unresolved paths (deleted / moved / not indexed) are simply omitted.
    public func resolveIds(forPaths paths: [String]) -> [String: Int32] {
        rdlock(); defer { unlock() }
        return resolveIdsLocked(forPaths: paths)
    }

    /// Caller-holds-the-lock variant, so the frecency map can be resolved in the SAME
    /// read-lock acquisition as the search that uses it (Codex review: resolving under
    /// a separate lock let a reconcile change ids between resolve and scan).
    func resolveIdsLocked(forPaths paths: [String]) -> [String: Int32] {
        var out = [String: Int32](minimumCapacity: paths.count)
        var byParent: [String: [(full: String, base: Substring)]] = [:]
        for p in paths {
            // A tracked path may itself BE a directory (incl. a crawl root, parent == -1);
            // resolve it directly first so opened folders count too (Codex review).
            if let did = _dirIndexVerified(p) { out[p] = did; continue }
            guard let slash = p.lastIndex(of: "/") else { continue }
            let parent = slash == p.startIndex ? "/" : String(p[..<slash])
            let base = p[p.index(after: slash)...]
            if base.isEmpty { continue }
            byParent[parent, default: []].append((p, base))
        }
        for (parent, kids) in byParent {
            guard let pid = _dirIndexVerified(parent) else { continue }
            let childIdxs = childrenLocked(of: pid)
            var nameToId = [String: Int32](minimumCapacity: childIdxs.count)
            for ci in childIdxs where !deleted[Int(ci)] { nameToId[_name(Int(ci))] = ci }
            for (full, base) in kids where nameToId[String(base)] != nil { out[full] = nameToId[String(base)]! }
        }
        return out
    }

    /// FNV-1a 64 over the NFC display-path bytes (the dirIndexByHash key).
    @inline(__always) private func pathHash(_ s: String) -> UInt64 {
        var h = fnvOffsetBasis
        for b in s.utf8 { h = fnvFeed(h, b) }
        return h
    }

    // MARK: - folder-size index (Everything 1.5's "Index folder sizes")

    private var fsize: [Int64] = []
    private var fsizeEpoch: Int = -1        // epochValue at last (re)build
    private var fsizeAppliedSeq: Int = -1   // log totalSeq consumed into fsize
    private let fsizeLock = NSLock()

    /// Folder totals for ALL entries. Refreshes INCREMENTALLY by replaying the change log
    /// since the last build when possible (append/tombstone/attr contributions walked up the
    /// parent chain), falling back to a full bottom-up pass on epoch mismatch, a dropped log
    /// window, or an oversized window. Every incremental result equals the from-scratch
    /// computation exactly (see spec SPEC-B1-FINAL §2). Caller must hold the read lock.
    /// Lock order: rwlock → fsizeLock (everywhere).
    func _folderSizes() -> [Int64] {
        let epoch = epochLocked                     // == epochValue, caller holds rdlock
        let total = chgBase &+ chgIds.count         // == totalSeqLocked
        let n = nameOff.count
        fsizeLock.lock(); defer { fsizeLock.unlock() }

        // (a) fresh?
        if fsizeEpoch == epoch, fsizeAppliedSeq == total, fsize.count == n { return fsize }

        // (b) can we advance incrementally? same epoch AND the log still reaches back to appliedSeq.
        if fsizeEpoch == epoch, fsizeAppliedSeq >= chgBase, fsizeAppliedSeq <= total, fsize.count <= n {
            let lo = fsizeAppliedSeq - chgBase
            // grow fsize for ids appended since the last build (new slots start at 0 — a leaf's own slot is 0,
            // matching the full pass; dirs only ever RECEIVE from descendants).
            if fsize.count < n { fsize.append(contentsOf: repeatElement(0, count: n - fsize.count)) }

            // window-size guard: bound distinct work like applyIncremental (SearchEngine.swift).
            let hi = total - chgBase                 // == chgIds.count
            let windowLen = hi - lo
            if windowLen <= max(8192, n / 16) {
                // PASS 1: appended-set for the attr-exclusion rule.
                var appendedSet = Set<Int32>()
                for k in lo..<hi where chgKinds[k] == 0 { appendedSet.insert(chgIds[k]) }
                // PASS 2: apply each record's contribution up the parent chain. A truncated
                // walk (hop guard) means a partial contribution was committed — the replay is
                // no longer exact, so bail to the full rebuild below (Codex P2: silently
                // committing a truncated sequence left ancestors permanently drifted).
                var walksExact = true
                for k in lo..<hi {
                    let id = chgIds[k]
                    let isDir = objType[Int(id)] == VNODE_VDIR                    // [S3] gate
                    switch chgKinds[k] {
                    case 0:  if !isDir { walksExact = walkAddAncestors(of: id, delta: size[Int(id)]) && walksExact }        // append: +size @replay
                    case 1:  if !isDir { walksExact = walkAddAncestors(of: id, delta: 0 &- size[Int(id)]) && walksExact }   // tombstone: −size @replay (&- : Int64.min-safe, Codex P2)
                    default:                                                                // attr
                        if !isDir, !appendedSet.contains(id) {                              // gated + append-excluded
                            walksExact = walkAddAncestors(of: id, delta: chgPayload[k]) && walksExact  // +delta (pre-overwrite)
                        }
                    }
                }
                if walksExact {
                    fsizeAppliedSeq = total
                    return fsize
                }
                // truncated walk ⇒ fall through to full rebuild (overwrites the partial state)
            }
            // window too large ⇒ fall through to full rebuild
        }

        // (c) full rebuild — mirrors the ORIGINAL bottom-up pass EXACTLY.
        var out = [Int64](repeating: 0, count: n)
        var i = n - 1
        while i >= 0 {
            if !deleted[i] {
                let own = objType[i] == VNODE_VDIR ? out[i] : size[i]   // dir own-size ignored; VLNK counts as file
                let p = parent[i]
                if p >= 0, Int(p) < n { out[Int(p)] &+= own }
            }
            i -= 1
        }
        fsize = out; fsizeEpoch = epoch; fsizeAppliedSeq = total
        return fsize
    }

    /// Add `delta` to every ANCESTOR dir of `id` (its own slot untouched). Caller holds
    /// rdlock+fsizeLock. Returns false when the cycle guard truncated the walk — the caller
    /// MUST discard the incremental state and full-rebuild (partial contributions were applied).
    @inline(__always) private func walkAddAncestors(of id: Int32, delta: Int64) -> Bool {
        if delta == 0 { return true }
        var cur = parent[Int(id)]
        var hops = 0
        while cur >= 0 {
            fsize[Int(cur)] &+= delta
            cur = parent[Int(cur)]
            hops += 1; if hops > 4096 { return false } // cycle guard, mirrors _path (unreachable on real FS)
        }
        return true
    }

    /// [N2] defense-in-depth: explicitly resets the fsize triple. Caller holds the write lock
    /// (clear() and Snapshot.swift's load call this alongside their existing epoch bump — both
    /// paths already bumpEpochLocked(), so this is belt-and-suspenders, not a correctness
    /// dependency today; it guards against a future edit that drops the epoch bump).
    func resetFsizeLocked() {
        fsizeLock.lock(); fsizeEpoch = -1; fsizeAppliedSeq = -1; fsize.removeAll(keepingCapacity: false); fsizeLock.unlock()
    }

    /// Build (or refresh) the folder-size cache — call from a background queue.
    public func buildFolderSizes() { rdlock(); defer { unlock() }; _ = _folderSizes() }

    /// TEST-ONLY: the MAINTAINED folder-size array (incremental refresh or full rebuild, whichever
    /// `_folderSizes()` picks). NOTE: this ADVANCES `fsizeAppliedSeq` to the current log total just
    /// like any other caller — do not call it between reconciles you want to stay unpeeked-at when
    /// testing a multi-record replay window (see SPEC-B1-FINAL §6 [S4]).
    public func _debugFolderSizes() -> [Int64] { rdlock(); defer { unlock() }; return _folderSizes() }

    /// TEST-ONLY oracle: a from-scratch bottom-up pass over the CURRENT state, ignoring (and NOT
    /// touching) the fsize cache entirely. Mirrors `_folderSizes()`'s full-rebuild branch exactly.
    public func _debugFolderSizesScratch() -> [Int64] {
        rdlock(); defer { unlock() }
        let n = nameOff.count
        var out = [Int64](repeating: 0, count: n)
        var i = n - 1
        while i >= 0 {
            if !deleted[i] {
                let own = objType[i] == VNODE_VDIR ? out[i] : size[i]
                let p = parent[i]
                if p >= 0, Int(p) < n { out[Int(p)] &+= own }
            }
            i -= 1
        }
        return out
    }

    /// Non-blocking read for display: nil while the cache is stale (kick
    /// buildFolderSizes() off-main and re-render when it lands).
    public func folderSizeIfReady(_ i: Int) -> Int64? {
        rdlock(); defer { unlock() }
        let epoch = epochLocked, total = chgBase &+ chgIds.count
        fsizeLock.lock(); defer { fsizeLock.unlock() }
        guard fsizeEpoch == epoch, fsizeAppliedSeq == total, i >= 0, i < fsize.count else { return nil }
        return fsize[i]
    }

    /// Total size of everything inside a directory subtree — the "size" Finder shows
    /// for a package/bundle. Iterative DFS over children; hop-bounded for safety.
    public func subtreeSize(of dirIdx: Int32) -> Int64 {
        rdlock(); defer { unlock() }
        var total: Int64 = 0
        var stack: [Int32] = [dirIdx]
        var hops = 0
        while let cur = stack.popLast() {
            hops += 1; if hops > 20_000_000 { break }
            let i = Int(cur)
            if i < 0 || i >= objType.count || deleted[i] { continue }
            if objType[i] != VNODE_VDIR { total += size[i] }
            stack.append(contentsOf: childrenLocked(of: cur))
        }
        return total
    }

    /// The parent directory's absolute path (for display). Bounds-guarded (see isDir).
    public func directory(_ i: Int) -> String {
        rdlock(); defer { unlock() }
        guard i >= 0, i < parent.count else { return "" }
        let p = parent[i]
        return p < 0 ? _path(i) : _path(Int(p))
    }

    /// One locked snapshot of everything a result row / preview pane needs — so
    /// the main-thread renderer never subscripts the parallel arrays off-lock
    /// (which races the reconciler's appends → crash).
    public struct RowInfo: Sendable {
        public let name, path, directory, ext: String
        public let size, mtime, crtime: Int64
        public let isDir: Bool
        public let isLink: Bool
    }
    public func row(_ i: Int) -> RowInfo {
        rdlock(); defer { unlock() }
        guard i >= 0, i < nameOff.count else {
            return RowInfo(name: "", path: "", directory: "", ext: "", size: 0, mtime: 0, crtime: 0,
                           isDir: false, isLink: false)
        }
        let nm = _name(i)
        let p = _path(i)
        let dir = parent[i] < 0 ? p : _path(Int(parent[i]))
        return RowInfo(name: nm, path: p, directory: dir, ext: (nm as NSString).pathExtension,
                       size: size[i], mtime: mtime[i], crtime: crtime[i],
                       isDir: objType[i] == VNODE_VDIR, isLink: objType[i] == VNODE_VLNK)
    }

    /// Locked sum of file sizes for the given entries (directories excluded).
    public func totalSize(of ids: [Int32]) -> Int64 {
        rdlock(); defer { unlock() }
        var b: Int64 = 0
        for id in ids { let i = Int(id); if i >= 0, i < objType.count, objType[i] != VNODE_VDIR { b += size[i] } }
        return b
    }

    // MARK: - Live updates (the reconciler applies FSEvents-driven deltas here)

    /// Look up a directory entry by its display path (FSEvents path).
    func liveDirIndex(forDisplayPath p: String) -> Int32? {
        rdlock(); defer { unlock() }
        return _dirIndexVerified(p.precomposedStringWithCanonicalMapping)
    }

    /// Tombstone a mounted root (or any indexed directory subtree) by display path.
    /// Used when a volume disappears after launch; returns the number of live rows removed.
    @discardableResult
    public func markDeletedSubtree(displayPath rawPath: String) -> Int {
        wrlock(); defer { unlock() }
        let p = rawPath.precomposedStringWithCanonicalMapping
        guard let idx = _dirIndexVerified(p) else { return 0 }
        let removed = _markDeletedSubtree(idx)
        if removed > 0 { bumpMut() }
        return removed
    }

    /// Tombstone any CHILD-STUB copy of a mounted volume's path — an entry for the same
    /// display path indexed as a child of its parent dir (e.g. /Volumes) by a reconciler
    /// racing the mount — while keeping the appended ROOT copy (parent == -1). Re-points
    /// dirIndexByHash at the root copy. Returns rows tombstoned.
    @discardableResult
    public func tombstoneChildStubCopies(ofRootPath rawPath: String) -> Int {
        wrlock(); defer { unlock() }
        let p = rawPath.precomposedStringWithCanonicalMapping
        let parentPath = p.contains("/") && p != "/"
            ? (String(p[..<(p.lastIndex(of: "/")!)]).isEmpty ? "/" : String(p[..<(p.lastIndex(of: "/")!)]))
            : "/"
        let lastName = (p as NSString).lastPathComponent
        var removed = 0
        // The stub lives under the parent dir's children; the root copy has parent == -1.
        if let pi = _dirIndexVerified(parentPath) {
            for k in childrenLocked(of: pi) where !deleted[Int(k)] && objType[Int(k)] == VNODE_VDIR && _name(Int(k)) == lastName {
                removed += _markDeletedSubtree(k)
            }
        }
        // Ensure the path resolves to the surviving root copy for future reconciles.
        for i in 0..<parent.count where parent[i] == -1 && !deleted[i] && _name(i) == p {
            dirIndexByHash[pathHash(p)] = Int32(i)
            break
        }
        if removed > 0 { bumpMut() }
        return removed
    }

    /// Display paths of all live crawl roots (`parent == -1`, not tombstoned) — used to
    /// detect roots that vanished while the app was not running.
    public func liveRootPaths() -> [String] {
        rdlock(); defer { unlock() }
        var out: [String] = []
        for i in 0..<parent.count where parent[i] == -1 && !deleted[i] { out.append(_name(i)) }
        return out
    }

    /// Diffs a directory's freshly-listed children against the index and applies
    /// adds / removes / attribute updates atomically. Returns what changed.
    func applyDirDiff(dirIdx: Int32, displayPath: String, current: [DirEntry],
                      expectedEpoch: Int) -> ReconcileResult {
        wrlock(); defer { unlock() }
        var res = ReconcileResult()
        guard epochValue == expectedEpoch else { return res }   // stale reconcile from a prior crawl
        let di = Int(dirIdx)
        guard di < deleted.count, !deleted[di] else { return res }

        let oldIdxs = childrenLocked(of: dirIdx)   // slice; consumed into oldByName below before any mutation (R5)
        var oldByName = [String: Int32](minimumCapacity: oldIdxs.count)
        for ci in oldIdxs where !deleted[Int(ci)] { oldByName[_name(Int(ci))] = ci }

        // Append a fresh child entry, registering it as a dir (map + recurse) if applicable.
        func appendChild(_ c: DirEntry, _ nameStr: String) -> Int32 {
            let ni = _appendOne(parent: dirIdx, name: c.name, size: c.size,
                                mtime: c.mtime, crtime: c.crtime, objType: c.objType, flags: c.flags)
            if c.objType == VNODE_VDIR {
                let cp = displayPath == "/" ? "/" + nameStr : displayPath + "/" + nameStr
                dirIndexByHash[pathHash(cp)] = ni
                res.newDirs.append(LiveDir(idx: ni, path: cp))  // recurse into it
            }
            return ni
        }

        var newList = [Int32](); newList.reserveCapacity(current.count)
        for c in current {
            let nameStr = String(decoding: c.name, as: UTF8.self)
            if let oi = oldByName.removeValue(forKey: nameStr) {
                let o = Int(oi)
                if objType[o] != c.objType {
                    // Same name, but file<->dir flipped: an in-place attr update would leave a
                    // ghost dir (or an un-indexed new dir). Tombstone the old subtree and
                    // re-add so a new directory gets registered + recursed into.
                    _markDeletedSubtree(oi); res.removed += 1
                    newList.append(appendChild(c, nameStr)); res.added += 1
                } else {
                    // flags/hidden affect FILTERING (hidden, UF_HIDDEN) but never a sort key
                    // (name/path/size/mtime/crtime) — log an attr record only when a sort key
                    // actually changed, so a flags-only churn doesn't force an order rebuild.
                    let sortKeyChanged = size[o] != c.size || mtime[o] != c.mtime || crtime[o] != c.crtime
                    if sortKeyChanged || flags[o] != c.flags {
                        let sizeDelta = c.size &- size[o]                 // BEFORE the in-place write (OI-1)
                        size[o] = c.size; mtime[o] = c.mtime; crtime[o] = c.crtime; flags[o] = c.flags
                        hidden[o] = (c.name.first == UInt8(ascii: ".")) || (c.flags & UInt32(UF_HIDDEN)) != 0
                        res.changed += 1
                        if sortKeyChanged { logAttr(oi, sizeDelta) }      // delta may be 0 (mtime/crtime-only) — harmless
                    }
                    newList.append(oi)
                }
            } else {
                newList.append(appendChild(c, nameStr)); res.added += 1
            }
        }
        for (_, oi) in oldByName { _markDeletedSubtree(oi); res.removed += 1 }
        childOverlay[dirIdx] = newList
        if res.added + res.removed + res.changed > 0 { bumpMut() }   // auto-invalidate search caches
        return res
    }

    private func _appendOne(parent p: Int32, name: [UInt8], size s: Int64, mtime mt: Int64,
                            crtime ct: Int64, objType t: UInt8, flags f: UInt32) -> Int32 {
        let idx = Int32(nameOff.count)
        nameOff.append(UInt64(nameBlob.count)); nameLen.append(UInt16(name.count))
        nameBlob.append(contentsOf: name)
        for b in name { foldBlob.append(asciiLower(b)) }
        appendUnicodeFoldStorage(for: name, blob: &unicodeFoldBlob,
                                 off: &unicodeFoldOff, len: &unicodeFoldLen)
        parent.append(p); size.append(s); mtime.append(mt); crtime.append(ct); objType.append(t); flags.append(f)
        hidden.append((name.first == UInt8(ascii: ".")) || (f & UInt32(UF_HIDDEN)) != 0)
        deleted.append(false)
        // Reconcile-inserted (live FS change): compute the real mask now from the name's
        // fold + unicode-fold bytes so this entry is accelerated immediately (buildLiveIndexes
        // isn't re-run after reconcile). Both representations OR'd → no diacritic false-negative.
        var m = Self.maskOf(name.lazy.map(asciiLower))
        // ASCII names store noUnicodeFoldOffset (UInt64.max) — Int(UInt64.max) TRAPS,
        // so the sentinel check MUST gate the conversion (Codex review: crash on live
        // ASCII reconcile-insert). Non-ASCII names have a real unicode fold to OR in.
        if unicodeFoldOff[Int(idx)] != noUnicodeFoldOffset {
            let uo = Int(unicodeFoldOff[Int(idx)]), ul = Int(unicodeFoldLen[Int(idx)])
            m |= Self.maskOf(unicodeFoldBlob[uo..<uo+ul])
        }
        nameMask.append(m)
        // typeClass exact now too (no buildLiveIndexes after reconcile). Read the just-
        // appended fold bytes for this row from foldBlob (nameOff/nameLen apply to it).
        let fo = Int(nameOff[Int(idx)]), fl = Int(nameLen[Int(idx)])
        typeClass.append(foldBlob.withUnsafeBufferPointer {
            $0.baseAddress.map { FileTypeClass.mask(foldedName: $0, fo, fl) } ?? 0
        })
        // camelBits from the just-appended CASED name bytes (nameBlob), not foldBlob.
        camelBits.append(name.withUnsafeBufferPointer { Self.camelBitsOf($0.baseAddress!, 0, name.count) })
        logAppend(idx)   // every reconcile insert + the file↔dir-flip re-add (via appendChild)
        return idx
    }

    @discardableResult
    private func _markDeletedSubtree(_ idx: Int32) -> Int {
        var removed = 0
        var stack = [idx]
        while let cur = stack.popLast() {
            let c = Int(cur)
            if deleted[c] { continue }
            deleted[c] = true
            logTombstone(cur)   // sole deleted=true site: covers every deletion path (spec §1)
            removed += 1
            // Drop the hash→id mapping so it can't leak for the whole session on high churn
            // (e.g. repeatedly deleted node_modules/build dirs). Guard on identity so we never
            // remove a same-path entry that was just re-created (file→dir flip re-adds after this).
            if objType[c] == VNODE_VDIR {
                let h = pathHash(_path(c))
                if dirIndexByHash[h] == cur { dirIndexByHash.removeValue(forKey: h) }
            }
            let kids = childrenLocked(of: cur)
            if !kids.isEmpty { stack.append(contentsOf: kids) }
            childOverlay.removeValue(forKey: cur)   // read BEFORE removeValue; CSR slice inert for a deleted dir
        }
        _deletedCount += removed   // keep liveStats() O(1) (caller holds the write lock)
        return removed
    }
}

public struct DirEntry: Sendable {
    public let name: [UInt8]
    public let size: Int64
    public let mtime: Int64
    public let crtime: Int64
    public let objType: UInt8
    public let flags: UInt32
    public init(name: [UInt8], size: Int64, mtime: Int64, crtime: Int64, objType: UInt8, flags: UInt32) {
        self.name = name; self.size = size; self.mtime = mtime; self.crtime = crtime
        self.objType = objType; self.flags = flags
    }
}

public struct LiveDir: Sendable { public let idx: Int32; public let path: String }

public struct ReconcileResult: Sendable {
    public var added = 0, removed = 0, changed = 0
    public var newDirs: [LiveDir] = []
    public var didMutate: Bool { added + removed + changed > 0 }
}

// VNODE type constants (sys/vnode.h fsobj_type_t)
public let VNODE_VREG: UInt8 = 1
public let VNODE_VDIR: UInt8 = 2
public let VNODE_VLNK: UInt8 = 5   // symbolic link (crawled with NOFOLLOW)

let noUnicodeFoldOffset = UInt64.max
private let searchFoldLocale = Locale(identifier: "en_US_POSIX")

// FNV-1a 64 primitives for dirIndexByHash keys (streamed byte-by-byte so
// buildLiveIndexes can extend a parent dir's path hash without building strings).
private let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
private let fnvPrime: UInt64 = 0x100_0000_01b3
@inline(__always) private func fnvFeed(_ h: UInt64, _ b: UInt8) -> UInt64 {
    (h ^ UInt64(b)) &* fnvPrime
}

@inline(__always) private func checkedBlobOffset(_ local: UInt64, adding base: UInt64) -> UInt64 {
    let (offset, overflow) = local.addingReportingOverflow(base)
    if overflow { fatalError("Maverything name blob offset overflow") }
    return offset
}

@inline(__always) func asciiLower(_ b: UInt8) -> UInt8 {
    (b >= 65 && b <= 90) ? b &+ 32 : b
}

@inline(__always) func containsNonASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    for b in bytes where b >= 0x80 { return true }
    return false
}

func searchFoldedBytes(_ s: String) -> [UInt8] {
    let nfc = s.precomposedStringWithCanonicalMapping
    var ascii = true
    for b in nfc.utf8 where b >= 0x80 { ascii = false; break }
    if ascii { return Array(nfc.utf8).map(asciiLower) }
    let folded = nfc.folding(options: [.caseInsensitive, .diacriticInsensitive],
                             locale: searchFoldLocale)
        .precomposedStringWithCanonicalMapping
    return Array(folded.utf8)
}

func unicodeSearchFoldBytes(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
    let s = String(decoding: bytes, as: UTF8.self)
    return searchFoldedBytes(s)
}

func appendUnicodeFoldStorage(for bytes: [UInt8], blob: inout [UInt8],
                              off: inout [UInt64], len: inout [UInt32]) {
    bytes.withUnsafeBufferPointer { bp in
        appendUnicodeFoldStorage(for: bp, blob: &blob, off: &off, len: &len)
    }
}

func appendUnicodeFoldStorage(for bytes: UnsafeBufferPointer<UInt8>, blob: inout [UInt8],
                              off: inout [UInt64], len: inout [UInt32]) {
    guard containsNonASCII(bytes) else {
        off.append(noUnicodeFoldOffset)
        len.append(0)
        return
    }
    let folded = unicodeSearchFoldBytes(bytes)
    off.append(UInt64(blob.count))
    len.append(UInt32(folded.count))
    blob.append(contentsOf: folded)
}

/// Canonicalize a filename to NFC. macOS/APFS often returns decomposed (NFD)
/// bytes from getattrlistbulk, while users type composed (NFC) — without this,
/// non-ASCII (e.g. Korean/한글) searches silently miss. ASCII names skip the work.
@inline(__always) func canonicalNameBytes(_ buf: UnsafeBufferPointer<UInt8>) -> [UInt8] {
    for b in buf where b >= 0x80 {
        let s = String(decoding: buf, as: UTF8.self).precomposedStringWithCanonicalMapping
        return Array(s.utf8)
    }
    return Array(buf)
}
@inline(__always) func canonicalNameBytes(_ a: [UInt8]) -> [UInt8] {
    a.withUnsafeBufferPointer { canonicalNameBytes($0) }
}

/// A per-directory accumulation buffer, built thread-locally then appended once.
struct ChildBatch {
    var blob: [UInt8] = []
    var fold: [UInt8] = []
    var unicodeFoldBlob: [UInt8] = []
    var off: [UInt64] = []
    var len: [UInt16] = []
    var unicodeFoldOff: [UInt64] = []
    var unicodeFoldLen: [UInt32] = []
    var size: [Int64] = []
    var mtime: [Int64] = []
    var crtime: [Int64] = []
    var objType: [UInt8] = []
    var flags: [UInt32] = []
    var hidden: [Bool] = []
    var typeClass: [UInt8] = []   // media-category mask, computed here (parallel) not under the write lock
    var camelBits: [UInt64] = []  // [28] camelCase boundary bitmap, computed here from CASED nameBytes
    /// (localIndex, name) of child directories, to enqueue for further crawling.
    var subdirs: [(Int32, String)] = []

    mutating func add(nameBytes raw: UnsafeBufferPointer<UInt8>, size s: Int64, mtime mt: Int64,
                      crtime ct: Int64, objType t: UInt8, flags f: UInt32) {
        // ASCII fast path: no allocation. Non-ASCII: normalize to NFC once.
        var nonAscii = false
        for b in raw where b >= 0x80 { nonAscii = true; break }
        if nonAscii {
            let canon = canonicalNameBytes(raw)
            canon.withUnsafeBufferPointer { appendName($0, size: s, mtime: mt, crtime: ct, objType: t, flags: f) }
        } else {
            appendName(raw, size: s, mtime: mt, crtime: ct, objType: t, flags: f)
        }
    }

    private mutating func appendName(_ nameBytes: UnsafeBufferPointer<UInt8>, size s: Int64, mtime mt: Int64,
                                     crtime ct: Int64, objType t: UInt8, flags f: UInt32) {
        let localIdx = Int32(len.count)
        off.append(UInt64(blob.count))
        len.append(UInt16(nameBytes.count))
        blob.append(contentsOf: nameBytes)
        let foldStart = fold.count
        for b in nameBytes { fold.append(asciiLower(b)) }
        // typeClass computed HERE (parallel per-worker scan) instead of in appendChildren under
        // the exclusive index write lock — same exact folded bytes + rule, just off the lock.
        let tcMask = fold.withUnsafeBufferPointer {
            FileTypeClass.mask(foldedName: $0.baseAddress!, foldStart, nameBytes.count)
        }
        typeClass.append(tcMask)
        // cased (not folded) — camelCase detection needs the original case transition.
        camelBits.append(FileIndex.camelBitsOf(nameBytes.baseAddress!, 0, nameBytes.count))
        appendUnicodeFoldStorage(for: nameBytes, blob: &unicodeFoldBlob,
                                 off: &unicodeFoldOff, len: &unicodeFoldLen)
        size.append(s); mtime.append(mt); crtime.append(ct); objType.append(t); flags.append(f)
        let isHidden = (nameBytes.first == UInt8(ascii: ".")) || (f & UInt32(UF_HIDDEN)) != 0
        hidden.append(isHidden)
        if t == VNODE_VDIR {
            subdirs.append((localIdx, String(decoding: nameBytes, as: UTF8.self)))
        }
    }

    var isEmpty: Bool { len.isEmpty }
}
