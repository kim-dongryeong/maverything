import Darwin
import Foundation

/// Maverything's enumeration engine — the macOS analog of Everything reading the
/// NTFS MFT. Recursively walks one or more roots using `getattrlistbulk(2)` on a
/// worker pool, filling a `FileIndex`. Validated at ~80–120k entries/sec on
/// Apple Silicon (≈1M files in ~10s).
public final class FileEnumerator: @unchecked Sendable {

    // sys/attr.h bits (validated packed layout — see prototype/offsetcheck).
    private static let A_CMN_RETURNED_ATTRS: UInt32 = 0x8000_0000
    private static let A_CMN_NAME: UInt32    = 0x0000_0001
    private static let A_CMN_FSID: UInt32    = 0x0000_0004
    private static let A_CMN_OBJTYPE: UInt32 = 0x0000_0008
    private static let A_CMN_CRTIME: UInt32  = 0x0000_0200
    private static let A_CMN_MODTIME: UInt32 = 0x0000_0400
    private static let A_CMN_FLAGS: UInt32   = 0x0004_0000
    private static let A_CMN_FILEID: UInt32  = 0x0200_0000
    private static let A_FILE_DATALENGTH: UInt32 = 0x0000_0200
    private static let OPT_PACK_INVAL: UInt64 = 0x0000_0008
    private static let OPT_NOFOLLOW: UInt64    = 0x0000_0001

    // Tight-packed record field offsets (validated in prototype/offsetcheck).
    // len(4) returned(20) name@24 fsid@32 objtype@40 crtime@44 modtime@60
    // flags@76 fileid@80 datalen@88
    private static let OFF_NAMEREF = 24
    private static let OFF_FSID    = 32
    private static let OFF_OBJTYPE = 40
    private static let OFF_CRSEC   = 44
    private static let OFF_CRNSEC  = 52
    private static let OFF_MODSEC  = 60
    private static let OFF_MODNSEC = 68
    private static let OFF_FLAGS   = 76
    private static let OFF_FILEID  = 80
    private static let OFF_DATALEN = 88

    public struct Stats {
        public var files = 0
        public var dirs = 0
        public var openErrors = 0
        public var seconds = 0.0
        public var total: Int { files + dirs }
    }

    public let index: FileIndex
    private let workerCount: Int

    // shared work queue: (fsPath to open, displayPath, this dir's index, fsid guard or -1)
    private let cond = NSCondition()
    private var stack: [(String, String, Int32, Int64)] = []
    private var idle = 0
    private var done = false
    private var cancelledFlag = false
    private var stat = Stats()
    private var excludePrefixes: [String] = []
    private var mountPoints: Set<String> = []   // other volumes' mount points → don't descend

    /// Signals a running crawl to stop ASAP (workers drain and return).
    public func cancel() {
        cond.lock(); cancelledFlag = true; cond.broadcast(); cond.unlock()
    }
    public var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelledFlag }

    public init(index: FileIndex, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.index = index
        self.workerCount = max(1, workers)
    }

    /// Convenience: crawl plain paths (fsPath == displayPath).
    @discardableResult
    public func crawl(roots: [String], restrictToVolume: Bool = false,
                      exclude: [String] = [], mountPoints: Set<String> = []) -> Stats {
        crawl(roots: roots.map { CrawlRoot(fsPath: $0, displayPath: $0) },
              restrictToVolume: restrictToVolume, exclude: exclude, mountPoints: mountPoints)
    }

    /// Crawl the given roots. `restrictToVolume: true` refuses descent into
    /// directories on a different volume than the root (firmlink / nested mount
    /// guard for whole-disk crawls). `exclude` is a list of fs-path prefixes to
    /// not descend into (cloud storage etc.). Blocks until complete.
    @discardableResult
    public func crawl(roots: [CrawlRoot], restrictToVolume: Bool = false,
                      exclude: [String] = [], mountPoints: Set<String> = []) -> Stats {
        let clock = ContinuousClock()
        let start = clock.now
        excludePrefixes = exclude
        // Don't descend into mount points (each real volume is crawled as its own
        // root). A root's own fsPath is added directly, never via the child loop,
        // so keeping it in the set is harmless (children are always deeper).
        self.mountPoints = mountPoints

        for r in roots {
            let rootIdx = index.appendRoot(path: r.displayPath)
            let guardFsid = restrictToVolume ? fsidOf(path: r.fsPath) : -1
            stack.append((r.fsPath, r.displayPath, rootIdx, guardFsid))
        }
        stat.dirs += roots.count

        let threads = (0..<workerCount).map { i -> Thread in
            let t = Thread { [weak self] in self?.worker() }
            t.stackSize = 8 << 20
            t.name = "mv-crawl-\(i)"
            return t
        }
        threads.forEach { $0.start() }

        cond.lock()
        while !((done && stack.isEmpty) || cancelledFlag) { cond.wait() }
        cond.unlock()
        while !threads.allSatisfy({ $0.isFinished }) { Thread.sleep(forTimeInterval: 0.001) }  // yield, don't pin a core

        stat.seconds = secondsBetween(start, clock.now)
        return stat
    }

    public var stats: Stats { stat }

    // MARK: - Worker

    private func worker() {
        var local = Stats()
        let bufSize = 1 << 20   // 1 MB — fewer syscalls
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var attr = attrlist()
        attr.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attr.commonattr = Self.A_CMN_RETURNED_ATTRS | Self.A_CMN_NAME | Self.A_CMN_FSID
            | Self.A_CMN_OBJTYPE | Self.A_CMN_CRTIME | Self.A_CMN_MODTIME | Self.A_CMN_FLAGS | Self.A_CMN_FILEID
        attr.fileattr = Self.A_FILE_DATALENGTH
        let options = Self.OPT_PACK_INVAL | Self.OPT_NOFOLLOW

        cond.lock()
        while true {
            if cancelledFlag { break }
            if let job = stack.popLast() {
                cond.unlock()
                let (fsPath, displayPath, dirIdx, fsidGuard) = job
                var batch = ChildBatch()
                scan(dir: fsPath, guardFsid: fsidGuard, buf: buf, bufSize: bufSize,
                     attr: &attr, options: options, batch: &batch, local: &local)
                cond.lock()
                if !batch.isEmpty {
                    let base = index.appendChildren(parent: dirIdx, displayParent: displayPath, batch)
                    if !batch.subdirs.isEmpty {
                        var pushed = false
                        for (localIdx, name) in batch.subdirs {
                            let childFs = fsPath == "/" ? "/" + name : fsPath + "/" + name
                            if isExcluded(childFs) || mountPoints.contains(childFs) { continue }
                            let childDisp = displayPath == "/" ? "/" + name : displayPath + "/" + name
                            stack.append((childFs, childDisp, base + localIdx, fsidGuard))
                            pushed = true
                        }
                        if pushed { cond.broadcast() }
                    }
                }
                continue
            }
            idle += 1
            if idle == workerCount { done = true; cond.broadcast() }
            while stack.isEmpty && !done && !cancelledFlag { cond.wait() }
            idle -= 1
            if (done && stack.isEmpty) || cancelledFlag { break }
        }
        stat.files += local.files
        stat.dirs += local.dirs
        stat.openErrors += local.openErrors
        cond.unlock()
    }

    private func isExcluded(_ path: String) -> Bool {
        for p in excludePrefixes where path == p || path.hasPrefix(p + "/") { return true }
        return false
    }

    private func scan(dir: String, guardFsid: Int64, buf: UnsafeMutableRawPointer, bufSize: Int,
                      attr: inout attrlist, options: UInt64, batch: inout ChildBatch, local: inout Stats) {
        let fd = open(dir, O_RDONLY, 0)
        if fd < 0 { local.openErrors += 1; return }
        defer { close(fd) }

        while true {
            let count = withUnsafeMutablePointer(to: &attr) { alp in
                getattrlistbulk(fd, alp, buf, bufSize, options)
            }
            if count <= 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let entryLen = Int(p.loadUnaligned(fromByteOffset: 0, as: UInt32.self))

                if guardFsid >= 0 {
                    let v0 = p.loadUnaligned(fromByteOffset: Self.OFF_FSID, as: Int32.self)
                    let v1 = p.loadUnaligned(fromByteOffset: Self.OFF_FSID + 4, as: Int32.self)
                    let key = fsidKey(v0, v1)
                    if key != guardFsid { p = p + entryLen; continue }
                }

                let objType = UInt8(truncatingIfNeeded: p.loadUnaligned(fromByteOffset: Self.OFF_OBJTYPE, as: UInt32.self))
                let crSec = p.loadUnaligned(fromByteOffset: Self.OFF_CRSEC, as: Int64.self)
                let crNsec = p.loadUnaligned(fromByteOffset: Self.OFF_CRNSEC, as: Int64.self)
                let modSec = p.loadUnaligned(fromByteOffset: Self.OFF_MODSEC, as: Int64.self)
                let modNsec = p.loadUnaligned(fromByteOffset: Self.OFF_MODNSEC, as: Int64.self)
                let flags = p.loadUnaligned(fromByteOffset: Self.OFF_FLAGS, as: UInt32.self)
                let dataLen = p.loadUnaligned(fromByteOffset: Self.OFF_DATALEN, as: Int64.self)
                let nameOff = Int(p.loadUnaligned(fromByteOffset: Self.OFF_NAMEREF, as: Int32.self))
                let nameLen = Int(p.loadUnaligned(fromByteOffset: Self.OFF_NAMEREF + 4, as: UInt32.self))
                // attr_length includes the trailing NUL.
                let realLen = nameLen > 0 ? nameLen - 1 : 0
                let nameBase = (p + Self.OFF_NAMEREF + nameOff).assumingMemoryBound(to: UInt8.self)
                let nameBuf = UnsafeBufferPointer(start: nameBase, count: realLen)

                // A mounted volume is crawled as its OWN root, so don't also add it here as a
                // childless stub under its parent (that duplicates the entry and, via
                // dirIndexByPath last-write-wins, would orphan the real subtree).
                if objType == VNODE_VDIR, !mountPoints.isEmpty {
                    let childName = String(decoding: nameBuf, as: UTF8.self)
                    let childFs = dir == "/" ? "/" + childName : dir + "/" + childName
                    if mountPoints.contains(childFs) { p = p + entryLen; continue }
                }

                let mtime = modSec &* 1_000_000_000 &+ modNsec
                let crtime = crSec &* 1_000_000_000 &+ crNsec
                batch.add(nameBytes: nameBuf, size: dataLen, mtime: mtime, crtime: crtime,
                          objType: objType, flags: flags)
                if objType == VNODE_VDIR { local.dirs += 1 } else { local.files += 1 }

                p = p + entryLen
            }
        }
    }

    /// Lists a single directory's children (used by the live reconciler). Returns
    /// nil if the directory can't be opened (deleted / no permission).
    public static func listDirectory(_ path: String) -> [DirEntry]? {
        let fd = open(path, O_RDONLY, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        var attr = attrlist()
        attr.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attr.commonattr = A_CMN_RETURNED_ATTRS | A_CMN_NAME | A_CMN_FSID
            | A_CMN_OBJTYPE | A_CMN_CRTIME | A_CMN_MODTIME | A_CMN_FLAGS | A_CMN_FILEID
        attr.fileattr = A_FILE_DATALENGTH
        let options = OPT_PACK_INVAL | OPT_NOFOLLOW
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var out: [DirEntry] = []
        while true {
            let count = withUnsafeMutablePointer(to: &attr) { alp in
                getattrlistbulk(fd, alp, buf, bufSize, options)
            }
            if count <= 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<count {
                let entryLen = Int(p.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
                let objType = UInt8(truncatingIfNeeded: p.loadUnaligned(fromByteOffset: OFF_OBJTYPE, as: UInt32.self))
                let crSec = p.loadUnaligned(fromByteOffset: OFF_CRSEC, as: Int64.self)
                let crNsec = p.loadUnaligned(fromByteOffset: OFF_CRNSEC, as: Int64.self)
                let modSec = p.loadUnaligned(fromByteOffset: OFF_MODSEC, as: Int64.self)
                let modNsec = p.loadUnaligned(fromByteOffset: OFF_MODNSEC, as: Int64.self)
                let flags = p.loadUnaligned(fromByteOffset: OFF_FLAGS, as: UInt32.self)
                let dataLen = p.loadUnaligned(fromByteOffset: OFF_DATALEN, as: Int64.self)
                let nameOff = Int(p.loadUnaligned(fromByteOffset: OFF_NAMEREF, as: Int32.self))
                let nameLen = Int(p.loadUnaligned(fromByteOffset: OFF_NAMEREF + 4, as: UInt32.self))
                let realLen = nameLen > 0 ? nameLen - 1 : 0
                let nameBase = (p + OFF_NAMEREF + nameOff).assumingMemoryBound(to: UInt8.self)
                let nameBytes = canonicalNameBytes(UnsafeBufferPointer(start: nameBase, count: realLen))
                out.append(DirEntry(name: nameBytes, size: dataLen,
                                    mtime: modSec &* 1_000_000_000 &+ modNsec,
                                    crtime: crSec &* 1_000_000_000 &+ crNsec,
                                    objType: objType, flags: flags))
                p = p + entryLen
            }
        }
        return out
    }

    // MARK: - fsid helpers

    // Read the root's fsid via getattrlist — the SAME source as the per-entry
    // ATTR_CMN_FSID from getattrlistbulk, so the comparison is apples-to-apples.
    // (statfs's f_fsid uses a different representation and won't match.)
    private func fsidOf(path: String) -> Int64 {
        var attr = attrlist()
        attr.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attr.commonattr = Self.A_CMN_RETURNED_ATTRS | Self.A_CMN_FSID
        var buf = [UInt8](repeating: 0, count: 64)
        let rc = buf.withUnsafeMutableBytes { p -> Int32 in
            withUnsafeMutablePointer(to: &attr) { alp in
                getattrlist(path, alp, p.baseAddress, p.count, UInt32(Self.OPT_NOFOLLOW))
            }
        }
        guard rc == 0 else { return -1 }
        // layout: [u32 length][attribute_set_t returned (20)][fsid_t (8)]
        return buf.withUnsafeBytes { raw in
            let v0 = raw.loadUnaligned(fromByteOffset: 24, as: Int32.self)
            let v1 = raw.loadUnaligned(fromByteOffset: 28, as: Int32.self)
            return fsidKey(v0, v1)
        }
    }

    private func fsidKey(_ v0: Int32, _ v1: Int32) -> Int64 {
        (Int64(UInt32(bitPattern: v0)) << 32) | Int64(UInt32(bitPattern: v1))
    }
}

func secondsBetween(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant) -> Double {
    let d = a.duration(to: b)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
