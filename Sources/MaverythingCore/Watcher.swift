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
    fileprivate var onBatch: (([String], Bool) -> Void)?
    public private(set) var lastEventId: UInt64 = 0

    public init() {}

    /// Start watching. `onBatch(dirtyPaths, mustScanAll)` is called on a private
    /// queue. `sinceWhen` lets us resume from a persisted event id (M5).
    public func start(paths: [String], latency: Double = 0.3,
                      sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow),
                      onBatch: @escaping ([String], Bool) -> Void) {
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
        // Seed with the current global event id so a snapshot saved before any
        // event still records a valid, recent resume point (not 0 = replay-all).
        lastEventId = max(lastEventId, FSEventsGetCurrentEventId())
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
        for i in 0..<count {
            let f = Int(flags[i])
            if f & (kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped) != 0 {
                mustScanAll = true
            }
            if ids[i] > lastEventId { lastEventId = ids[i] }
        }
        onBatch?(paths, mustScanAll)
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

    public init(index: FileIndex, exclude: [String]) {
        self.index = index
        self.exclude = exclude
    }

    /// Reconcile the dirty directories implied by these event paths. Returns the
    /// aggregate change set; `.didMutate` tells the caller whether to refresh.
    public func reconcile(eventPaths: [String]) -> ReconcileResult {
        var work: [String] = []
        var seen = Set<String>()
        func enqueue(_ d: String) { if seen.insert(d).inserted { work.append(d) } }

        for p in eventPaths where !isExcluded(p) {
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
            guard let current = FileEnumerator.listDirectory(d) else { continue } // vanished
            let r = index.applyDirDiff(dirIdx: di, displayPath: d, current: current)
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
