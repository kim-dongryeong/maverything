import CoreServices
import Darwin
import Foundation

/// Real-time filesystem watcher — the macOS analog of Everything's USN-journal
/// poller. One FSEvents stream per watch root with file-level events; dirty
/// directories are handed to the `Reconciler`, which re-lists them with
/// getattrlistbulk and diffs against the index.
public final class FSWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "maverything.fsevents")
    // onBatch(dirtyPaths, mustReindexAll, batchMaxEventId)
    fileprivate var onBatch: (([String], Bool, UInt64) -> Void)?
    private let eventIdLock = NSLock()
    // The resume cursor we PERSIST. Critically it advances only when a batch's changes
    // have actually been APPLIED to the index (via markApplied), never merely on delivery —
    // otherwise a quit right after a burst would persist an id ahead of the index and
    // silently skip those events on the next launch.
    private var _appliedEventId: UInt64 = 0
    public var appliedEventId: UInt64 {
        eventIdLock.lock(); defer { eventIdLock.unlock() }; return _appliedEventId
    }
    /// Advance the persisted resume cursor after a reconcile batch has committed.
    public func markApplied(_ id: UInt64) {
        eventIdLock.lock(); if id > _appliedEventId { _appliedEventId = id }; eventIdLock.unlock()
    }

    public init() {}

    /// Start watching. `onBatch(dirtyPaths, mustScanAll, batchMaxId)` runs on a private
    /// queue. `sinceWhen` resumes from a persisted (already-applied) event id.
    public func start(paths: [String], latency: Double = 0.3,
                      sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow),
                      onBatch: @escaping ([String], Bool, UInt64) -> Void) {
        stop()
        self.onBatch = onBatch
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagWatchRoot
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, mvFSCallback, &ctx,
                                          paths as CFArray,
                                          FSEventStreamEventId(sinceWhen),
                                          latency, flags) else { return }
        stream = s
        // Resume cursor starts AT the resume point (everything up to it is already applied).
        // Only a brand-new watch (no persisted id) seeds from the current global id. We must
        // NOT fast-forward past `sinceWhen`, or the offline backlog being replayed would be
        // marked "seen" before it is reconciled.
        let isNew = sinceWhen == UInt64(kFSEventStreamEventIdSinceNow)
        eventIdLock.lock()
        _appliedEventId = isNew ? FSEventsGetCurrentEventId() : sinceWhen
        eventIdLock.unlock()
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    fileprivate func deliver(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>,
                             ids: UnsafePointer<FSEventStreamEventId>, count: Int) {
        var mustScanAll = false
        var batchMax: UInt64 = 0
        for i in 0..<count {
            let f = Int(flags[i])
            if f & (kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged) != 0 {
                mustScanAll = true
            }
            if ids[i] > batchMax { batchMax = ids[i] }
        }
        onBatch?(paths, mustScanAll, batchMax)
    }
}

private func mvFSCallback(stream: ConstFSEventStreamRef,
                          info: UnsafeMutableRawPointer?,
                          numEvents: Int,
                          eventPaths: UnsafeMutableRawPointer,
                          eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                          eventIds: UnsafePointer<FSEventStreamEventId>) {
    guard let info, numEvents > 0 else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
    let paths = (cfArray as NSArray).compactMap { $0 as? String }
    watcher.deliver(paths: paths, flags: eventFlags, ids: eventIds, count: numEvents)
}

/// Applies FSEvents-driven changes to the index by re-listing dirty directories.
public final class Reconciler: @unchecked Sendable {
    private let index: FileIndex
    private let exclude: [String]
    private let mountPoints: Set<String>   // other volumes' mounts — each is its OWN crawl root

    public init(index: FileIndex, exclude: [String], mountPoints: Set<String> = []) {
        self.index = index
        self.exclude = exclude
        self.mountPoints = mountPoints
    }

    /// Reconcile the dirty directories implied by these event paths. Returns the
    /// aggregate change set; `.didMutate` tells the caller whether to refresh.
    public func reconcile(eventPaths: [String]) -> ReconcileResult {
        let epoch = index.currentEpoch()   // if a reindex clears the index mid-reconcile, we no-op
        var work: [String] = []
        var seen = Set<String>()
        func enqueue(_ d: String) { if seen.insert(d).inserted { work.append(d) } }

        // FSEvents may deliver decomposed (NFD) paths, but the index stores NFC names and
        // keys dirIndexByPath by NFC — normalize so non-ASCII (e.g. 한글) dirs actually
        // resolve instead of silently failing the lookup (permanent drift otherwise).
        let normalized = eventPaths.map { $0.precomposedStringWithCanonicalMapping }
        for p in normalized where !isExcluded(p) {
            enqueue(parentDir(p))
            if index.liveDirIndex(forDisplayPath: p) != nil { enqueue(p) }
        }
        // process shallow dirs first so a newly-added parent registers its child
        // dirs before we try to descend into them
        work.sort { $0.utf8.count < $1.utf8.count }

        var total = ReconcileResult()
        var i = 0
        while i < work.count {
            let d = work[i]; i += 1
            if isExcluded(d) { continue }
            guard let di = index.liveDirIndex(forDisplayPath: d) else { continue }
            guard var current = FileEnumerator.listDirectory(d) else { continue } // vanished
            // A mount point re-listed as a child of its parent (e.g. /Volumes) must NOT be
            // re-added here — it's indexed as its own root, so drop it from the diff.
            if !mountPoints.isEmpty {
                current.removeAll { e in
                    let nm = String(decoding: e.name, as: UTF8.self)
                    let cp = d == "/" ? "/" + nm : d + "/" + nm
                    return mountPoints.contains(cp)
                }
            }
            let r = index.applyDirDiff(dirIdx: di, displayPath: d, current: current, expectedEpoch: epoch)
            total.added += r.added; total.removed += r.removed; total.changed += r.changed
            for nd in r.newDirs where !isExcluded(nd.path) {   // recurse into new subtrees
                if seen.insert(nd.path).inserted { work.append(nd.path) }
            }
        }
        return total
    }

    private func isExcluded(_ p: String) -> Bool {
        for e in exclude where p == e || p.hasPrefix(e + "/") { return true }
        return false
    }

    private func parentDir(_ p: String) -> String {
        if p == "/" { return "/" }
        if let i = p.lastIndex(of: "/") {
            let pre = p[..<i]
            return pre.isEmpty ? "/" : String(pre)
        }
        return "/"
    }
}
