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

@MainActor
final class AppModel: ObservableObject {
    @Published var query = ""
    @Published var statusText = "Starting…"
    @Published var resultTotal = 0
    @Published var indexedCount = 0
    @Published var queryMillis = 0.0
    @Published var resultsVersion = 0
    @Published var queryNonce = 0          // bumps only on a NEW query (not live refresh)
    @Published var sortKey: SortKey = .name
    @Published var ascending = true
    @Published var scope: SearchScope = .nameOnly
    @Published var matchMode: MatchMode = .exact
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
    private var started = false
    private var currentEnumerator: FileEnumerator?
    private var indexGen = 0
    private let watcher = FSWatcher()
    private var reconciler: Reconciler?
    private let reconcileQueue = DispatchQueue(label: "maverything.reconcile", qos: .utility)

    init() {
        resultsStore.index = index

        $query
            .debounce(for: .milliseconds(35), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.queryNonce &+= 1; self?.runSearch() }
            .store(in: &cancellables)

        Publishers.Merge4(
            $sortKey.map { _ in () },
            $ascending.map { _ in () },
            $scope.map { _ in () },
            $matchMode.map { _ in () }
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
    }

    private var progressTimer: Timer?

    /// Path prefixes to skip. Cloud File Providers are excluded unless the user
    /// opts in; the autofs home map is always skipped.
    private func currentExclusions() -> [String] {
        if includeCloud { return ["/System/Volumes/Data/home"] }
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
                self.startWatching(roots: Volumes.localCrawlRoots(),
                                   exclude: self.currentExclusions(),
                                   sinceWhen: meta.lastEventId)
            }
        }
        return true
    }

    /// (Re)start a whole-disk crawl across all local volumes. Safe to call while
    /// a crawl is running: the previous crawl is cancelled and superseded.
    func beginIndexing() {
        indexGen += 1
        let gen = indexGen
        watcher.stop()                  // pause live updates during (re)index
        currentEnumerator?.cancel()     // abort any in-flight crawl fast
        isIndexing = true
        indexedCount = 0
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
            DispatchQueue.main.sync {
                guard gen == self.indexGen else { return }
                self.index.clear()
                self.index.reserveCapacity(3_000_000)
                self.currentEnumerator = en
            }
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
                self.startWatching(roots: roots, exclude: exclude)
                self.saveSnapshot()   // so the next launch is instant
            }
        }
    }

    // MARK: - Real-time watching

    private func startWatching(roots: [CrawlRoot], exclude: [String],
                               sinceWhen: UInt64 = UInt64(kFSEventStreamEventIdSinceNow)) {
        let watchPaths = Array(Set(roots.map { $0.displayPath }))
        let rec = Reconciler(index: index, exclude: exclude)
        reconciler = rec
        let q = reconcileQueue
        watcher.start(paths: watchPaths, sinceWhen: sinceWhen) { [weak self] paths, mustScanAll in
            if mustScanAll {
                // FSEvents history gap / dropped events → safest is a full re-crawl.
                DispatchQueue.main.async { self?.beginIndexing() }
                return
            }
            q.async {
                let r = rec.reconcile(eventPaths: paths)
                guard r.didMutate else { return }
                DispatchQueue.main.async { self?.scheduleLiveRefresh() }
            }
        }
        Diag.log("watching: \(watchPaths.joined(separator: ", ")) since=\(sinceWhen)")
    }

    // Coalesce bursts of filesystem changes into one index refresh so we don't
    // rebuild the sort order (and burn a core) on every individual event.
    private var liveRefreshScheduled = false
    private var pendingLiveRefresh = false
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
            guard let self, self.snapshotDirty, !self.isIndexing else { return }
            self.saveSnapshot()
        }
    }

    /// Write the index to disk. `sync` (used on app termination) blocks until done.
    func saveSnapshot(sync: Bool = false) {
        guard !isIndexing else { return }
        snapshotDirty = false
        let idx = index
        let lastEventId = watcher.lastEventId
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

    func runSearch() {
        guard !isIndexing else { return }   // M1: index is immutable only after crawl
        searchSeq &+= 1
        let seq = searchSeq
        let q = query, sk = sortKey, asc = ascending, sc = scope, mm = matchMode
        let now = Date().timeIntervalSince1970
        let engine = self.engine
        searchQueue.async { [weak self] in
            guard let self else { return }
            let res = engine.search(q, mode: mm, scope: sc, sortKey: sk, ascending: asc, now: now)
            DispatchQueue.main.async {
                guard seq == self.searchSeq else { return }   // drop stale
                self.resultsStore.ids = res.ids
                self.resultTotal = res.total
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
