import Foundation

/// Per-path "run history" — how many times the user opened a result and when
/// last (Everything's Run Count / Date Run, and the classic frecency signal).
/// It powers the `.runCount` sort (most-run-first) and boosts `.relevance` so a
/// file you open daily floats to the top. Path-keyed (not id-keyed): entry ids
/// change on every reindex, but the path is stable — the engine re-resolves
/// paths→ids per index generation. Thread-safe; persisted as JSON, debounced.
public final class RunStats: @unchecked Sendable {
    public struct Entry: Codable {
        public var count: Int32
        public var lastRun: TimeInterval   // seconds since 1970
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Bumped on every mutation so the engine's resolved-id cache knows to rebuild.
    private var _generation: Int = 0
    public var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    private let cap: Int
    private let halfLife: Double            // recency half-life in seconds (default 14 days)
    private let url: URL?
    private var saveScheduled = false
    private let saveDebounce: TimeInterval = 5

    public init(url: URL? = nil, cap: Int = 4096, halfLifeDays: Double = 14) {
        self.url = url
        self.cap = cap
        self.halfLife = halfLifeDays * 86_400
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Frecency = count × 2^(−age/halfLife). Monotone in count, decays with age —
    /// a file opened 100× a month ago can still outrank one opened twice today,
    /// which is the point (habitual files stay near the top). Both the static and
    /// instance forms funnel here so a non-default half-life can't make them disagree
    /// (completeness review F8).
    public static func frecency(count: Int32, lastRun: TimeInterval, now: TimeInterval,
                                halfLifeDays: Double = 14) -> Double {
        guard count > 0 else { return 0 }
        let age = max(0, now - lastRun)
        return Double(count) * pow(2.0, -age / (halfLifeDays * 86_400))
    }
    private func frecencyLocked(_ e: Entry, now: TimeInterval) -> Double {
        Self.frecency(count: e.count, lastRun: e.lastRun, now: now, halfLifeDays: halfLife / 86_400)
    }

    // MARK: - mutation

    /// Record that the user opened `path` (increments count, stamps lastRun).
    public func record(path: String, now: TimeInterval) {
        let key = path.precomposedStringWithCanonicalMapping   // match the index's NFC keys
        lock.lock()
        var e = entries[key] ?? Entry(count: 0, lastRun: now)
        e.count &+= 1
        e.lastRun = now
        entries[key] = e
        if entries.count > cap { pruneLocked(now: now) }
        _generation &+= 1
        lock.unlock()
        scheduleSave()
    }

    public func clear() {
        lock.lock(); entries.removeAll(); _generation &+= 1; lock.unlock()
        scheduleSave()
    }

    /// Drop the lowest-frecency entries back down to the cap (keeps the useful tail).
    private func pruneLocked(now: TimeInterval) {
        let overflow = entries.count - cap
        guard overflow > 0 else { return }
        let ranked = entries.map { ($0.key, frecencyLocked($0.value, now: now)) }
            .sorted { $0.1 < $1.1 }
        for (k, _) in ranked.prefix(overflow) { entries.removeValue(forKey: k) }
    }

    // MARK: - read

    /// Snapshot of every tracked path with its live frecency score (path → score).
    /// The engine resolves these paths to ids and caches by `generation`.
    public func scoredPaths(now: TimeInterval) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        var out = [String: Double](minimumCapacity: entries.count)
        for (k, e) in entries { out[k] = frecencyLocked(e, now: now) }
        return out
    }

    public func count(forPath path: String) -> Int32 {
        let key = path.precomposedStringWithCanonicalMapping
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.count ?? 0
    }

    public var trackedCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    // MARK: - persistence (debounced)

    private func scheduleSave() {
        guard url != nil else { return }
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + saveDebounce) { [weak self] in
            self?.flush()
        }
    }

    /// Write immediately (called by the debounce timer and on app teardown).
    public func flush() {
        guard let url else { return }
        lock.lock()
        saveScheduled = false
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
