import Foundation

/// On-disk snapshot of the index — Everything's `Everything.db` equivalent.
/// The whole in-RAM struct-of-arrays is dumped as raw bytes so reload is a few
/// memcpys (~100 ms) instead of a 20 s crawl. The persisted FSEvents event id
/// lets us replay changes that happened while the app was closed.
public enum Snapshot {
    static let magic: UInt32 = 0x4D56_4931   // "MVI1"
    static let version: UInt32 = 3           // v3 adds crtime (Date Created)

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Maverything", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("index.mvidx")
    }

    public struct Meta: Sendable { public var lastEventId: UInt64; public var savedAt: Double }
}

extension FileIndex {

    /// Serialize the live (non-tombstoned) index to a blob. Tombstones are
    /// compacted away on save so the file never accumulates garbage.
    public func snapshotData(lastEventId: UInt64, savedAt: Double) -> Data {
        lock.lock(); defer { lock.unlock() }

        // Compact: drop tombstoned entries, remap indices.
        let n = nameOff.count
        var remap = [Int32](repeating: -1, count: n)
        var live = 0
        for i in 0..<n where !deleted[i] { remap[i] = Int32(live); live += 1 }

        var oNameOff = [UInt32](); oNameOff.reserveCapacity(live)
        var oNameLen = [UInt16](); oNameLen.reserveCapacity(live)
        var oParent = [Int32](); oParent.reserveCapacity(live)
        var oSize = [Int64](); oSize.reserveCapacity(live)
        var oMtime = [Int64](); oMtime.reserveCapacity(live)
        var oCrtime = [Int64](); oCrtime.reserveCapacity(live)
        var oType = [UInt8](); oType.reserveCapacity(live)
        var oFlags = [UInt32](); oFlags.reserveCapacity(live)
        var oHidden = [UInt8](); oHidden.reserveCapacity(live)
        var oBlob = [UInt8](); oBlob.reserveCapacity(nameBlob.count)
        var oFold = [UInt8](); oFold.reserveCapacity(foldBlob.count)

        for i in 0..<n where !deleted[i] {
            let o = Int(nameOff[i]); let l = Int(nameLen[i])
            oNameOff.append(UInt32(oBlob.count)); oNameLen.append(UInt16(l))
            oBlob.append(contentsOf: nameBlob[o..<o+l])
            oFold.append(contentsOf: foldBlob[o..<o+l])
            let p = parent[i]
            oParent.append(p < 0 ? -1 : remap[Int(p)])
            oSize.append(size[i]); oMtime.append(mtime[i]); oCrtime.append(crtime[i])
            oType.append(objType[i]); oFlags.append(flags[i]); oHidden.append(hidden[i] ? 1 : 0)
        }

        var d = Data()
        appendScalar(Snapshot.magic, &d)
        appendScalar(Snapshot.version, &d)
        appendScalar(lastEventId, &d)
        appendScalar(savedAt.bitPattern, &d)
        appendScalar(UInt64(live), &d)
        appendScalar(UInt64(oBlob.count), &d)
        appendArrayBytes(oBlob, &d)
        appendArrayBytes(oFold, &d)
        appendArrayBytes(oNameOff, &d)
        appendArrayBytes(oNameLen, &d)
        appendArrayBytes(oParent, &d)
        appendArrayBytes(oSize, &d)
        appendArrayBytes(oMtime, &d)
        appendArrayBytes(oCrtime, &d)
        appendArrayBytes(oType, &d)
        appendArrayBytes(oFlags, &d)
        appendArrayBytes(oHidden, &d)
        return d
    }

    /// Replace this index's contents from a snapshot blob. Returns the metadata
    /// on success, nil if the blob is invalid/incompatible.
    public func loadSnapshot(_ data: Data) -> Snapshot.Meta? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Snapshot.Meta? in
            var off = 0
            guard raw.count >= 40 else { return nil }
            let m: UInt32 = readScalar(raw, &off)
            let v: UInt32 = readScalar(raw, &off)
            guard m == Snapshot.magic, v == Snapshot.version else { return nil }
            let lastEventId: UInt64 = readScalar(raw, &off)
            let savedBits: UInt64 = readScalar(raw, &off)
            let countU: UInt64 = readScalar(raw, &off)
            let blobLenU: UInt64 = readScalar(raw, &off)
            // Reject corrupt/truncated snapshots BEFORE any memcpy/allocation.
            guard countU <= 200_000_000, blobLenU <= 8_000_000_000 else { return nil }
            let count = Int(countU), blobLen = Int(blobLenU)
            let perEntry = 4 + 2 + 4 + 8 + 8 + 8 + 1 + 4 + 1   // arrays below, bytes/entry
            let expected = 40 + blobLen * 2 + count * perEntry
            guard raw.count >= expected else { return nil }   // falls back to a full crawl

            lock.lock(); defer { lock.unlock() }
            nameBlob = readArray(raw, &off, blobLen, UInt8.self)
            foldBlob = readArray(raw, &off, blobLen, UInt8.self)
            nameOff = readArray(raw, &off, count, UInt32.self)
            nameLen = readArray(raw, &off, count, UInt16.self)
            parent = readArray(raw, &off, count, Int32.self)
            size = readArray(raw, &off, count, Int64.self)
            mtime = readArray(raw, &off, count, Int64.self)
            crtime = readArray(raw, &off, count, Int64.self)
            objType = readArray(raw, &off, count, UInt8.self)
            flags = readArray(raw, &off, count, UInt32.self)
            let hid = readArray(raw, &off, count, UInt8.self)
            hidden = hid.map { $0 != 0 }
            deleted = [Bool](repeating: false, count: count)
            // Intra-file integrity: a valid-LENGTH but corrupt snapshot (bit rot) could hold
            // out-of-range name offsets or parent indices that would trap in _name/_path.
            // Verify in one pass; on any violation, reject → caller does a full crawl.
            for i in 0..<count {
                if Int(nameOff[i]) + Int(nameLen[i]) > blobLen { return nil }
                let par = parent[i]
                if par < -1 || Int(par) >= count { return nil }
            }
            childrenOf.removeAll(); dirIndexByPath.removeAll()
            return Snapshot.Meta(lastEventId: lastEventId, savedAt: Double(bitPattern: savedBits))
        }
    }
}

// MARK: - little binary helpers

private func appendScalar<T>(_ v: T, _ d: inout Data) {
    var x = v
    withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
}
private func appendArrayBytes<T>(_ a: [T], _ d: inout Data) {
    a.withUnsafeBytes { d.append(contentsOf: $0) }
}
private func readScalar<T>(_ raw: UnsafeRawBufferPointer, _ off: inout Int) -> T {
    let v = raw.loadUnaligned(fromByteOffset: off, as: T.self)
    off += MemoryLayout<T>.size
    return v
}
private func readArray<T>(_ raw: UnsafeRawBufferPointer, _ off: inout Int, _ count: Int, _: T.Type) -> [T] {
    let byteCount = count * MemoryLayout<T>.stride
    let arr = [T](unsafeUninitializedCapacity: count) { buf, initialized in
        if byteCount > 0 { memcpy(buf.baseAddress!, raw.baseAddress! + off, byteCount) }
        initialized = count
    }
    off += byteCount
    return arr
}
