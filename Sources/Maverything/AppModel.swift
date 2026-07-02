import AppKit
import Combine
import CoreServices
import Foundation
import MaverythingCore

/// Lightweight file logger so we can verify the in-app engine pipeline headlessly.
enum Diag {
    static let path = NSHomeDirectory() + "/dev/maverything/maverything-diag.log"
    static func log(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Holds the result rows outside of `@Published` so SwiftUI never diffs a
/// 100k-element array. The table reads this directly; `AppModel.resultsVersion`
/// is the cheap signal that tells the table to `reloadData()`.
final class ResultsStore {
    var ids: [Int32] = []
    var index: FileIndex!
}

/// Everything-style quick type filters. Each maps to a query clause that is
/// AND-ed with whatever the user has typed (see `AppModel.effectiveQuery`).
enum TypeFilter: String, CaseIterable, Identifiable {
    case all, folders, documents, images, audio, video, archives, apps
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All";             case .folders: return "Folders"
        case .documents: return "Documents"; case .images: return "Images"
        case .audio: return "Audio";         case .video: return "Video"
        case .archives: return "Archives";   case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2";  case .folders: return "folder"
        case .documents: return "doc.text";   case .images: return "photo"
        case .audio: return "music.note";     case .video: return "film"
        case .archives: return "archivebox";  case .apps: return "app.badge"
        }
    }

    /// The query fragment this filter contributes (empty for `.all`).
    var clause: String {
        switch self {
        case .all:       return ""
        case .folders:   return "folder:"
        case .documents: return "ext:pdf,doc,docx,txt,rtf,pages,md,markdown,odt,tex,epub,xls,xlsx,csv,ppt,pptx,key,numbers"
        case .images:    return "ext:jpg,jpeg,png,gif,bmp,tiff,tif,heic,heif,webp,svg,raw,cr2,nef,arw,dng,psd,ico"
        case .audio:     return "ext:mp3,wav,flac,aac,m4a,ogg,oga,aiff,aif,wma,alac,opus"
        case .video:     return "ext:mp4,mov,avi,mkv,wmv,flv,webm,m4v,mpg,mpeg,3gp,m2ts,mts"
        case .archives:  return "ext:zip,rar,7z,tar,gz,tgz,bz2,xz,dmg,iso,pkg,cab"
        case .apps:      return "ext:app,pkg,dmg,exe"
        }
    }
}

/// A user-saved search: the query plus the modes it was captured with.
struct SavedSearch: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var query: String
    var matchMode: Int
    var typeFilter: String
    var scope: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var statusText = "Starting…"
    @Published var resultTotal = 0
    @Published var resultShown = 0          // rows actually returned (may be capped below resultTotal)
    @Published var indexedCount = 0
    @Published var queryMillis = 0.0
    @Published var resultsVersion = 0
    @Published var queryNonce = 0          // bumps only on a NEW query (not live refresh)
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var scope: SearchScope = .nameOnly
    @Published var matchMode: MatchMode = .exact
    @Published var typeFilter: TypeFilter = .all   // Everything-style quick type chips
    @Published var recentQueries: [String] = AppModel.loadRecents()
    @Published var savedSearches: [SavedSearch] = AppModel.loadSaved()
    @Published var scopeRoot: String? = nil        // "Search in This Folder" — restrict to a subtree
    @Published var isIndexing = true
    @Published var hasFullDiskAccess = true
    @Published var showOnboarding = false
    @Published var includeCloud = false        // index ~/Library/CloudStorage etc.
    @Published var showHidden = true            // Everything-style: show everything
    @Published var enterRenames: Bool = UserDefaults.standard.bool(forKey: "mv.enterRenames") {
        didSet { UserDefaults.standard.set(enterRenames, forKey: "mv.enterRenames") }
    }
    @Published var focusNonce = 0              // bumped to refocus the search field
    @Published var focusResultsNonce = 0       // bumped to move focus into the results list
    @Published var selectedID: Int32? = nil    // current selection (for the preview pane)
    @Published var selectionCount = 0
    @Published var selectionBytes: Int64 = 0
    @Published var layout: UILayout = UILayout(rawValue:
        UserDefaults.standard.string(forKey: "mv.layout") ?? "") ?? .table {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "mv.layout") }
    }
    @Published var appearance: Appearance = Appearance(rawValue:
        UserDefaults.standard.string(forKey: "mv.appearance") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "mv.appearance") }
    }
    @Published var density: RowDensity = RowDensity(rawValue:
        UserDefaults.standard.string(forKey: "mv.density") ?? "") ?? .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "mv.density") }
    }

    /// Set by the AppDelegate so the search UI can dismiss the panel (ESC).
    var requestHide: (() -> Void)?

    let index = FileIndex()
    lazy var engine = SearchEngine(index: index)
    let resultsStore = ResultsStore()

    private var cancellables = Set<AnyCancellable>()
    private let searchQueue = DispatchQueue(label: "maverything.search", qos: .userInteractive)
    private let indexQueue = DispatchQueue(label: "maverything.index", qos: .userInitiated)
    private var searchSeq = 0
    private let seqLock = NSLock()   // guards searchSeq so the search queue can pre-check staleness
    private func nextSearchSeq() -> Int { seqLock.lock(); searchSeq &+= 1; let v = searchSeq; seqLock.unlock(); return v }
    private func currentSearchSeq() -> Int { seqLock.lock(); defer { seqLock.unlock() }; return searchSeq }
    private var started = false
    private var currentEnumerator: FileEnumerator?
    private var indexGen = 0
    private let watcher = FSWatcher()
    private var reconciler: Reconciler?
    private let reconcileQueue = DispatchQueue(label: "maverything.reconcile", qos: .utility)
    private var watchedRoots: [CrawlRoot] = []
    private var volumeRefreshInFlight = false
    private var pendingVolumeRefresh = false

    init() {
        resultsStore.index = index

        $query
            .debounce(for: .milliseconds(35), scheduler: DispatchQueue.main)  // fires during window tracking too
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                // if the user edited away from a cycled history entry, drop the cursor
                if self.historyCursor >= 0, self.historyCursor < self.recentQueries.count,
                   self.query != self.recentQueries[self.historyCursor] {
                    self.historyCursor = -1
                }
                self.queryNonce &+= 1; self.runSearch()
            }
            .store(in: &cancellables)

        Publishers.Merge6(
            $sortKey.map { _ in () },
            $ascending.map { _ in () },
            $scope.map { _ in () },
            $matchMode.map { _ in () },
            $typeFilter.map { _ in () },
            $scopeRoot.map { _ in () }
        )
        .dropFirst()
        .sink { [weak self] in self?.queryNonce &+= 1; self?.runSearch() }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.saveSnapshot(sync: true)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification, object: nil)
    }

    private var progressTimer: Timer?

    /// Path prefixes to skip. Cloud File Providers are excluded unless the user
    /// opts in; the autofs home map is always skipped.
    private func currentExclusions() -> [String] {
        // always skip our own snapshot dir + autofs; cloud only when not opted in
        if includeCloud { return Volumes.alwaysExclusions() }
        return Volumes.defaultExclusions()
    }

    func start() {
        guard !started else { return }
        started = true

        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        showOnboarding = !hasFullDiskAccess
        startPeriodicSave()
        if !loadFromSnapshot() { beginIndexing() }
    }

    /// Fast path: reload the last snapshot (~100 ms) and resume live updates from
    /// the persisted FSEvents id, instead of a full crawl.
    private func loadFromSnapshot() -> Bool {
        let url = Snapshot.defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        isIndexing = true
        statusText = "Loading saved index…"
        let gen = indexGen
        indexQueue.async { [weak self] in
            guard let self else { return }
            guard let data = try? Data(contentsOf: url), let meta = self.index.loadSnapshot(data) else {
                DispatchQueue.main.async { if gen == self.indexGen { self.beginIndexing() } }
                return
            }
            self.index.buildLiveIndexes()
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }
                self.isIndexing = false
                self.indexedCount = self.index.count
                self.statusText = "Loaded \(self.index.count.formatted()) items · resuming…"
                self.engine.invalidate()
                self.prewarmAndSearch()
                Diag.log("LOADED snapshot \(self.index.count) items, resume@\(meta.lastEventId)")
                let roots = Volumes.localCrawlRoots()
                // Roots that were in the snapshot but are NO LONGER mounted would otherwise
                // survive forever (the sync only diffs against currently-watched roots).
                let mountedNow = Set(roots.map(\.displayPath))
                for rp in self.index.liveRootPaths() where !mountedNow.contains(rp) {
                    let n = self.index.markDeletedSubtree(displayPath: rp)
                    Diag.log("snapshot root '\(rp)' no longer mounted → tombstoned \(n) rows")
                }
                let indexedRoots = roots.filter { self.index.dirIndex(forPath: $0.displayPath) != nil }
                self.startWatching(roots: indexedRoots,
                                   exclude: self.currentExclusions(),
                                   sinceWhen: meta.lastEventId)
                self.refreshMountedVolumes(reason: "snapshot root sync")
                // Correctness guard: FSEvents only retains a few days of history, so if we
                // were offline longer than that, the resume above may have missed changes.
                // Rather than blindly re-index on a timer (like some rivals), re-index ONLY
                // when the snapshot is old enough that the resume can't be trusted.
                let offline = Date().timeIntervalSince1970 - meta.savedAt
                if offline > Self.staleResumeSeconds {
                    Diag.log("snapshot stale by \(Int(offline))s (> trust window) → reindex for correctness")
                    self.beginIndexing()
                }
            }
        }
        return true
    }

    /// Offline gap beyond which a snapshot resume is considered unsafe (FSEvents history
    /// is finite) and we do a fresh crawl on launch to guarantee the index is correct.
    private static let staleResumeSeconds: Double = 3 * 24 * 3600   // 3 days

    /// (Re)start a whole-disk crawl across all local volumes. Safe to call while
    /// a crawl is running: the previous crawl is cancelled and superseded.
    func beginIndexing() {
        indexGen += 1
        let gen = indexGen
        watcher.stop()                  // pause live updates during (re)index
        currentEnumerator?.cancel()     // abort any in-flight crawl fast
        isIndexing = true
        indexedCount = 0
        // A reindex rebuilds the index from scratch, so every row id currently in the
        // result set points at the OLD generation. Invalidate them now so nothing maps
        // stale ids against the cleared/rebuilding arrays (Copy All Paths crash, wrong
        // CSV rows), and bump queryNonce so the post-reindex search is treated as a NEW
        // query — the table then drops the old (now-meaningless) selection instead of
        // re-selecting by numeric id.
        resultsStore.ids = []
        resultShown = 0
        resultTotal = 0
        queryNonce &+= 1
        statusText = "Indexing all local volumes…"

        let roots = Volumes.localCrawlRoots()
        let exclude = currentExclusions()
        Diag.log("crawl[\(gen)] roots: \(roots.map { "\($0.fsPath)→\($0.displayPath)" }.joined(separator: ", "))  FDA=\(hasFullDiskAccess) cloud=\(includeCloud)")

        progressTimer?.invalidate()
        var ticks = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.indexedCount = self.index.safeCount()
            self.statusText = "Indexing… \(self.indexedCount.formatted()) items"
            ticks += 1
            if ticks % 8 == 0 { Diag.log("…progress \(self.indexedCount) items") }
        }

        // Serial queue guarantees the previous crawl's worker threads have fully
        // exited (crawl() joins them) before we clear + start the next one.
        indexQueue.async { [weak self] in
            guard let self else { return }
            let en = FileEnumerator(index: self.index)
            let proceed: Bool = DispatchQueue.main.sync {
                guard gen == self.indexGen else { return false }
                self.index.clear()
                self.index.reserveCapacity(3_000_000)
                self.currentEnumerator = en
                return true
            }
            guard proceed else { return }   // superseded before we started — don't run the crawl
            // Capture the FSEvents cursor BEFORE crawling so changes made during the
            // crawl are replayed once the stream starts (not lost).
            let sinceId = FSEventsGetCurrentEventId()
            let stats = en.crawl(roots: roots, restrictToVolume: false, exclude: exclude,
                                 mountPoints: Volumes.allMountPoints())
            if en.isCancelled { return }                     // superseded; skip extra work
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }
                self.statusText = "Preparing live updates…"
            }
            self.index.buildLiveIndexes()                    // O(n), enables the reconciler
            DispatchQueue.main.async {
                guard gen == self.indexGen else { return }   // superseded by a newer crawl
                self.currentEnumerator = nil
                self.progressTimer?.invalidate(); self.progressTimer = nil
                self.isIndexing = false
                self.indexedCount = self.index.count
                self.statusText = String(format: "Indexed %@ items in %.1fs",
                                         self.index.count.formatted(), stats.seconds)
                self.engine.invalidate()
                Diag.log("DONE[\(gen)] indexed \(self.index.count) items in \(stats.seconds)s (\(stats.openErrors) open-errors)")
                self.prewarmAndSearch()
                self.startWatching(roots: roots, exclude: exclude, sinceWhen: sinceId)
                self.saveSnapshot()   // so the next launch is instant
                if self.pendingVolumeRefresh {
                    self.pendingVolumeRefresh = false
                    self.refreshMountedVolumes(reason: "pending after reindex")
                }
            }
        }
    }

    // MARK: - Real-time watching

    private func startWatching(roots: [CrawlRoot], exclude: [String],
                               sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)) {
        watchedRoots = roots
        let watchPaths = Array(Set(roots.map { $0.displayPath }))
        let rec = Reconciler(index: index, exclude: exclude, mountPoints: Volumes.allMountPoints())
        reconciler = rec
        let q = reconcileQueue
        watcher.start(paths: watchPaths, sinceWhen: sinceWhen) { [weak self] paths, mustScanAll, rootChanged, batchMax in
            guard let self else { return }
            if mustScanAll {
                // FSEvents history gap / dropped events → safest is a full re-crawl.
                Diag.log("FSEvents requested full reindex for roots: \(paths.joined(separator: ", "))")
                DispatchQueue.main.async { self.beginIndexing() }
                return
            }
            if rootChanged {
                // A watched ROOT vanished/moved. The overwhelmingly common cause is a volume
                // unplug (WatchRoot fires when the mount dir disappears) — handle that via the
                // graceful volume sync (tombstone + watcher restart), NOT a multi-minute full
                // reindex. Only when every watched root is still mounted (a true root rename/
                // replace on a live volume) do we fall back to the full re-crawl.
                DispatchQueue.main.async {
                    let mounted = Set(Volumes.localCrawlRoots().map(\.displayPath))
                    let unplugged = self.watchedRoots.contains { !mounted.contains($0.displayPath) }
                    if unplugged {
                        self.refreshMountedVolumes(reason: "rootChanged (volume unplugged)")
                    } else {
                        Diag.log("rootChanged with all roots still mounted → full reindex")
                        self.beginIndexing()
                    }
                }
                return
            }
            q.async {
                let r = rec.reconcile(eventPaths: paths)
                // Advance the persisted resume cursor ONLY now that this batch is applied,
                // so a crash/quit can never persist an id ahead of the index.
                self.watcher.markApplied(batchMax)
                guard r.didMutate else { return }
                DispatchQueue.main.async { self.scheduleLiveRefresh() }
            }
        }
        Diag.log("watching: \(watchPaths.joined(separator: ", ")) since=\(sinceWhen)")
    }

    @objc private func volumeDidMount(_ note: Notification) {
        refreshMountedVolumes(reason: "didMount \(volumePath(from: note) ?? "unknown")")
    }

    @objc private func volumeDidUnmount(_ note: Notification) {
        refreshMountedVolumes(reason: "didUnmount \(volumePath(from: note) ?? "unknown")")
    }

    private func volumePath(from note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?
            .path.precomposedStringWithCanonicalMapping
    }

    private func rootsByDisplayPath(_ roots: [CrawlRoot]) -> [String: CrawlRoot] {
        var out: [String: CrawlRoot] = [:]
        for r in roots { out[r.displayPath] = r }
        return out
    }

    private func refreshMountedVolumes(reason: String) {
        guard started else { return }
        guard !isIndexing, !volumeRefreshInFlight else {
            pendingVolumeRefresh = true
            Diag.log("volume sync deferred (\(reason)); indexing=\(isIndexing) inFlight=\(volumeRefreshInFlight)")
            return
        }

        let desiredRoots = Volumes.localCrawlRoots()
        let currentByPath = rootsByDisplayPath(watchedRoots)
        let desiredByPath = rootsByDisplayPath(desiredRoots)
        let removals = watchedRoots.filter { desiredByPath[$0.displayPath] == nil }
        let additions = desiredRoots.filter { currentByPath[$0.displayPath] == nil }
        guard !removals.isEmpty || !additions.isEmpty else { return }

        volumeRefreshInFlight = true
        let gen = indexGen
        let exclude = currentExclusions()
        let expectedRoots = watchedRoots.filter { desiredByPath[$0.displayPath] != nil } + additions
        let dynamicEnumerator = additions.isEmpty ? nil : FileEnumerator(index: index)
        if let dynamicEnumerator { currentEnumerator = dynamicEnumerator }
        Diag.log("volume sync (\(reason)): +[\(additions.map(\.displayPath).joined(separator: ", "))] -[\(removals.map(\.displayPath).joined(separator: ", "))]")

        indexQueue.async { [weak self] in
            guard let self else { return }
            // Same invariant as beginIndexing: capture the FSEvents cursor BEFORE crawling,
            // so events landing on the NEW volume during the (possibly long) append-crawl
            // are replayed after the watcher restarts. The old stream keeps reconciling old
            // volumes during the crawl and advances appliedEventId past them otherwise —
            // silently and permanently dropping those files.
            let preCrawlId: UInt64? = additions.isEmpty ? nil : FSEventsGetCurrentEventId()
            var removedRows = 0
            for r in removals {
                removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
            }
            // If /Volumes delivered an event before NSWorkspace did, a mount point may
            // already exist as a child stub. Remove it before adding the real root.
            for r in additions {
                removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
            }

            var addedRows = 0
            var openErrors = 0
            var seconds = 0.0
            if let en = dynamicEnumerator {
                let stats = en.crawl(roots: additions, restrictToVolume: false, exclude: exclude,
                                     mountPoints: Volumes.allMountPoints())
                if !en.isCancelled {
                    self.index.buildLiveIndexes()
                    // A stale reconciler racing the mount may have indexed the volume AGAIN
                    // as a child subtree of /Volumes (its mount filter predated the mount).
                    // Tombstone any such duplicate stub copy, keeping the appended root.
                    for r in additions {
                        removedRows += self.index.tombstoneChildStubCopies(ofRootPath: r.displayPath)
                    }
                    addedRows = stats.total
                    openErrors = stats.openErrors
                    seconds = stats.seconds
                }
            }

            var finalRoots = expectedRoots
            if dynamicEnumerator?.isCancelled != true {
                let stillMounted = Set(Volumes.localCrawlRoots().map { $0.displayPath })
                for r in finalRoots where !stillMounted.contains(r.displayPath) {
                    removedRows += self.index.markDeletedSubtree(displayPath: r.displayPath)
                }
                finalRoots.removeAll { !stillMounted.contains($0.displayPath) }
            }
            let finalRootKeys = Set(finalRoots.map { $0.displayPath })
            let desiredKeysAfterWork = Set(Volumes.localCrawlRoots().map { $0.displayPath })
            let needsAnotherPass = finalRootKeys != desiredKeysAfterWork
            let cancelled = dynamicEnumerator?.isCancelled == true

            DispatchQueue.main.async {
                if let en = dynamicEnumerator, self.currentEnumerator === en {
                    self.currentEnumerator = nil
                }
                self.volumeRefreshInFlight = false
                guard !cancelled, gen == self.indexGen else {
                    if self.pendingVolumeRefresh, !self.isIndexing {
                        self.pendingVolumeRefresh = false
                        self.refreshMountedVolumes(reason: "pending after cancelled volume sync")
                    }
                    return
                }

                // Resume from BEFORE the append-crawl when we added a volume (replay is
                // idempotent; resuming earlier is always safe) — appliedEventId alone can
                // have advanced past new-volume events that fired during the crawl.
                let resumeId = preCrawlId.map { min($0, self.watcher.appliedEventId) }
                    ?? self.watcher.appliedEventId
                self.startWatching(roots: finalRoots, exclude: self.currentExclusions(),
                                   sinceWhen: resumeId)
                if removedRows > 0 || addedRows > 0 {
                    self.indexedCount = self.index.safeCount()
                    self.scheduleLiveRefresh()
                    self.saveSnapshot()
                    Diag.log("volume sync applied: +\(addedRows) rows -\(removedRows) rows, \(openErrors) open-errors in \(String(format: "%.2f", seconds))s")
                }
                if needsAnotherPass || self.pendingVolumeRefresh {
                    self.pendingVolumeRefresh = false
                    self.refreshMountedVolumes(reason: "pending after volume sync")
                }
            }
        }
    }

    // Coalesce bursts of filesystem changes into one index refresh so we don't
    // rebuild the sort order (and burn a core) on every individual event.
    private var liveRefreshScheduled = false
    private var pendingLiveRefresh = false
    /// Timestamp (monotonic) of the last keyboard navigation in the results list.
    /// A live refresh reloads the table, which would reset scroll/selection under an
    /// actively-held arrow key — so we defer it until the user pauses.
    var lastNavAt: TimeInterval = 0
    private func scheduleLiveRefresh() {
        snapshotDirty = true
        // When the app isn't frontmost, background file churn shouldn't burn a core
        // rebuilding the sort order — defer until the user comes back.
        guard NSApp.isActive else { pendingLiveRefresh = true; return }
        guard !liveRefreshScheduled else { return }
        liveRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.liveRefreshScheduled = false
            guard !self.isIndexing else { return }
            // Don't yank the list out from under active keyboard navigation.
            if ProcessInfo.processInfo.systemUptime - self.lastNavAt < 0.6 {
                self.scheduleLiveRefresh()   // flag is clear now → reschedules for later
                return
            }
            self.engine.invalidate()
            self.indexedCount = self.index.safeCount()   // reconciler may still be appending
            self.runSearch()
        }
    }

    @objc private func appBecameActive() {
        guard pendingLiveRefresh else { return }
        pendingLiveRefresh = false
        scheduleLiveRefresh()
    }

    // MARK: - Snapshot persistence

    private var snapshotDirty = false
    private var saveTimer: Timer?

    private func startPeriodicSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self, !self.isIndexing else { return }
            // Compact away accumulated tombstones (long high-churn sessions) by
            // re-indexing — reuses the well-tested crawl path and reclaims RAM.
            let s = self.index.liveStats()
            if s.total > 50_000, s.deleted > s.total * 2 / 5 {
                Diag.log("compacting: \(s.deleted)/\(s.total) tombstoned → reindex")
                self.beginIndexing()
                return
            }
            if self.snapshotDirty { self.saveSnapshot() }
        }
    }

    /// Write the index to disk. `sync` (used on app termination) blocks until done.
    func saveSnapshot(sync: Bool = false) {
        guard !isIndexing else { return }
        snapshotDirty = false
        let idx = index
        let lastEventId = watcher.appliedEventId   // resume cursor = last APPLIED event, never ahead of the index
        let savedAt = Date().timeIntervalSince1970
        let url = Snapshot.defaultURL()
        let work = {
            let data = idx.snapshotData(lastEventId: lastEventId, savedAt: savedAt)
            try? data.write(to: url, options: .atomic)
            Diag.log("SAVED snapshot \(data.count / (1024*1024)) MB @\(lastEventId)")
        }
        if sync { work() } else { indexQueue.async(execute: work) }
    }

    func recheckFullDiskAccess() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        if hasFullDiskAccess {
            showOnboarding = false
            beginIndexing()   // safely cancels + restarts with protected paths readable
        }
    }

    func openFDASettings() { Permissions.openFullDiskAccessSettings() }

    func reindex() { beginIndexing() }

    func setIncludeCloud(_ on: Bool) {
        guard on != includeCloud else { return }
        includeCloud = on
        beginIndexing()
    }

    func toggleScope() { scope = (scope == .nameOnly) ? .fullPath : .nameOnly }

    /// The user's typed query combined with the active type-filter chip.
    var effectiveQuery: String {
        let c = typeFilter.clause
        if c.isEmpty { return query }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? c : c + " " + q
    }

    // MARK: - recent queries & saved searches

    private static let recentsKey = "mv.recentQueries"
    private static let savedKey = "mv.savedSearches"
    private static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }
    private static func loadSaved() -> [SavedSearch] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let arr = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return arr
    }

    /// Record a query the user actually committed (Enter / opened a result).
    func recordRecentQuery(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentQueries.insert(q, at: 0)
        if recentQueries.count > 15 { recentQueries.removeLast(recentQueries.count - 15) }
        UserDefaults.standard.set(recentQueries, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentQueries.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    /// Shell-style history cycling in the search field: ⌘↑ = older, ⌘↓ = newer.
    private var historyCursor = -1
    func cycleHistory(older: Bool) {
        guard !recentQueries.isEmpty else { return }
        if older { historyCursor = min(historyCursor + 1, recentQueries.count - 1) }
        else { historyCursor -= 1 }
        if historyCursor < 0 { historyCursor = -1; query = "" }
        else { query = recentQueries[historyCursor] }
    }

    /// Apply a recent/saved query and run it.
    func applyQuery(_ q: String) {
        query = q
        focusNonce &+= 1   // keep focus on the search field
    }

    /// Restrict subsequent searches to a folder subtree (files use their parent dir).
    func searchInFolder(path: String, isDir: Bool) {
        scopeRoot = isDir ? path : (path as NSString).deletingLastPathComponent
        focusNonce &+= 1
    }

    func saveCurrentSearch(name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let s = SavedSearch(name: n, query: q, matchMode: matchMode.rawValue,
                            typeFilter: typeFilter.rawValue, scope: scope.rawValue)
        savedSearches.removeAll { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        savedSearches.append(s)
        persistSaved()
    }

    func applySaved(_ s: SavedSearch) {
        matchMode = MatchMode(rawValue: s.matchMode) ?? .exact
        typeFilter = TypeFilter(rawValue: s.typeFilter) ?? .all
        scope = SearchScope(rawValue: s.scope) ?? .nameOnly
        query = s.query
        focusNonce &+= 1
    }

    func deleteSaved(_ s: SavedSearch) {
        savedSearches.removeAll { $0.id == s.id }
        persistSaved()
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedSearches) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    // MARK: - export current results

    /// All current result paths, newline-joined (for "Copy All Paths").
    func allResultPaths() -> String {
        guard !isIndexing else { return "" }   // ids belong to the old generation during a reindex
        return resultsStore.ids.map { index.path(Int($0)) }.joined(separator: "\n")
    }

    /// The current result set as CSV (Name, Path, Size, Date Modified, Date Created).
    func buildResultsCSV() -> String {
        guard !isIndexing else { return "Name,Path,Size,Date Modified,Date Created\n" }
        let ids = resultsStore.ids
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ ns: Int64) -> String { ns == 0 ? "" : df.string(from: Date(timeIntervalSince1970: Double(ns) / 1e9)) }
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r"))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "Name,Path,Size,Date Modified,Date Created\n"
        out.reserveCapacity(ids.count * 96)
        for id in ids {
            let r = index.row(Int(id))
            let size = r.isDir ? "" : String(r.size)
            out += esc(r.name) + "," + esc(r.path) + "," + size + "," + date(r.mtime) + "," + date(r.crtime) + "\n"
        }
        return out
    }

    func runSearch() {
        guard !isIndexing else { return }   // M1: index is immutable only after crawl
        let seq = nextSearchSeq()
        let q = effectiveQuery, sk = sortKey, asc = ascending, sc = scope, mm = matchMode
        let root = scopeRoot
        let now = Date().timeIntervalSince1970
        let engine = self.engine
        let idx = self.index
        searchQueue.async { [weak self] in
            guard let self else { return }
            // Superseded by a newer keystroke before our turn on the serial queue → skip
            // the whole scan (typing enqueues many searches; only the latest need run).
            guard self.currentSearchSeq() == seq else { return }
            let rootIdx = root.flatMap { idx.dirIndex(forPath: $0) }
            // A folder scope that can't be resolved (deleted/renamed folder, or the
            // index mid-reindex) must NOT silently degrade into a whole-disk search —
            // return nothing, since the scope chip still says "in <folder>".
            if root != nil, rootIdx == nil {
                DispatchQueue.main.async {
                    guard self.currentSearchSeq() == seq else { return }
                    self.resultsStore.ids = []; self.resultTotal = 0; self.resultShown = 0
                    self.resultsVersion &+= 1
                }
                return
            }
            let res = engine.search(q, mode: mm, scope: sc, sortKey: sk, ascending: asc,
                                    now: now, scopeRoot: rootIdx)
            DispatchQueue.main.async {
                guard self.currentSearchSeq() == seq else { return }   // drop stale
                self.resultsStore.ids = res.ids
                self.resultTotal = res.total
                self.resultShown = res.ids.count
                self.queryMillis = res.queryMillis
                self.resultsVersion &+= 1
            }
        }
    }

    /// Warm ALL sort orders off the main thread (so the first search and any
    /// column-sort switch are instant), then run the current query.
    private func prewarmAndSearch() {
        let engine = self.engine
        searchQueue.async {
            for k in [SortKey.name, .size, .dateModified] {
                _ = engine.search("", sortKey: k, ascending: true, limit: 1)
            }
        }
        runSearch()
    }

    // Convenience for the table coordinator.
    func path(_ id: Int32) -> String { index.path(Int(id)) }
    func name(_ id: Int32) -> String { index.name(Int(id)) }
    func directory(_ id: Int32) -> String { index.directory(Int(id)) }
}
