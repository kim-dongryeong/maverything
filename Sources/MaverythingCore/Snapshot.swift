import Foundation

/// On-disk snapshot of the index — Everything's `Everything.db` equivalent.
/// The whole in-RAM struct-of-arrays is dumped as raw bytes so reload is a few
/// memcpys (~100 ms) instead of a 20 s crawl. The persisted FSEvents event id
/// lets us replay changes that happened while the app was closed.
public enum Snapshot {
    static let magic: UInt32 = 0x4D56_4931   // "MVI1"
    static let version: UInt32 = 5           // v5 widens nameOff to UInt64

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
        rdlock(); defer { unlock() }   // reads all arrays to serialize

        // Compact: drop tombstoned entries, remap indices.
        let n = nameOff.count
        var remap = [Int32](repeating: -1, count: n)
        var live = 0
        for i in 0..<n where !deleted[i] { remap[i] = Int32(live); live += 1 }

        var oNameOff = [UInt64](); oNameOff.reserveCapacity(live)
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
        var oUnicodeFoldBlob = [UInt8](); oUnicodeFoldBlob.reserveCapacity(unicodeFoldBlob.count)
        var oUnicodeFoldOff = [UInt64](); oUnicodeFoldOff.reserveCapacity(live)
        var oUnicodeFoldLen = [UInt32](); oUnicodeFoldLen.reserveCapacity(live)

        for i in 0..<n where !deleted[i] {
            let o = Int(nameOff[i]); let l = Int(nameLen[i])
            oNameOff.append(UInt64(oBlob.count)); oNameLen.append(UInt16(l))
            oBlob.append(contentsOf: nameBlob[o..<o+l])
            oFold.append(contentsOf: foldBlob[o..<o+l])
            if unicodeFoldOff[i] == noUnicodeFoldOffset {
                oUnicodeFoldOff.append(noUnicodeFoldOffset)
                oUnicodeFoldLen.append(0)
            } else {
                let uo = Int(unicodeFoldOff[i]); let ul = Int(unicodeFoldLen[i])
                oUnicodeFoldOff.append(UInt64(oUnicodeFoldBlob.count))
                oUnicodeFoldLen.append(UInt32(ul))
                oUnicodeFoldBlob.append(contentsOf: unicodeFoldBlob[uo..<uo+ul])
            }
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
        appendScalar(UInt64(oUnicodeFoldBlob.count), &d)
        appendArrayBytes(oBlob, &d)
        appendArrayBytes(oFold, &d)
        appendArrayBytes(oUnicodeFoldBlob, &d)
        appendArrayBytes(oNameOff, &d)
        appendArrayBytes(oNameLen, &d)
        appendArrayBytes(oUnicodeFoldOff, &d)
        appendArrayBytes(oUnicodeFoldLen, &d)
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
            guard raw.count >= 48 else { return nil }
            let m: UInt32 = readScalar(raw, &off)
            let v: UInt32 = readScalar(raw, &off)
            guard m == Snapshot.magic, (v == 4 || v == 5) else { return nil }
            let lastEventId: UInt64 = readScalar(raw, &off)
            let savedBits: UInt64 = readScalar(raw, &off)
            let countU: UInt64 = readScalar(raw, &off)
            let blobLenU: UInt64 = readScalar(raw, &off)
            let unicodeBlobLenU: UInt64 = readScalar(raw, &off)
            // Reject corrupt/truncated snapshots BEFORE any memcpy/allocation.
            guard countU <= 200_000_000,
                  blobLenU <= 8_000_000_000,
                  unicodeBlobLenU <= 8_000_000_000 else { return nil }
            let count = Int(countU), blobLen = Int(blobLenU), unicodeBlobLen = Int(unicodeBlobLenU)
            let nameOffSize = (v == 4) ? 4 : 8
            let perEntry = nameOffSize + 2 + 8 + 4 + 4 + 8 + 8 + 8 + 1 + 4 + 1   // arrays below, bytes/entry
            let expected = 48 + blobLen * 2 + unicodeBlobLen + count * perEntry
            guard raw.count >= expected else { return nil }   // falls back to a full crawl

            wrlock(); defer { unlock() }   // replaces all arrays
            bumpMutationLocked()           // new generation → search caches rebuild
            nameBlob = readArray(raw, &off, blobLen, UInt8.self)
            foldBlob = readArray(raw, &off, blobLen, UInt8.self)
            unicodeFoldBlob = readArray(raw, &off, unicodeBlobLen, UInt8.self)
            if v == 4 {
                let tempOff = readArray(raw, &off, count, UInt32.self)
                nameOff = tempOff.map { UInt64($0) }
            } else {
                nameOff = readArray(raw, &off, count, UInt64.self)
            }
            nameLen = readArray(raw, &off, count, UInt16.self)
            unicodeFoldOff = readArray(raw, &off, count, UInt64.self)
            unicodeFoldLen = readArray(raw, &off, count, UInt32.self)
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
                let uo = unicodeFoldOff[i]
                if uo == noUnicodeFoldOffset {
                    if unicodeFoldLen[i] != 0 { return nil }
                } else {
                    let ul = UInt64(unicodeFoldLen[i])
                    let uBlobLen = UInt64(unicodeBlobLen)
                    if uo > uBlobLen || ul > uBlobLen - uo { return nil }
                }
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
