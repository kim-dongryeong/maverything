import Foundation

/// Media "kind" categories (documents / images / audio / …), precomputed once per
/// file as a one-byte bitmask (`FileIndex.typeClass`) so the `type:` query operator
/// — and the app's type chips that emit it — filter by a single AND'd bit test in the
/// hot loop instead of re-scanning each candidate's extension against a list every query.
///
/// This is the SINGLE SOURCE OF TRUTH for what each category contains. Each category's
/// extension list is exactly the historical `ext:` clause the chips used, so by
/// construction `type:documents` ≡ `ext:pdf,doc,docx,…` (mvsim proves the equivalence).
/// Categories are NOT disjoint — e.g. `dmg`/`pkg` are both `archives` and `apps`, which
/// independent bits represent exactly.
public enum FileTypeClass {
    public static let documents: UInt8 = 1 << 0
    public static let images:    UInt8 = 1 << 1
    public static let audio:     UInt8 = 1 << 2
    public static let video:     UInt8 = 1 << 3
    public static let archives:  UInt8 = 1 << 4
    public static let apps:      UInt8 = 1 << 5
    // bits 6..7 are unused by real categories. 0xFF is the "unknown, not yet finalized"
    // sentinel (see FileIndex): it matches ANY `type:` mask, mirroring nameMask's .max —
    // a pre-build row can only cause a passing scan, never drop a real match.

    /// (name, bit, folded extensions without leading dot). Order fixed; append-only.
    public static let categories: [(name: String, mask: UInt8, exts: [String])] = [
        ("documents", documents, ["pdf","doc","docx","txt","rtf","pages","md","markdown","odt","tex","epub","xls","xlsx","csv","ppt","pptx","key","numbers"]),
        ("images",    images,    ["jpg","jpeg","png","gif","bmp","tiff","tif","heic","heif","webp","svg","raw","cr2","nef","arw","dng","psd","ico"]),
        ("audio",     audio,     ["mp3","wav","flac","aac","m4a","ogg","oga","aiff","aif","wma","alac","opus"]),
        ("video",     video,     ["mp4","mov","avi","mkv","wmv","flv","webm","m4v","mpg","mpeg","3gp","m2ts","mts"]),
        ("archives",  archives,  ["zip","rar","7z","tar","gz","tgz","bz2","xz","dmg","iso","pkg","cab"]),
        ("apps",      apps,      ["app","pkg","dmg","exe"]),
    ]

    /// Every category extension fits in 8 bytes ("markdown" is the longest at 8), so an
    /// extension can be packed little-endian into a UInt64 for an allocation-free lookup.
    /// Anything longer than 8 bytes cannot belong to a category → mask 0.
    static let maxExtLen = 8

    /// packed folded-ext bytes → category bitmask.
    static let byPackedExt: [UInt64: UInt8] = {
        var m: [UInt64: UInt8] = [:]
        for c in categories {
            for e in c.exts {
                let bytes = Array(e.utf8)   // the lists are already lowercase/ASCII
                precondition(bytes.count <= maxExtLen, "category ext '\(e)' exceeds \(maxExtLen) bytes")
                var key: UInt64 = 0
                for (j, b) in bytes.enumerated() { key |= UInt64(b) << (8 * j) }
                m[key, default: 0] |= c.mask
            }
        }
        return m
    }()

    /// Resolve a `type:` operand (`documents`, or a comma list `documents,images`) to the
    /// OR of its category bits. Unknown names contribute nothing; an operand naming no
    /// known category yields 0 (matches nothing) — the caller decides how to treat that.
    public static func maskForOperand(_ operand: String) -> UInt8 {
        var out: UInt8 = 0
        for part in operand.split(separator: ",") {
            let key = part.trimmingCharacters(in: .whitespaces).lowercased()
            for c in categories where c.name == key { out |= c.mask }
        }
        return out
    }

    /// The category bitmask for one entry, read from its ASCII-FOLDED name bytes. Uses
    /// the exact same "bytes after the last dot" rule as `SearchEngine.extMatches`, so a
    /// `type:` filter and the equivalent `ext:` clause select the identical set.
    @inline(__always)
    public static func mask(foldedName base: UnsafePointer<UInt8>, _ o: Int, _ l: Int) -> UInt8 {
        var dot = -1
        var i = l - 1
        while i >= 0 { if base[o + i] == UInt8(ascii: ".") { dot = i; break }; i -= 1 }
        guard dot >= 0 else { return 0 }
        let extLen = l - dot - 1
        guard extLen >= 1, extLen <= maxExtLen else { return 0 }
        let s = o + dot + 1
        var key: UInt64 = 0
        for j in 0..<extLen { key |= UInt64(base[s + j]) << (8 * j) }
        return byPackedExt[key] ?? 0
    }
}
