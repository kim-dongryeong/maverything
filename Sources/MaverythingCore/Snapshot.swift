import Compression
import Foundation

/// On-disk snapshot of the index — Everything's `Everything.db` equivalent.
/// The whole in-RAM struct-of-arrays is dumped as raw bytes so reload is a few
/// memcpys (~100 ms) instead of a 20 s crawl. The persisted FSEvents event id
/// lets us replay changes that happened while the app was closed.
public enum Snapshot {
    static let magic: UInt32 = 0x4D56_4931   // "MVI1"
    static let version: UInt32 = 5           // v5 widens nameOff to UInt64
    /// Compressed-container magic ("MVZ1"): header = magic + rawSize(UInt64), then an
    /// LZFSE stream of the ordinary (v5) snapshot. Cardinal ships a 22 MB zstd snapshot
    /// for a whole disk vs our 167 MB raw — this closes most of that gap natively.
    static let zMagic: UInt32 = 0x4D56_5A31  // "MVZ1"

    static func compress(_ raw: Data) -> Data {
        var out = Data(capacity: raw.count / 3 + 64)
        withUnsafeBytes(of: zMagic) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(raw.count)) { out.append(contentsOf: $0) }
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: raw.count + 4096)
        defer { dst.deallocate() }
        let n = raw.withUnsafeBytes { src in
            compression_encode_buffer(dst, raw.count + 4096,
                                      src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                      nil, COMPRESSION_LZFSE)
        }
        guard n > 0 else { return raw }          // encode failure → fall back to raw
        out.append(dst, count: n)
        return out
    }

    static func decompressIfNeeded(_ data: Data) -> Data? {
        guard data.count >= 12 else { return data }
        let m = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard m == zMagic else { return data }   // not compressed → pass through
        let rawSize = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
        // Trust the header's rawSize ONLY within sane bounds before allocating it: a corrupt
        // or tampered snapshot could otherwise name a value up to 32 GB and OOM-kill the app
        // at launch (Codex). Cap by BOTH an absolute ceiling AND a decompression-ratio vs the
        // actual compressed payload — real LZFSE index data compresses a few ×, so a tiny file
        // claiming gigabytes is definitionally corrupt. (The decode below still verifies the
        // exact size; this only bounds the pre-decode allocation.) A generous 1000× + 1 MB
        // floor clears every legitimate snapshot with huge margin.
        let compressedPayload = UInt64(data.count - 12)
        let maxRaw = min(UInt64(32_000_000_000), compressedPayload &* 1000 &+ 1_000_000)
        guard rawSize > 0, rawSize <= maxRaw else { return nil }
        var raw = Data(count: Int(rawSize))
        let ok: Bool = raw.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                let payload = src.baseAddress! + 12
                let n = compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(rawSize),
                                                  payload.assumingMemoryBound(to: UInt8.self), data.count - 12,
                                                  nil, COMPRESSION_LZFSE)
                return n == Int(rawSize)
            }
        }
        return ok ? raw : nil                    // corrupt stream → reject (caller re-crawls)
    }

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
    public func snapshotData(lastEventId: UInt64, savedAt: Double, compress: Bool = true) -> Data {
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
        return compress ? Snapshot.compress(d) : d
    }

    /// Replace this index's contents from a snapshot blob. Returns the metadata
    /// on success, nil if the blob is invalid/incompatible.
    public func loadSnapshot(_ dataIn: Data) -> Snapshot.Meta? {
        guard let data = Snapshot.decompressIfNeeded(dataIn) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Snapshot.Meta? in
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

            let loadedNameBlob = readArray(raw, &off, blobLen, UInt8.self)
            let loadedFoldBlob = readArray(raw, &off, blobLen, UInt8.self)
            let loadedUnicodeFoldBlob = readArray(raw, &off, unicodeBlobLen, UInt8.self)
            let loadedNameOff: [UInt64]
            if v == 4 {
                let tempOff = readArray(raw, &off, count, UInt32.self)
                loadedNameOff = tempOff.map { UInt64($0) }
            } else {
                loadedNameOff = readArray(raw, &off, count, UInt64.self)
            }
            let loadedNameLen = readArray(raw, &off, count, UInt16.self)
            let loadedUnicodeFoldOff = readArray(raw, &off, count, UInt64.self)
            let loadedUnicodeFoldLen = readArray(raw, &off, count, UInt32.self)
            let loadedParent = readArray(raw, &off, count, Int32.self)
            let loadedSize = readArray(raw, &off, count, Int64.self)
            let loadedMtime = readArray(raw, &off, count, Int64.self)
            let loadedCrtime = readArray(raw, &off, count, Int64.self)
            let loadedObjType = readArray(raw, &off, count, UInt8.self)
            let loadedFlags = readArray(raw, &off, count, UInt32.self)
            let loadedHiddenBytes = readArray(raw, &off, count, UInt8.self)
            // Intra-file integrity: a valid-LENGTH but corrupt snapshot (bit rot) could hold
            // out-of-range name offsets or parent indices that would trap in _name/_path.
            // Verify in one pass; on any violation, reject → caller does a full crawl.
            let blobLen64 = UInt64(blobLen)
            let unicodeBlobLen64 = UInt64(unicodeBlobLen)
            for i in 0..<count {
                let nameOffset = loadedNameOff[i]
                let nameLength = UInt64(loadedNameLen[i])
                if nameOffset > blobLen64 || nameLength > blobLen64 - nameOffset { return nil }
                let uo = loadedUnicodeFoldOff[i]
                if uo == noUnicodeFoldOffset {
                    if loadedUnicodeFoldLen[i] != 0 { return nil }
                } else {
                    let ul = UInt64(loadedUnicodeFoldLen[i])
                    if uo > unicodeBlobLen64 || ul > unicodeBlobLen64 - uo { return nil }
                }
                let par = loadedParent[i]
                if par < -1 || Int(par) >= count { return nil }
            }

            wrlock(); defer { unlock() }   // replaces all arrays only after validation succeeds
            bumpMutationLocked()           // new generation → search caches rebuild
            nameBlob = loadedNameBlob
            foldBlob = loadedFoldBlob
            unicodeFoldBlob = loadedUnicodeFoldBlob
            nameOff = loadedNameOff
            nameLen = loadedNameLen
            unicodeFoldOff = loadedUnicodeFoldOff
            unicodeFoldLen = loadedUnicodeFoldLen
            parent = loadedParent
            size = loadedSize
            mtime = loadedMtime
            crtime = loadedCrtime
            objType = loadedObjType
            flags = loadedFlags
            hidden = loadedHiddenBytes.map { $0 != 0 }
            deleted = [Bool](repeating: false, count: count)
            // Mask/typeClass are never persisted (format-stable); the "match everything"
            // sentinels (.max / 0xFF) are a safe passthrough until the caller's
            // buildLiveIndexes() fills the authoritative values.
            nameMask = [UInt64](repeating: .max, count: count)
            typeClass = [UInt8](repeating: 0xFF, count: count)
            childrenOf.removeAll(); dirIndexByHash.removeAll()
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
