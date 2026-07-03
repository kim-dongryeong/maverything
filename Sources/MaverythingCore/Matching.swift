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
    @inline(__always)
    public static func match(hay: UnsafePointer<UInt8>, hayLen: Int,
                             needle: UnsafePointer<UInt8>, needleLen: Int,
                             mode: MatchMode) -> MatchOutcome {
        if needleLen == 0 { return MatchOutcome(true, 0, 0) }
        switch mode {
        case .exact:    return exact(hay, hayLen, needle, needleLen)
        case .fuzzy:    return fuzzy(hay, hayLen, needle, needleLen)
        case .wildcard: return wildcard(hay, hayLen, needle, needleLen)
        case .regex:    return .no   // regex is handled by SearchEngine.regexSearch, not here
        }
    }

    // MARK: exact substring (memmem)

    @inline(__always)
    static func exact(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                      _ needle: UnsafePointer<UInt8>, _ needleLen: Int) -> MatchOutcome {
        guard hayLen >= needleLen else { return .no }
        guard let hit = memmem(hay, hayLen, needle, needleLen) else { return .no }
        let pos = UnsafeRawPointer(hit) - UnsafeRawPointer(hay)
        // earlier match + boundary start scores higher
        var score = 1000 - min(pos, 900)
        if pos == 0 || isBoundary(hay, pos) { score += 80 }
        return MatchOutcome(true, score, pos)
    }

    // MARK: fuzzy subsequence (greedy, boundary/consecutive-aware)

    @inline(__always)
    static func fuzzy(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                      _ needle: UnsafePointer<UInt8>, _ needleLen: Int) -> MatchOutcome {
        var ni = 0, hi = 0
        var score = 0, firstPos = -1
        var prevMatchIdx = -2
        while hi < hayLen && ni < needleLen {
            if hay[hi] == needle[ni] {
                if firstPos < 0 { firstPos = hi }
                var bonus = 16
                if hi == prevMatchIdx + 1 { bonus += 12 }          // consecutive
                if hi == 0 || isBoundary(hay, hi) { bonus += 18 }  // word boundary
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

    // MARK: wildcard / glob (anchored to whole name), * and ?

    @inline(__always)
    static func wildcard(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                         _ pat: UnsafePointer<UInt8>, _ patLen: Int) -> MatchOutcome {
        // classic two-pointer glob with backtracking on '*'
        let star = UInt8(ascii: "*"), q = UInt8(ascii: "?")
        var s = 0, p = 0, starP = -1, sTmp = 0
        while s < hayLen {
            if p < patLen && (pat[p] == hay[s] || pat[p] == q) {
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
