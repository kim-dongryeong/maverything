import Foundation

/// [37] Tombstone-compaction threshold + hysteresis (SPEC-B5-FINAL §5, SF-2).
///
/// A reindex (snapshot save→load) already reclaims tombstoned rows (fresh crawl, `deleted=0`,
/// fresh ids, epoch bump) — this policy is only WHEN to trigger that reindex early, so RAM
/// doesn't accumulate dead rows indefinitely on high-churn trees (repeatedly deleted
/// node_modules/build dirs, etc). The pure predicate lives here (in MaverythingCore, not
/// inline in AppModel) so it's testable from mvsim, which imports only this module.
///
/// Hysteresis proof: a reindex ZEROES tombstones, so the only re-trigger path is (a)
/// re-accumulate ≥25% via real churn, AND (b) ≥10 min since the last compaction — UNLESS
/// tombstones already exceed the 40% hard cap, which fires regardless of cooldown (a session
/// must have added ≥40% dead weight — reindexing is correct regardless of timing). Oscillation
/// around 24-26% never re-triggers below 25%; the first cross triggers once, then cooldown
/// gates the next trigger to ≥10 minutes out — bounding reindex to ≤6/hour except the hard cap.
/// All comparisons are integer cross-multiplication (no float, no division) — exact at any scale.
public enum CompactionPolicy {
    public static let ratioNum = 1, ratioDen = 4          // 25%
    public static let hardNum  = 2, hardDen  = 5          // 40% escape hatch (ignores cooldown)
    public static let cooldown: TimeInterval = 600        // 10 min (OI-E)
    public static let minTotal = 50_000                   // below this, tombstone churn is noise

    public static func shouldCompact(total: Int, deleted: Int, now: TimeInterval, lastAt: TimeInterval) -> Bool {
        guard total > minTotal else { return false }
        let over25 = deleted * ratioDen > total * ratioNum
        let over40 = deleted * hardDen  > total * hardNum
        return over40 || (over25 && now - lastAt >= cooldown)
    }
}
