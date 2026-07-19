import Darwin
import Foundation

/// The matching strategies a search term can use. All three are built and
/// switchable at runtime — the user picks per the "build every option" rule.
public enum MatchMode: Int, Sendable, CaseIterable {
    case exact      // substring (Everything default) — fastest
    case fuzzy      // fzf/Sublime-style subsequence with scoring
    case wildcard   // glob: * and ? against the whole name (Everything wildcard)
    case regex      // full regular expression (NSRegularExpression); slower power mode

    /// What the app's mode pickers offer. Wildcard is NOT a mode in the UI —
    /// like Everything, it is always-on syntax (typing * or ? auto-engages glob
    /// matching in Exact). The case survives for the engine/CLI (mvfind
    /// --wildcard: bare term = whole-name match) and old persisted state.
    public static var uiModes: [MatchMode] { [.exact, .fuzzy, .regex] }

    public var label: String {
        switch self {
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        case .wildcard: return "Wildcard"
        case .regex: return "Regex"
        }
    }
}

/// Result of matching a single term against one candidate's bytes.
public struct MatchOutcome {
    public var matched: Bool
    public var score: Int     // higher = better (used for relevance ranking)
    public var position: Int  // byte offset of the match start (earlier = better)
    @inline(__always) public init(_ m: Bool, _ s: Int = 0, _ p: Int = Int.max) {
        matched = m; score = s; position = p
    }
    public static let no = MatchOutcome(false)
}

public enum Matcher {

    /// Dispatch one term (already ASCII-folded bytes) against a folded haystack.
    /// `camelBits` bit i set ⇔ cased-byte position i is a camelCase word start ([28]);
    /// 0 = separator-only (safe default — see FileIndex.camelBits doc).
    @inline(__always)
    public static func match(hay: UnsafePointer<UInt8>, hayLen: Int,
                             needle: UnsafePointer<UInt8>, needleLen: Int,
                             mode: MatchMode, camelBits: UInt64 = 0) -> MatchOutcome {
        if needleLen == 0 { return MatchOutcome(true, 0, 0) }
        switch mode {
        case .exact:    return exact(hay, hayLen, needle, needleLen, camelBits)
        case .fuzzy:    return fuzzy(hay, hayLen, needle, needleLen, camelBits)
        case .wildcard: return wildcard(hay, hayLen, needle, needleLen)
        case .regex:    return .no   // regex is handled by SearchEngine.regexSearch, not here
        }
    }

    // a byte position is a boundary if it's a separator boundary OR a camelCase word
    // start ([28]). `camelBits` is built from the CASED origin bytes but aligns 1:1
    // with the folded scan position (asciiLower is byte-length-preserving) — see
    // FileIndex.swift §2 coordinate-space note. Pass 0 for the Unicode-fold segment
    // and path-scope scans (no per-entry alignment there).
    @inline(__always)
    static func isBoundaryX(_ hay: UnsafePointer<UInt8>, _ i: Int, _ camelBits: UInt64) -> Bool {
        if isBoundary(hay, i) { return true }
        return i < 64 && (camelBits >> UInt64(i)) & 1 == 1
    }

    // MARK: exact substring (memmem)

    @inline(__always)
    static func exactScore(_ pos: Int, _ needleLen: Int, _ hayLen: Int, prefix: Bool, boundary: Bool) -> Int {
        var s = 1000 - min(pos, 900)
        if prefix { s += 150 } else if boundary { s += 60 }
        s += max(0, 40 - (hayLen - needleLen))
        return s
    }

    /// [22] bounded best-occurrence scan: the first hit is used unless it's interior AND
    /// a nearby boundary occurrence exists (≤4 extra probes, G5) — a boundary hit anywhere
    /// beats an interior hit, but we never scan unboundedly for one.
    @inline(__always)
    static func exact(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                      _ needle: UnsafePointer<UInt8>, _ needleLen: Int,
                      _ camelBits: UInt64 = 0) -> MatchOutcome {
        guard hayLen >= needleLen else { return .no }
        guard let hit = memmem(hay, hayLen, needle, needleLen) else { return .no }
        let pos = UnsafeRawPointer(hit) - UnsafeRawPointer(hay)
        if pos == 0 { return MatchOutcome(true, exactScore(pos, needleLen, hayLen, prefix: true, boundary: false), pos) }
        if isBoundaryX(hay, pos, camelBits) {
            return MatchOutcome(true, exactScore(pos, needleLen, hayLen, prefix: false, boundary: true), pos)
        }
        var best = exactScore(pos, needleLen, hayLen, prefix: false, boundary: false)   // interior floor
        var bestPos = pos
        var from = pos + 1, probes = 0
        while from + needleLen <= hayLen && probes < 4 {        // ≤4 extra memmem (bounded, G5)
            guard let h2 = memmem(hay + from, hayLen - from, needle, needleLen) else { break }
            let p2 = UnsafeRawPointer(h2) - UnsafeRawPointer(hay)
            if isBoundaryX(hay, p2, camelBits) {                // boundary occurrence found
                let s2 = exactScore(p2, needleLen, hayLen, prefix: false, boundary: true)
                if s2 > best { best = s2; bestPos = p2 }        // §1 proves s2 ≤1099 < any prefix
                break                                           // first boundary hit is enough
            }
            from = p2 + 1; probes += 1
        }
        return MatchOutcome(true, best, bestPos)
    }

    // MARK: fuzzy subsequence (greedy, boundary/consecutive-aware)

    @inline(__always)
    static func fuzzy(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                      _ needle: UnsafePointer<UInt8>, _ needleLen: Int,
                      _ camelBits: UInt64 = 0) -> MatchOutcome {
        var ni = 0, hi = 0
        var score = 0, firstPos = -1
        var prevMatchIdx = -2
        while hi < hayLen && ni < needleLen {
            if hay[hi] == needle[ni] {
                if firstPos < 0 { firstPos = hi }
                var bonus = 16
                if hi == prevMatchIdx + 1 { bonus += 12 }          // consecutive
                if hi == 0 || isBoundaryX(hay, hi, camelBits) { bonus += 18 }  // word boundary
                score += bonus
                prevMatchIdx = hi
                ni += 1
            }
            hi += 1
        }
        guard ni == needleLen else { return .no }
        score -= firstPos                                          // prefer early start
        score += max(0, 40 - (hayLen - needleLen))                // prefer tight match
        return MatchOutcome(true, max(score, 1), firstPos)
    }

    // MARK: [26] fuzzy DP — bounded affine-gap Smith-Waterman (fzf FuzzyMatchV2 model),
    // ranking-only refinement over the greedy existence match. See spec §4: M1's fzf
    // consecutive-inheritance rule (a run's bonus is the boundary strength of whichever
    // character STARTED the run, not a flat per-consecutive-char bonus) is THE fix that
    // keeps a tight prefix match (app.swift) outranking a fully-delimited scattered one
    // (a_p_p.txt).
    static let dpMatch: Int32 = 16
    // fzf-scale (agy cross-review): with gapStart −3 / gapExtend −1 a gap of g costs g+2, so 10
    // cancels a boundary at g≈8 — fzf's balance point. 18 doubled it, over-rewarding scattered
    // boundary matches (a_b_c) vs tight interior runs (xabc).
    static let dpBoundaryBonus: Int32 = 10
    static let dpConsecFloor: Int32 = 4
    static let dpGapStart: Int32 = -3
    static let dpGapExtend: Int32 = -1
    static let dpNegInf: Int32 = Int32.min / 4

    /// DP domain: caller must have a matching GREEDY outcome already (existence gate never
    /// changes) and pass fixed-capacity scratch rows (≥255, the path-scope/name-scope hay
    /// cap — S1). Outside `3 ≤ needleLen ≤ 32` or `hayLen ≤ 255`, returns `greedy` unchanged
    /// (fallback — S1: an unbounded DP width on 8192-byte path scratch would blow rows to
    /// 32×8192 ≈ 262k ops/candidate and overflow the 255-sized scratch).
    static func fuzzyDPRefine(hay: UnsafePointer<UInt8>, hayLen: Int,
                              needle: UnsafePointer<UInt8>, needleLen: Int,
                              camelBits: UInt64,
                              prev: UnsafeMutableBufferPointer<Int32>, curr: UnsafeMutableBufferPointer<Int32>,
                              prevStart: UnsafeMutableBufferPointer<Int32>, currStart: UnsafeMutableBufferPointer<Int32>,
                              prevRun: UnsafeMutableBufferPointer<Int32>, currRun: UnsafeMutableBufferPointer<Int32>,
                              greedy: MatchOutcome) -> MatchOutcome {
        guard needleLen >= 3, needleLen <= 32, hayLen <= 255, hayLen >= needleLen,
              hayLen <= prev.count else { return greedy }
        let h = hayLen, m = needleLen
        let NEG = dpNegInf
        var pv = prev, cv = curr, pvS = prevStart, cvS = currStart, pvR = prevRun, cvR = currRun
        for j in 0..<h { pv[j] = NEG; pvS[j] = -1; pvR[j] = 0 }
        for i in 0..<m {
            var run = NEG; var runStart: Int32 = -1
            for j in 0..<h {
                // fold prev[j-1] in as a gap-START candidate (≥1 hay char skipped before j)
                if i > 0, j >= 1, pv[j - 1] != NEG, pv[j - 1] + dpGapStart > run {
                    run = pv[j - 1] + dpGapStart; runStart = pvS[j - 1]   // gap path breaks the run
                }
                if hay[j] == needle[i] {
                    let pb: Int32 = isBoundaryX(hay, j, camelBits) ? dpBoundaryBonus : 0
                    var s = NEG; var st: Int32 = -1; var rb: Int32 = 0
                    if i == 0 {
                        // fzf bonusFirstCharMultiplier: how the term STARTS matters most; the
                        // run inherits the UNdoubled bonus (parity with fzf's consecutive rule).
                        s = dpMatch + pb &* 2; st = Int32(j); rb = pb
                    } else {
                        if j >= 1, pv[j - 1] != NEG {
                            // consecutive (diagonal, no gap): inherit the run's boundary bonus
                            let cb = max(pb, max(pvR[j - 1], dpConsecFloor))
                            let cand = pv[j - 1] + dpMatch + cb
                            if cand > s { s = cand; st = pvS[j - 1]; rb = max(pvR[j - 1], pb) }
                        }
                        if run != NEG {   // gapped (run just opened above): fresh run at this boundary
                            let cand = run + dpMatch + pb
                            if cand > s { s = cand; st = runStart; rb = pb }
                        }
                    }
                    if s != NEG { cv[j] = s; cvS[j] = st; cvR[j] = rb }
                    else { cv[j] = NEG; cvS[j] = -1; cvR[j] = 0 }
                } else {
                    cv[j] = NEG; cvS[j] = -1; cvR[j] = 0
                }
                if run != NEG { run += dpGapExtend }   // extend open gaps by one position
            }
            swap(&pv, &cv); swap(&pvS, &cvS); swap(&pvR, &cvR)
        }
        // best final alignment: maximize the RETURNED metric (raw − startPos), not raw alone —
        // an alignment with slightly lower raw but a much earlier start wins the final score
        // (Codex P1: argmax over raw discarded the true best before the penalty was applied).
        var bestFinal = NEG, bestJ = -1
        for j in 0..<h where pv[j] != NEG {
            let fin = pv[j] - pvS[j]
            if bestJ < 0 || fin > bestFinal { bestFinal = fin; bestJ = j }
        }
        guard bestJ >= 0 else { return greedy }
        let firstPos = Int(pvS[bestJ])
        var score = Int(pv[bestJ]) - firstPos                         // prefer early start (parity greedy)
        score += max(0, 40 - (hayLen - needleLen))                   // tightness (parity greedy)
        return MatchOutcome(true, max(score, 1), firstPos)
    }

    // MARK: wildcard / glob (anchored to whole name), * and ?

    @inline(__always)
    static func wildcard(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                         _ pat: UnsafePointer<UInt8>, _ patLen: Int) -> MatchOutcome {
        // classic two-pointer glob with backtracking on '*'
        let star = UInt8(ascii: "*"), q = UInt8(ascii: "?")
        var s = 0, p = 0, starP = -1, sTmp = 0
        while s < hayLen {
            if p < patLen && pat[p] == q {
                // `?` matches ONE character, not one byte: consume a full UTF-8 code point so
                // `?.txt` matches `가.txt` (3 bytes) as users expect for non-ASCII names.
                s += 1
                while s < hayLen && (hay[s] & 0xC0) == 0x80 { s += 1 }   // skip continuation bytes
                p += 1
            } else if p < patLen && pat[p] == hay[s] {
                s += 1; p += 1
            } else if p < patLen && pat[p] == star {
                starP = p; sTmp = s; p += 1
            } else if starP >= 0 {
                p = starP + 1; sTmp += 1; s = sTmp
            } else {
                return .no
            }
        }
        while p < patLen && pat[p] == star { p += 1 }
        // shorter names rank higher for relevance (positional score, not a constant)
        return p == patLen ? MatchOutcome(true, max(1, 700 - hayLen), 0) : .no
    }

    // MARK: whole-word exact (Everything's "Match Whole Word", ww:)

    /// Substring match where the hit must not be flanked by word characters —
    /// `report` matches "report.txt" but not "reporting_x.txt". Scans past
    /// non-word-boundary hits to later occurrences.
    @inline(__always)
    static func wholeWordExact(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                               _ needle: UnsafePointer<UInt8>, _ needleLen: Int) -> MatchOutcome {
        guard needleLen > 0, hayLen >= needleLen else { return .no }
        var from = 0
        while from + needleLen <= hayLen {
            guard let hit = memmem(hay + from, hayLen - from, needle, needleLen) else { return .no }
            let pos = UnsafeRawPointer(hit) - UnsafeRawPointer(hay)
            let beforeOK = pos == 0 || !isWordByte(hay[pos - 1])
            let afterOK = pos + needleLen == hayLen || !isWordByte(hay[pos + needleLen])
            if beforeOK && afterOK {
                var score = 1000 - min(pos, 900)
                if pos == 0 || isBoundary(hay, pos) { score += 80 }
                return MatchOutcome(true, score, pos)
            }
            from = pos + 1
        }
        return .no
    }

    /// ASCII letters/digits and any multi-byte UTF-8 unit count as word characters.
    @inline(__always)
    static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b >= 0x80
    }

    // a byte is a "word boundary start" if the preceding byte is a separator
    @inline(__always)
    static func isBoundary(_ hay: UnsafePointer<UInt8>, _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let c = hay[i - 1]
        return c == UInt8(ascii: "/") || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
            || c == UInt8(ascii: ".") || c == UInt8(ascii: " ")
    }
}
