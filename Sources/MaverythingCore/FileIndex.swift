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
    // childrenOf maps a directory entry to its child entry indices; dirIndexByPath
    // maps a directory's DISPLAY path to its entry index so FSEvents paths resolve.
    var childrenOf: [Int32: [Int32]] = [:]
    var dirIndexByPath: [String: Int32] = [:]

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
    deinit { pthread_rwlock_destroy(rwlock); rwlock.deallocate() }

    /// Bumped under the write lock on EVERY content mutation (append/delete/attr/clear/
    /// load). SearchEngine keys its order/narrowing caches off this, so a mutation can
    /// never leave a stale cache even if the engine's `invalidate()` is forgotten — the
    /// caches self-heal on the next search. Read only while holding the lock.
    private var _mutationGen = 0
    var mutationGenLocked: Int { _mutationGen }                       // caller already holds the lock
    @inline(__always) private func bumpMut() { _mutationGen &+= 1 }   // caller holds wrlock
    func bumpMutationLocked() { _mutationGen &+= 1 }                  // internal: Snapshot.swift, caller holds wrlock
    public func bumpMutation() { wrlock(); _mutationGen &+= 1; unlock() }   // external "refresh now"

    /// Bumped on every clear() so an in-flight reconcile from a previous crawl
    /// generation can detect it's stale and no-op instead of corrupting the fresh index.
    private var epochValue = 0
    public func currentEpoch() -> Int { rdlock(); defer { unlock() }; return epochValue }

    public init() {}

    public var count: Int { nameOff.count }

    /// Lock-safe count for live progress polling while a crawl is appending.
    public func safeCount() -> Int { rdlock(); defer { unlock() }; return nameOff.count }

    /// (total slots, tombstoned) — for deciding when to compact away dead entries.
    public func liveStats() -> (total: Int, deleted: Int) {
        rdlock(); defer { unlock() }
        var d = 0
        for x in deleted where x { d += 1 }
        return (nameOff.count, d)
    }

    // Locked (safe to call from the main thread while the reconciler mutates).
    @inline(__always) public func isDir(_ i: Int) -> Bool {
        rdlock(); defer { unlock() }; return objType[i] == VNODE_VDIR
    }
    @inline(__always) public func isDeleted(_ i: Int) -> Bool {
        rdlock(); defer { unlock() }; return deleted[i]
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
        parent.removeAll(keepingCapacity: false); size.removeAll(keepingCapacity: false)
        mtime.removeAll(keepingCapacity: false); crtime.removeAll(keepingCapacity: false)
        objType.removeAll(keepingCapacity: false)
        flags.removeAll(keepingCapacity: false); hidden.removeAll(keepingCapacity: false)
        deleted.removeAll(keepingCapacity: false)
        childrenOf.removeAll(keepingCapacity: false)
        dirIndexByPath.removeAll(keepingCapacity: false)
    }

    public func reserveCapacity(_ n: Int) {
        wrlock(); defer { unlock() }   // reallocation must not race a concurrent reader
        nameOff.reserveCapacity(n); nameLen.reserveCapacity(n)
        unicodeFoldOff.reserveCapacity(n); unicodeFoldLen.reserveCapacity(n)
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
        let idx = Int32(nameOff.count)
        nameOff.append(UInt64(nameBlob.count))
        nameLen.append(UInt16(bytes.count))
        nameBlob.append(contentsOf: bytes)
        foldBlob.append(contentsOf: bytes.map(asciiLower))
        appendUnicodeFoldStorage(for: bytes, blob: &unicodeFoldBlob,
                                 off: &unicodeFoldOff, len: &unicodeFoldLen)
        parent.append(-1)
        size.append(0); mtime.append(0); crtime.append(0)
        objType.append(VNODE_VDIR); flags.append(0); hidden.append(false); deleted.append(false)
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
        for o in batch.off { nameOff.append(o &+ blobBase) }
        nameLen.append(contentsOf: batch.len)
        for o in batch.unicodeFoldOff {
            unicodeFoldOff.append(o == noUnicodeFoldOffset ? o : o &+ unicodeBlobBase)
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
        return base
    }

    /// Builds the live-update maps (childrenOf, dirIndexByPath) in one O(n) pass
    /// after the crawl. Entries are appended parent-before-child, so a forward
    /// pass can compute each directory's display path from its parent's. This is
    /// far faster than doing it under the crawl lock.
    public func buildLiveIndexes() {
        wrlock(); defer { unlock() }
        let n = nameOff.count
        childrenOf.removeAll(keepingCapacity: true)
        dirIndexByPath.removeAll(keepingCapacity: true)
        var dirPath = [String?](repeating: nil, count: n)   // display path for dir entries
        for i in 0..<n {
            let p = parent[i]
            if p >= 0 { childrenOf[p, default: []].append(Int32(i)) }
            if objType[i] == VNODE_VDIR {
                let nm = _name(i)
                let path: String
                if p < 0 {
                    path = nm   // root: name IS the display path
                } else if let base = dirPath[Int(p)] {
                    path = base == "/" ? "/" + nm : base + "/" + nm
                } else {
                    path = nm   // shouldn't happen (parent dir precedes child)
                }
                dirPath[i] = path
                dirIndexByPath[path] = Int32(i)   // "/" roots collide; harmless
            }
        }
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

    /// The bare file/dir name of entry `i`.
    public func name(_ i: Int) -> String { rdlock(); defer { unlock() }; return _name(i) }

    /// Reconstructs the absolute path of entry `i` by walking parents.
    public func path(_ i: Int) -> String { rdlock(); defer { unlock() }; return _path(i) }

    /// Resolve a folder's absolute path to its entry index (for folder-scoped search).
    public func dirIndex(forPath p: String) -> Int32? {
        rdlock(); defer { unlock() }
        guard let i = dirIndexByPath[p], !deleted[Int(i)] else { return nil }
        return i
    }

    /// Total size of everything inside a directory subtree — the "size" Finder shows
    /// for a package/bundle. Iterative DFS over childrenOf; hop-bounded for safety.
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
            if let kids = childrenOf[cur] { stack.append(contentsOf: kids) }
        }
        return total
    }

    /// The parent directory's absolute path (for display).
    public func directory(_ i: Int) -> String {
        rdlock(); defer { unlock() }
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
    }
    public func row(_ i: Int) -> RowInfo {
        rdlock(); defer { unlock() }
        guard i >= 0, i < nameOff.count else {
            return RowInfo(name: "", path: "", directory: "", ext: "", size: 0, mtime: 0, crtime: 0, isDir: false)
        }
        let nm = _name(i)
        let p = _path(i)
        let dir = parent[i] < 0 ? p : _path(Int(parent[i]))
        return RowInfo(name: nm, path: p, directory: dir, ext: (nm as NSString).pathExtension,
                       size: size[i], mtime: mtime[i], crtime: crtime[i], isDir: objType[i] == VNODE_VDIR)
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
        guard let i = dirIndexByPath[p], !deleted[Int(i)] else { return nil }
        return i
    }

    /// Tombstone a mounted root (or any indexed directory subtree) by display path.
    /// Used when a volume disappears after launch; returns the number of live rows removed.
    @discardableResult
    public func markDeletedSubtree(displayPath rawPath: String) -> Int {
        wrlock(); defer { unlock() }
        let p = rawPath.precomposedStringWithCanonicalMapping
        guard let idx = dirIndexByPath[p], !deleted[Int(idx)] else { return 0 }
        let removed = _markDeletedSubtree(idx)
        if removed > 0 { bumpMut() }
        return removed
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

        let oldIdxs = childrenOf[dirIdx] ?? []
        var oldByName = [String: Int32](minimumCapacity: oldIdxs.count)
        for ci in oldIdxs where !deleted[Int(ci)] { oldByName[_name(Int(ci))] = ci }

        // Append a fresh child entry, registering it as a dir (map + recurse) if applicable.
        func appendChild(_ c: DirEntry, _ nameStr: String) -> Int32 {
            let ni = _appendOne(parent: dirIdx, name: c.name, size: c.size,
                                mtime: c.mtime, crtime: c.crtime, objType: c.objType, flags: c.flags)
            if c.objType == VNODE_VDIR {
                let cp = displayPath == "/" ? "/" + nameStr : displayPath + "/" + nameStr
                dirIndexByPath[cp] = ni
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
                    if size[o] != c.size || mtime[o] != c.mtime || crtime[o] != c.crtime || flags[o] != c.flags {
                        size[o] = c.size; mtime[o] = c.mtime; crtime[o] = c.crtime; flags[o] = c.flags
                        hidden[o] = (c.name.first == UInt8(ascii: ".")) || (c.flags & UInt32(UF_HIDDEN)) != 0
                        res.changed += 1
                    }
                    newList.append(oi)
                }
            } else {
                newList.append(appendChild(c, nameStr)); res.added += 1
            }
        }
        for (_, oi) in oldByName { _markDeletedSubtree(oi); res.removed += 1 }
        childrenOf[dirIdx] = newList
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
            removed += 1
            // Drop the path→id mapping so it can't leak for the whole session on high churn
            // (e.g. repeatedly deleted node_modules/build dirs). Guard on identity so we never
            // remove a same-path entry that was just re-created (file→dir flip re-adds after this).
            if objType[c] == VNODE_VDIR {
                let pth = _path(c)
                if dirIndexByPath[pth] == cur { dirIndexByPath.removeValue(forKey: pth) }
            }
            if let kids = childrenOf[cur] { stack.append(contentsOf: kids); childrenOf[cur] = nil }
        }
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
public let VNODE_VLNK: UInt8 = 5

let noUnicodeFoldOffset = UInt64.max
private let searchFoldLocale = Locale(identifier: "en_US_POSIX")

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
        for b in nameBytes { fold.append(asciiLower(b)) }
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
